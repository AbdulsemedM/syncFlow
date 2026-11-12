import 'package:syncflow/syncflow.dart';
import 'package:syncflow_test/syncflow_test.dart';
import 'package:test/test.dart';

/// A change feed served page by page, keyed by cursor (null = start).
final class FakeFeed {
  final Map<String?, Map<String, Object?>> pages = {};
  final Set<String> expiredCursors = {};
  final List<String?> requestedCursors = [];

  SyncResponse handle(SyncRequest request) {
    final cursor = request.queryParameters['cursor'] as String?;
    requestedCursors.add(cursor);
    if (expiredCursors.contains(cursor)) {
      return SyncResponse(statusCode: 410);
    }
    final page = pages[cursor];
    if (page == null) {
      return SyncResponse(
        statusCode: 200,
        body: {'changes': <Object?>[], 'nextCursor': cursor, 'hasMore': false},
      );
    }
    return SyncResponse(statusCode: 200, body: page);
  }
}

Map<String, Object?> upsert(String id, String name, {int version = 1}) => {
      'entityId': id,
      'type': 'update',
      'version': version,
      'data': {'name': name},
    };

Map<String, Object?> tombstone(String id) => {'entityId': id, 'type': 'delete'};

void main() {
  final t0 = DateTime.utc(2026, 10, 1, 8);
  late InMemorySyncStorage storage;
  late FakeClock clock;
  late FakeSyncTransport transport;
  late FakeFeed customersFeed;
  late FakeFeed ordersFeed;
  late InMemoryEntityAdapter customers;
  late InMemoryEntityAdapter orders;
  late List<SyncEvent> events;
  late SyncEngine engine;
  var account = 'account-a';

  Future<SyncEngine> start({
    SyncEngineConfig config = const SyncEngineConfig(),
  }) async {
    final entities = SyncEntityRegistry([
      SyncEntity(
        name: 'customers',
        endpoint: const RestEndpoint.crud('/customers'),
        pull: const PullEndpoint('/customers/changes', pageSize: 2),
        adapter: customers,
      ),
      SyncEntity(
        name: 'orders',
        endpoint: const RestEndpoint.crud('/orders'),
        pull: const PullEndpoint('/orders/changes'),
        adapter: orders,
      ),
      SyncEntity(
        name: 'push-only',
        endpoint: const RestEndpoint.crud('/push-only'),
      ),
    ]);
    final created = SyncEngine(
      storage: storage,
      transport: transport,
      requestBuilder:
          RestRequestBuilder(entities: entities, storage: storage).build,
      entities: entities,
      activeAccount: () => account,
      config: config,
      retryPolicy: ExponentialBackoffRetryPolicy(jitter: 0),
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
    customersFeed = FakeFeed();
    ordersFeed = FakeFeed();
    transport = FakeSyncTransport(
      handler: (request) => switch (request.path) {
        '/customers/changes' => customersFeed.handle(request),
        '/orders/changes' => ordersFeed.handle(request),
        _ => SyncResponse(statusCode: 200),
      },
    );
    customers = InMemoryEntityAdapter();
    orders = InMemoryEntityAdapter();
    events = [];
    account = 'account-a';
  });

  tearDown(() async {
    await engine.close();
    await storage.close();
  });

  Future<String?> checkpoint(String entity) async =>
      (await storage.getCheckpoint(accountId: 'account-a', entityName: entity))
          ?.cursor;

  test('pulls every page in order and advances the checkpoint', () async {
    customersFeed.pages
      ..[null] = {
        'changes': [upsert('c-1', 'Ada'), upsert('c-2', 'Grace')],
        'nextCursor': 'p2',
        'hasMore': true,
      }
      ..['p2'] = {
        'changes': [upsert('c-1', 'Ada L.', version: 2), tombstone('c-2')],
        'nextCursor': 'p3',
        'hasMore': false,
      };
    engine = await start();

    final result = await engine.syncNow();
    await pumpEventQueue();

    expect(result.pulledChanges, 4);
    expect(result.pullFailures, 0);
    expect(customers.rows, {
      'c-1': {'name': 'Ada L.'},
    });
    expect(customers.appliedPages, hasLength(2));
    expect(customers.applied.last.type, RemoteChangeType.delete);
    expect(await checkpoint('customers'), 'p3');
    expect(customersFeed.requestedCursors, [null, 'p2']);
    final request = transport.requests.first;
    expect(request.method, SyncHttpMethod.get);
    expect(request.queryParameters, {'limit': '2'});
    expect(
      events
          .whereType<RemoteChangesApplied>()
          .where((e) => e.entityName == 'customers')
          .map((e) => e.cursor),
      ['p2', 'p3'],
    );
  });

  test('resumes from the stored checkpoint', () async {
    customersFeed.pages[null] = {
      'changes': [upsert('c-1', 'Ada')],
      'nextCursor': 'p2',
      'hasMore': false,
    };
    engine = await start();
    await engine.syncNow();

    customersFeed.pages['p2'] = {
      'changes': [upsert('c-3', 'Linus')],
      'nextCursor': 'p3',
      'hasMore': false,
    };
    final second = await engine.syncNow();

    expect(customersFeed.requestedCursors, [null, 'p2']);
    expect(second.pulledChanges, 1);
    expect(customers.rows.keys, ['c-1', 'c-3']);
    expect(
      transport.requests
          .lastWhere((r) => r.path == '/customers/changes')
          .queryParameters['cursor'],
      'p2',
    );
  });

  test('pushes local changes before pulling', () async {
    engine = await start();
    await OperationQueue(storage: storage, clock: clock).enqueue(
      SyncMutation.create(entity: 'orders', id: 'o-1', data: const {}),
      accountId: 'account-a',
    );

    await engine.syncNow();

    expect(
      transport.requests.map((r) => '${r.method.name} ${r.path}'),
      ['post /orders', 'get /customers/changes', 'get /orders/changes'],
    );
  });

  test('a failed page keeps the checkpoint and is retried next run', () async {
    customersFeed.pages
      ..[null] = {
        'changes': [upsert('c-1', 'Ada')],
        'nextCursor': 'p2',
        'hasMore': true,
      }
      ..['p2'] = {
        'changes': [upsert('c-2', 'Grace')],
        'nextCursor': 'p3',
        'hasMore': false,
      };
    engine = await start();
    customers.failWith = Exception('disk full');

    final failed = await engine.syncNow();
    await pumpEventQueue();

    expect(failed.pullFailures, 1);
    expect(failed.pulledChanges, 0);
    expect(await checkpoint('customers'), isNull);
    expect(
      events.whereType<PullFailed>().single.error.category,
      SyncErrorCategory.storage,
    );

    customers.failWith = null;
    final retried = await engine.syncNow();

    expect(retried.pulledChanges, 2);
    expect(await checkpoint('customers'), 'p3');
  });

  test('one failing entity does not stop the others', () async {
    customersFeed.pages[null] = {'changes': 'not-a-list'};
    ordersFeed.pages[null] = {
      'changes': [upsert('o-1', 'Order')],
      'nextCursor': 'o2',
      'hasMore': false,
    };
    engine = await start();

    final result = await engine.syncNow();
    await pumpEventQueue();

    expect(result.pullFailures, 1);
    expect(result.pulledChanges, 1);
    expect(
      events.whereType<PullFailed>().single.error.category,
      SyncErrorCategory.protocol,
    );
    expect(orders.rows.keys, ['o-1']);
  });

  test('an expired cursor triggers a full resync from the beginning', () async {
    await storage.saveCheckpoint(
      SyncCheckpoint(
        accountId: 'account-a',
        entityName: 'customers',
        cursor: 'ancient',
        updatedAt: t0,
      ),
    );
    customers.rows['stale'] = {'name': 'Deleted long ago'};
    customersFeed
      ..expiredCursors.add('ancient')
      ..pages[null] = {
        'changes': [upsert('c-1', 'Ada')],
        'nextCursor': 'fresh',
        'hasMore': false,
      };
    engine = await start();

    final result = await engine.syncNow();
    await pumpEventQueue();

    expect(customers.fullResyncs, 1);
    expect(customers.rows.keys, ['c-1']);
    expect(customersFeed.requestedCursors, ['ancient', null]);
    expect(await checkpoint('customers'), 'fresh');
    expect(result.pullFailures, 0);
    expect(events.whereType<FullResyncStarted>(), hasLength(1));
  });

  test('a cursor that keeps expiring resyncs only once per run', () async {
    customersFeed.expiredCursors.addAll(['old']);
    customersFeed.pages[null] = {
      'changes': <Object?>[],
      'nextCursor': 'old',
      'hasMore': true,
    };
    await storage.saveCheckpoint(
      SyncCheckpoint(
        accountId: 'account-a',
        entityName: 'customers',
        cursor: 'old',
        updatedAt: t0,
      ),
    );
    engine = await start();

    final result = await engine.syncNow();

    expect(customers.fullResyncs, 1);
    expect(result.pullFailures, 1);
  });

  test('stops when the server makes no progress', () async {
    customersFeed.pages[null] = {
      'changes': <Object?>[],
      'nextCursor': null,
      'hasMore': true,
    };
    engine = await start();

    await engine.syncNow();

    expect(customersFeed.requestedCursors, [null]);
  });

  test('changes for entities with unsynced local edits are flagged', () async {
    engine = await start();
    final queue = OperationQueue(storage: storage, clock: clock);
    await queue.enqueue(
      SyncMutation.update(
        entity: 'customers',
        id: 'c-1',
        data: const {'name': 'Local edit'},
      ),
      accountId: 'account-a',
    );
    transport.enqueueStatus(503); // the push fails and stays queued
    customersFeed.pages[null] = {
      'changes': [upsert('c-1', 'Remote edit'), upsert('c-2', 'Grace')],
      'nextCursor': 'p2',
      'hasMore': false,
    };

    await engine.syncNow();

    expect(
      customers.applied.map((c) => '${c.entityId}:${c.hasPendingLocalChanges}'),
      ['c-1:true', 'c-2:false'],
    );
    expect(customers.skipped.single.entityId, 'c-1');
    expect(customers.rows.keys, ['c-2']);
  });

  test('401 on pull pauses the account', () async {
    customersFeed.pages[null] = {'changes': <Object?>[]};
    transport.handler = (request) => SyncResponse(statusCode: 401);
    engine = await start();

    final result = await engine.syncNow();

    expect(result.stopReason, SyncRunStopReason.authenticationRequired);
    expect(engine.isAuthenticationRequired('account-a'), isTrue);
    expect(transport.requests, hasLength(1), reason: 'orders not pulled');
  });

  test('network failures leave the checkpoint and report the failure',
      () async {
    transport.handler = (_) => throw const SyncTransportException(
          'offline',
          category: SyncErrorCategory.network,
        );
    engine = await start();

    final result = await engine.syncNow();

    expect(result.pullFailures, 2);
    expect(result.isComplete, isTrue);
    expect(await checkpoint('customers'), isNull);
  });

  test('checkpoints are scoped to the active account', () async {
    customersFeed.pages[null] = {
      'changes': [upsert('c-1', 'Ada')],
      'nextCursor': 'a-cursor',
      'hasMore': false,
    };
    engine = await start();
    await engine.syncNow();

    account = 'account-b';
    await engine.syncNow();

    expect(customersFeed.requestedCursors, [null, null]);
    expect(
      transport.requests.map((r) => r.accountId).toSet(),
      {'account-a', 'account-b'},
    );
  });

  test('pull can be disabled', () async {
    engine = await start(config: const SyncEngineConfig(pullEnabled: false));

    await engine.syncNow();

    expect(transport.requests, isEmpty);
  });

  test('an entity with a pull endpoint requires an adapter', () {
    engine = SyncEngine(
      storage: storage,
      transport: transport,
      requestBuilder: (_) => throw UnimplementedError(),
      activeAccount: () => null,
    );
    expect(
      () => SyncEntity(
        name: 'x',
        endpoint: const RestEndpoint.crud('/x'),
        pull: const PullEndpoint('/x/changes'),
      ),
      throwsArgumentError,
    );
  });

  group('parsePullPage', () {
    PullPage parse(Object? body) =>
        parsePullPage(SyncResponse(statusCode: 200, body: body), 'customers');

    test('parses the documented format', () {
      final page = parse({
        'changes': [
          {
            'entityId': 'c-1',
            'type': 'create',
            'version': 5,
            'data': {'name': 'Ada'},
          },
          {'id': 42, 'type': 'upsert', 'data': <String, Object?>{}},
          {'entityId': 'c-3', 'type': 'delete'},
        ],
        'nextCursor': 'cursor_002',
        'hasMore': true,
      });

      expect(page.nextCursor, 'cursor_002');
      expect(page.hasMore, isTrue);
      expect(
        page.changes.map((c) => '${c.entityId}:${c.type.name}:${c.version}'),
        ['c-1:upsert:5', '42:upsert:null', 'c-3:delete:null'],
      );
      expect(page.changes.first.entityName, 'customers');
      expect(page.changes.first.data, {'name': 'Ada'});
    });

    test('defaults to an empty, finished page', () {
      final page = parse(<String, Object?>{});
      expect(page.changes, isEmpty);
      expect(page.hasMore, isFalse);
      expect(page.nextCursor, isNull);
    });

    test('rejects malformed feeds', () {
      for (final body in <Object?>[
        'text',
        {'changes': 'x'},
        {'hasMore': 'yes'},
        {
          'changes': [
            {'type': 'update', 'data': <String, Object?>{}},
          ],
        },
        {
          'changes': [
            {'entityId': 'c-1', 'type': 'rename'},
          ],
        },
        {
          'changes': [
            {'entityId': 'c-1', 'type': 'update'},
          ],
        },
      ]) {
        expect(() => parse(body), throwsFormatException, reason: '$body');
      }
    });
  });
}
