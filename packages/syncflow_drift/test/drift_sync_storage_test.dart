import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:syncflow/syncflow.dart';
import 'package:syncflow_drift/syncflow_drift.dart';
import 'package:syncflow_test/syncflow_test.dart';
import 'package:test/test.dart';

/// Stands in for an application's own Drift database with its own table.
Future<SyncFlowDatabase> openAppDatabase(QueryExecutor executor) async {
  final database = SyncFlowDatabase(executor);
  await database.customStatement(
    'CREATE TABLE IF NOT EXISTS customers (id TEXT PRIMARY KEY, name TEXT)',
  );
  return database;
}

Future<List<String>> tableNames(GeneratedDatabase database) async {
  final rows = await database
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name NOT LIKE 'sqlite_%' ORDER BY name",
      )
      .get();
  return [for (final row in rows) row.read<String>('name')];
}

void main() {
  final t0 = DateTime.utc(2026, 5, 1, 8);

  group('schema', () {
    late SyncFlowDatabase database;

    setUp(
        () async => database = await openAppDatabase(NativeDatabase.memory()));
    tearDown(() => database.close());

    test('adds prefixed tables next to the application tables', () async {
      final storage = DriftSyncStorage(database);
      await storage.initialize();

      expect(await tableNames(database), [
        'customers',
        'syncflow_checkpoints',
        'syncflow_conflicts',
        'syncflow_id_mappings',
        'syncflow_metadata',
        'syncflow_operations',
      ]);
      expect(DriftSyncStorage.schemaVersion, 3);
    });

    test('upgrades a version 1 database to the latest, preserving pending work',
        () async {
      // Build a database exactly as schema version 1 left it.
      final v1 = DriftSyncStorage(database);
      await v1.initialize();
      await v1.insertOperation(
        buildTestOperation(id: 'pending-1', payload: {'name': 'Ada'}),
      );
      await v1.insertOperation(
        buildTestOperation(
          id: 'retry-1',
          status: SyncOperationStatus.retryScheduled,
          attempts: 3,
          nextAttemptAt: DateTime.utc(2026, 5, 2),
        ),
      );
      await database.customStatement('DROP TABLE syncflow_id_mappings');
      await database.customStatement('DROP TABLE syncflow_conflicts');
      await database.customStatement(
        "UPDATE syncflow_metadata SET value = '1' "
        "WHERE key = 'schema_version'",
      );

      final upgraded = DriftSyncStorage(database);
      await upgraded.initialize();

      final version = await database
          .customSelect(
            "SELECT value FROM syncflow_metadata WHERE key = 'schema_version'",
          )
          .getSingle();
      expect(version.read<String>('value'), '3');
      expect(
        (await upgraded.getOperation('pending-1'))!.payload,
        {'name': 'Ada'},
      );
      final retry = (await upgraded.getOperation('retry-1'))!;
      expect(retry.status, SyncOperationStatus.retryScheduled);
      expect(retry.attempts, 3);
      expect(retry.idempotencyKey, 'idem-retry-1');

      await upgraded.saveIdMapping(
        SyncIdMapping(
          accountId: 'account-a',
          entityName: 'customers',
          localId: 'tmp-1',
          serverId: 'srv-1',
          createdAt: t0,
        ),
      );
      expect(
        await upgraded.resolveServerId(
          accountId: 'account-a',
          entityName: 'customers',
          localId: 'tmp-1',
        ),
        'srv-1',
      );
    });

    test('records its schema version and initializes idempotently', () async {
      final storage = DriftSyncStorage(database);
      await storage.initialize();
      await storage.insertOperation(buildTestOperation(id: 'op-1'));

      final again = DriftSyncStorage(database);
      await again.initialize();

      final version = await database
          .customSelect(
            "SELECT value FROM syncflow_metadata WHERE key = 'schema_version'",
          )
          .getSingle();
      expect(
          version.read<String>('value'), '${DriftSyncStorage.schemaVersion}');
      expect(await again.getOperation('op-1'), isNotNull);
    });

    test('refuses a schema written by a newer version, keeping data', () async {
      final storage = DriftSyncStorage(database);
      await storage.initialize();
      await storage.insertOperation(buildTestOperation(id: 'op-1'));
      await database.customStatement(
        "UPDATE syncflow_metadata SET value = '999' "
        "WHERE key = 'schema_version'",
      );

      await expectLater(
        DriftSyncStorage(database).initialize(),
        throwsA(
          isA<SyncStorageException>()
              .having((e) => e.message, 'message', contains('newer')),
        ),
      );
      final count = await database
          .customSelect('SELECT COUNT(*) AS n FROM syncflow_operations')
          .getSingle();
      expect(count.read<int>('n'), 1);
    });

    test('requires initialize before use', () {
      final storage = DriftSyncStorage(database);
      expect(() => storage.getOperation('x'), throwsStateError);
    });
  });

  group('transactional outbox (shared database)', () {
    late SyncFlowDatabase database;
    late DriftSyncStorage storage;
    late OperationQueue queue;

    setUp(() async {
      database = await openAppDatabase(NativeDatabase.memory());
      storage = DriftSyncStorage(database);
      await storage.initialize();
      queue = OperationQueue(storage: storage, clock: FakeClock(t0));
    });
    tearDown(() => database.close());

    Future<int> customerCount() async => (await database
            .customSelect('SELECT COUNT(*) AS n FROM customers')
            .getSingle())
        .read<int>('n');

    Future<void> createCustomer(String id, {bool fail = false}) =>
        database.transaction(() async {
          await database.customInsert(
            'INSERT INTO customers (id, name) VALUES (?, ?)',
            variables: [Variable<String>(id), Variable<String>('Ada')],
          );
          await queue.enqueue(
            SyncMutation.create(
              entity: 'customers',
              id: id,
              data: const {'name': 'Ada'},
            ),
            accountId: 'account-a',
          );
          if (fail) throw StateError('crash after both writes');
        });

    test('commits the local write and the operation together', () async {
      await createCustomer('c-1');

      expect(await customerCount(), 1);
      expect(storage.allOperationsFor('account-a'), completion(hasLength(1)));
    });

    test('rolls back both when the transaction fails', () async {
      await expectLater(createCustomer('c-1', fail: true), throwsStateError);

      expect(await customerCount(), 0);
      expect(storage.allOperationsFor('account-a'), completion(isEmpty));
    });

    test('close does not close a shared application database', () async {
      await storage.close();
      expect(await customerCount(), 0);
    });
  });

  group('durability', () {
    late Directory directory;
    late File file;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('syncflow_drift_');
      file = File('${directory.path}/app.sqlite');
    });
    tearDown(() => directory.delete(recursive: true));

    test('offline create survives restart and is delivered exactly once',
        () async {
      // Session 1: offline. The mutation is recorded, then the app dies.
      var storage = DriftSyncStorage.separate(NativeDatabase(file));
      await storage.initialize();
      final clock = FakeClock(t0);
      final created =
          await OperationQueue(storage: storage, clock: clock).enqueue(
        SyncMutation.create(
          entity: 'customers',
          id: 'c-1',
          data: const {'name': 'Ada'},
        ),
        accountId: 'account-a',
      );
      await storage.close();

      // Session 2: online. The response is lost after the server processed
      // the request, so the operation is retried with the same key.
      storage = DriftSyncStorage.separate(NativeDatabase(file));
      await storage.initialize();
      final server = FakeIdempotentServer();
      final transport = FakeSyncTransport(handler: server.handle)
        ..enqueueHandler((request) async {
          await server.handle(request);
          throw const SyncTransportException(
            'Connection reset.',
            category: SyncErrorCategory.network,
          );
        });
      final engine = SyncEngine(
        storage: storage,
        transport: transport,
        activeAccount: () => 'account-a',
        requestBuilder: (op) => SyncRequest(
          method: SyncHttpMethod.post,
          path: '/customers',
          accountId: op.accountId,
          body: op.payload,
        ),
        retryPolicy: ExponentialBackoffRetryPolicy(jitter: 0),
        clock: clock,
      );
      await engine.initialize();
      await engine.syncNow();
      clock.advance(const Duration(seconds: 1));
      await engine.syncNow();
      await engine.close();
      await storage.close();

      // Session 3: the acknowledgement was persisted.
      storage = DriftSyncStorage.separate(NativeDatabase(file));
      await storage.initialize();
      final stored = (await storage.getOperation(created.id))!;
      await storage.close();

      expect(stored.status, SyncOperationStatus.acknowledged);
      expect(stored.attempts, 2);
      expect(stored.idempotencyKey, created.idempotencyKey);
      expect(server.received, 2);
      expect(server.effects, hasLength(1));
    });

    test('a lease held when the app died is recovered after restart', () async {
      var storage = DriftSyncStorage.separate(NativeDatabase(file));
      await storage.initialize();
      await storage.insertOperation(buildTestOperation(id: 'op-1'));
      await storage.acquireLease(
        operationId: 'op-1',
        workerId: 'dead-worker',
        now: t0,
        expiresAt: t0.add(const Duration(minutes: 1)),
      );
      await storage.close();

      storage = DriftSyncStorage.separate(NativeDatabase(file));
      await storage.initialize();
      final recovered = await storage.recoverExpiredLeases(
        t0.add(const Duration(minutes: 1)),
      );
      final operation = (await storage.getOperation('op-1'))!;
      await storage.close();

      expect(recovered, 1);
      expect(operation.status, SyncOperationStatus.pending);
      expect(operation.idempotencyKey, 'idem-op-1');
    });
  });

  group('pull into the shared database', () {
    late SyncFlowDatabase database;
    late DriftSyncStorage storage;
    late _CustomerTableAdapter adapter;
    late FakeSyncTransport transport;
    late SyncEngine engine;

    setUp(() async {
      database = await openAppDatabase(NativeDatabase.memory());
      storage = DriftSyncStorage(database);
      await storage.initialize();
      adapter = _CustomerTableAdapter(database);
      transport = FakeSyncTransport(
        handler: (_) => SyncResponse(
          statusCode: 200,
          body: {
            'changes': [
              {
                'entityId': 'c-1',
                'type': 'create',
                'data': {'name': 'Ada'},
              },
              {
                'entityId': 'c-2',
                'type': 'create',
                'data': {'name': 'Grace'},
              },
            ],
            'nextCursor': 'p2',
            'hasMore': false,
          },
        ),
      );
      final entities = SyncEntityRegistry([
        SyncEntity(
          name: 'customers',
          endpoint: const RestEndpoint.crud('/customers'),
          pull: const PullEndpoint('/customers/changes'),
          adapter: adapter,
        ),
      ]);
      engine = SyncEngine(
        storage: storage,
        transport: transport,
        requestBuilder:
            RestRequestBuilder(entities: entities, storage: storage).build,
        entities: entities,
        activeAccount: () => 'account-a',
        clock: FakeClock(t0),
      );
      await engine.initialize();
    });

    tearDown(() async {
      await engine.close();
      await database.close();
    });

    Future<List<String>> customerIds() async => [
          for (final row in await database
              .customSelect('SELECT id FROM customers ORDER BY id')
              .get())
            row.read<String>('id'),
        ];

    Future<String?> cursor() async => (await storage.getCheckpoint(
          accountId: 'account-a',
          entityName: 'customers',
        ))
            ?.cursor;

    test('commits the page and the checkpoint together', () async {
      final result = await engine.syncNow();

      expect(result.pulledChanges, 2);
      expect(await customerIds(), ['c-1', 'c-2']);
      expect(await cursor(), 'p2');
    });

    test('a failure mid-page rolls back rows and checkpoint', () async {
      adapter.failAfter = 1;

      final result = await engine.syncNow();

      expect(result.pullFailures, 1);
      expect(await customerIds(), isEmpty,
          reason: 'the first row was rolled back');
      expect(await cursor(), isNull);
    });
  });

  group('robustness', () {
    late DriftSyncStorage storage;
    late SyncFlowDatabase database;

    setUp(() async {
      database = SyncFlowDatabase(NativeDatabase.memory());
      storage = DriftSyncStorage(database, closeDatabase: true);
      await storage.initialize();
    });
    tearDown(() => storage.close());

    test('a corrupt row is reported, never skipped', () async {
      await storage.insertOperation(buildTestOperation(id: 'op-1'));
      await database.customStatement(
        "UPDATE syncflow_operations SET payload = '{not json' WHERE id = 'op-1'",
      );

      await expectLater(
        storage.getEligibleOperations(
          accountId: 'account-a',
          now: t0.add(const Duration(days: 1)),
          limit: 10,
        ),
        throwsA(
          isA<FormatException>()
              .having((e) => e.message, 'message', contains('op-1')),
        ),
      );
    });

    test('an invalid stored status is reported', () async {
      await storage.insertOperation(buildTestOperation(id: 'op-1'));
      await database.customStatement(
        "UPDATE syncflow_operations SET status = 'flying' WHERE id = 'op-1'",
      );

      await expectLater(
        storage.getOperation('op-1'),
        throwsFormatException,
      );
    });

    test('backend failures surface as SyncStorageException', () async {
      await database.customStatement('DROP TABLE syncflow_operations');

      await expectLater(
        storage.getOperation('op-1'),
        throwsA(isA<SyncStorageException>()),
      );
    });

    test('timestamps keep microsecond precision', () async {
      final precise = DateTime.utc(2026, 5, 1, 8, 0, 0, 123, 456);
      await storage.insertOperation(
        buildTestOperation(id: 'op-1', createdAt: precise),
      );

      expect((await storage.getOperation('op-1'))!.createdAt, precise);
    });

    test('eligibility and entity lookups use indexes', () async {
      Future<String> plan(String sql, List<Variable<Object>> variables) async {
        final rows = await database
            .customSelect('EXPLAIN QUERY PLAN $sql', variables: variables)
            .get();
        return rows.map((r) => r.read<String>('detail')).join('\n');
      }

      final eligible = await plan(
        DriftSyncStorage.eligibleOperationsQuery,
        [
          Variable<String>('account-a'),
          Variable<String>('pending'),
          Variable<String>('retryScheduled'),
          Variable<int>(0),
          Variable<int>(10),
        ],
      );
      final entity = await plan(
        'SELECT * FROM syncflow_operations WHERE account_id = ? '
        'AND entity_name = ? AND entity_id = ? '
        'ORDER BY created_at DESC LIMIT 1',
        [
          Variable<String>('account-a'),
          Variable<String>('customers'),
          Variable<String>('c-1'),
        ],
      );

      expect(eligible, contains('syncflow_operations_eligible'));
      expect(entity, contains('syncflow_operations_entity'));
    });
  });
}

extension on DriftSyncStorage {
  /// Every operation of [accountId] that is still eligible, for assertions.
  Future<List<SyncOperation>> allOperationsFor(String accountId) =>
      getEligibleOperations(
        accountId: accountId,
        now: DateTime.utc(2100),
        limit: 1000,
      );
}

/// Writes remote customers into the application's own `customers` table.
final class _CustomerTableAdapter implements SyncEntityAdapter {
  _CustomerTableAdapter(this.database);

  final GeneratedDatabase database;

  /// Throw after writing this many rows, to simulate a mid-page failure.
  int? failAfter;

  @override
  Future<void> applyRemoteChanges(List<RemoteChange> changes) async {
    var written = 0;
    for (final change in changes) {
      if (failAfter != null && written >= failAfter!) {
        throw Exception('simulated failure');
      }
      if (change.type == RemoteChangeType.delete) {
        await database.customUpdate(
          'DELETE FROM customers WHERE id = ?',
          variables: [Variable<String>(change.entityId)],
        );
      } else {
        await database.customInsert(
          'INSERT OR REPLACE INTO customers (id, name) VALUES (?, ?)',
          variables: [
            Variable<String>(change.entityId),
            Variable<String>(change.data!['name']! as String),
          ],
        );
      }
      written++;
    }
  }

  @override
  Future<void> prepareFullResync() async {}
}
