import 'package:syncflow/syncflow.dart';
import 'package:syncflow_test/syncflow_test.dart';
import 'package:test/test.dart';

void main() {
  final t0 = DateTime.utc(2026, 9, 1, 12);
  late InMemorySyncStorage storage;
  late FakeClock clock;
  late FakeSyncTransport transport;
  late OperationQueue queue;
  late InMemoryEntityAdapter adapter;
  late List<SyncEvent> events;
  late SyncEngine engine;

  Future<SyncEngine> start({
    ConflictResolver? resolver,
    SyncEntityAdapter? entityAdapter,
  }) async {
    final entities = SyncEntityRegistry([
      SyncEntity(
        name: 'customers',
        endpoint: const RestEndpoint.crud('/customers'),
        conflictResolver: resolver,
        adapter: entityAdapter ?? adapter,
      ),
      SyncEntity(
        name: 'accounts',
        endpoint: const RestEndpoint.crud('/accounts'),
      ),
    ]);
    final created = SyncEngine(
      storage: storage,
      transport: transport,
      requestBuilder:
          RestRequestBuilder(entities: entities, storage: storage).build,
      entities: entities,
      activeAccount: () => 'account-a',
      config: const SyncEngineConfig(maxConcurrentOperations: 1),
      clock: clock,
    );
    created.events.listen(events.add);
    await created.initialize();
    return created;
  }

  setUp(() async {
    storage = InMemorySyncStorage();
    await storage.initialize();
    clock = FakeClock(t0);
    transport = FakeSyncTransport();
    queue = OperationQueue(storage: storage, clock: clock);
    adapter = InMemoryEntityAdapter();
    events = [];
  });

  tearDown(() async {
    await engine.close();
    await storage.close();
  });

  Future<SyncOperation> rename(String name, {String? baseVersion = '"v1"'}) =>
      queue.enqueue(
        SyncMutation.update(
          entity: 'customers',
          id: 'c-1',
          data: {'name': name},
          baseVersion: baseVersion,
        ),
        accountId: 'account-a',
      );

  /// The server rejects the first request with 409 and its current state.
  void conflictOnce({
    Map<String, Object?> current = const {
      'name': 'Server name',
      'updatedAt': '2026-09-01T11:00:00Z',
    },
    String? etag = '"v2"',
  }) {
    transport.enqueueHandler(
      (_) => SyncResponse(
        statusCode: 409,
        headers: {if (etag != null) 'ETag': etag},
        body: {'current': current},
      ),
    );
  }

  group('detection', () {
    test(
        'stores the conflict with the remote state and waits for manual '
        'resolution by default', () async {
      engine = await start();
      final operation = await rename('Local name');
      conflictOnce();

      final result = await engine.syncNow();
      await pumpEventQueue();

      expect(result.conflicts, 1);
      expect(result.conflictsResolved, 0);
      expect(
        (await storage.getOperation(operation.id))!.status,
        SyncOperationStatus.conflict,
      );
      final conflict = (await storage.getConflict(operation.id))!;
      expect(conflict.remoteData, {
        'name': 'Server name',
        'updatedAt': '2026-09-01T11:00:00Z',
      });
      expect(conflict.remoteVersion, '"v2"');
      final detected = events.whereType<ConflictDetected>().single;
      expect(detected.conflict.operationId, operation.id);
      expect(adapter.applied, isEmpty, reason: 'nothing applied yet');
    });

    test('a failing resolver falls back to manual resolution', () async {
      engine = await start(
        resolver: (_, __) => throw const FormatException('resolver bug'),
      );
      final operation = await rename('Local name');
      conflictOnce();

      final result = await engine.syncNow();
      await pumpEventQueue();

      expect(result.conflictsResolved, 0);
      expect(events.whereType<ConflictDetected>(), hasLength(1));
      expect(await storage.getConflict(operation.id), isNotNull);
    });
  });

  group('built-in strategies', () {
    test('server wins: applies the remote state and cancels the local change',
        () async {
      engine = await start(resolver: ConflictStrategy.serverWins.resolver());
      final operation = await rename('Local name');
      conflictOnce();

      final result = await engine.syncNow();
      await pumpEventQueue();

      expect(result.conflictsResolved, 1);
      expect(
        (await storage.getOperation(operation.id))!.status,
        SyncOperationStatus.cancelled,
      );
      expect(adapter.rows['c-1'], {
        'name': 'Server name',
        'updatedAt': '2026-09-01T11:00:00Z',
      });
      expect(adapter.applied.single.version, '"v2"');
      expect(await storage.getConflict(operation.id), isNull);
      expect(
        events.whereType<ConflictResolved>().single.resolution,
        isA<UseRemote>(),
      );
    });

    test('client wins: re-sends the change on top of the server version',
        () async {
      engine = await start(resolver: ConflictStrategy.clientWins.resolver());
      final operation = await rename('Local name');
      conflictOnce();

      await engine.syncNow();
      final rebased = (await storage.getOperation(operation.id))!;
      final second = await engine.syncNow();

      expect(rebased.status, SyncOperationStatus.pending);
      expect(rebased.baseVersion, '"v2"');
      expect(rebased.attempts, 0);
      expect(second.acknowledged, 1);
      expect(
        transport.requests.map((r) => r.headers['If-Match']),
        ['"v1"', '"v2"'],
      );
      expect(transport.requests.last.body, {'name': 'Local name'});
      expect(
        transport.requests.last.idempotencyKey,
        operation.idempotencyKey,
      );
    });

    test('client wins without a known version writes unconditionally',
        () async {
      engine = await start(resolver: ConflictStrategy.clientWins.resolver());
      final operation = await rename('Local name');
      conflictOnce(etag: null, current: const {'name': 'Server name'});

      await engine.syncNow();
      await engine.syncNow();

      expect((await storage.getOperation(operation.id))!.baseVersion, isNull);
      expect(transport.requests.last.headers, isNot(contains('If-Match')));
    });

    group('last write wins', () {
      Future<SyncOperationStatus> outcome(String? remoteUpdatedAt) async {
        engine = await start(
          resolver: ConflictStrategy.lastWriteWins.resolver(),
        );
        final operation = await rename('Local name');
        conflictOnce(
          current: {
            'name': 'Server name',
            if (remoteUpdatedAt != null) 'updatedAt': remoteUpdatedAt,
          },
        );
        await engine.syncNow();
        return (await storage.getOperation(operation.id))!.status;
      }

      test('the local change wins when it is newer', () async {
        expect(
            await outcome('2026-09-01T11:00:00Z'), SyncOperationStatus.pending);
      });

      test('the remote change wins when it is newer', () async {
        expect(await outcome('2026-09-01T13:00:00Z'),
            SyncOperationStatus.cancelled);
      });

      test('an unknown remote time requires manual resolution', () async {
        expect(await outcome(null), SyncOperationStatus.conflict);
      });
    });
  });

  group('manual resolution', () {
    test('a merged payload is rebased and sent on the next run', () async {
      engine = await start();
      final operation = await rename('Local name');
      conflictOnce();
      await engine.syncNow();

      final resolved = await engine.resolveConflict(
        operation.id,
        MergeResolution({'name': 'Local name', 'nickname': 'Server name'}),
      );
      final result = await engine.syncNow();

      expect(resolved.status, SyncOperationStatus.pending);
      expect(resolved.baseVersion, '"v2"');
      expect(result.acknowledged, 1);
      expect(transport.requests.last.body, {
        'name': 'Local name',
        'nickname': 'Server name',
      });
      expect(await storage.getConflict(operation.id), isNull);
    });

    test('conflicts survive a restart', () async {
      engine = await start();
      final operation = await rename('Local name');
      conflictOnce();
      await engine.syncNow();
      await engine.close();

      engine = await start();
      expect(
        await storage.listConflicts(accountId: 'account-a'),
        hasLength(1),
      );
      await engine.resolveConflict(operation.id, const UseRemote());

      expect(adapter.rows['c-1']?['name'], 'Server name');
    });

    test('rejects invalid resolutions', () async {
      engine = await start();
      final operation = await rename('Local name');

      await expectLater(
        engine.resolveConflict(operation.id, const UseLocal()),
        throwsA(isA<InvalidStateTransitionException>()),
      );
      await expectLater(
        engine.resolveConflict('missing', const UseLocal()),
        throwsA(isA<OperationNotFoundException>()),
      );
      expect(
        () => engine.resolveConflict(
          operation.id,
          const RequireManualResolution(),
        ),
        throwsArgumentError,
      );
    });
  });

  group('dependents', () {
    test('wait while in conflict and proceed once the server state is kept',
        () async {
      engine = await start();
      final update = await rename('Local name');
      final later = await rename('Even later');
      conflictOnce();

      final first = await engine.syncNow();
      expect(first.blocked, 1);
      expect(transport.requests, hasLength(1));

      await engine.resolveConflict(update.id, const UseRemote());
      final second = await engine.syncNow();

      expect(second.acknowledged, 1);
      expect(transport.requests.last.operationId, later.id);
    });
  });
}
