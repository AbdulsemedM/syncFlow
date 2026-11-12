import 'package:syncflow/syncflow.dart';
import 'package:syncflow_test/syncflow_test.dart';
import 'package:test/test.dart';

void main() {
  late InMemorySyncStorage storage;
  late SyncEntityRegistry entities;
  late RestRequestBuilder builder;
  final t0 = DateTime.utc(2026, 8, 1, 9);

  setUp(() async {
    storage = InMemorySyncStorage();
    await storage.initialize();
    entities = SyncEntityRegistry([
      SyncEntity(
        name: 'customers',
        endpoint: const RestEndpoint.crud('/customers'),
      ),
      SyncEntity(
        name: 'accounts',
        endpoint: const RestEndpoint.crud(
          '/accounts',
          updateMethod: SyncHttpMethod.put,
        ),
        references: {'customerId': 'customers', 'cosigners': 'customers'},
      ),
      SyncEntity(
        name: 'audit-log',
        endpoint: const RestEndpoint(create: '/audit'),
      ),
    ]);
    builder = RestRequestBuilder(
      entities: entities,
      storage: storage,
      timeout: const Duration(seconds: 15),
    );
  });

  tearDown(() => storage.close());

  Future<void> map(String entity, String localId, String serverId) =>
      storage.saveIdMapping(
        SyncIdMapping(
          accountId: 'account-a',
          entityName: entity,
          localId: localId,
          serverId: serverId,
          createdAt: t0,
        ),
      );

  group('SyncEntityRegistry', () {
    test('rejects duplicate names and reports unknown entities', () {
      expect(
        () => entities.register(
          SyncEntity(
              name: 'customers', endpoint: const RestEndpoint.crud('/c')),
        ),
        throwsArgumentError,
      );
      expect(entities['missing'], isNull);
      expect(
        () => entities.require('missing'),
        throwsA(isA<UnknownEntityException>()),
      );
      expect(entities.names, ['customers', 'accounts', 'audit-log']);
    });
  });

  group('RestRequestBuilder', () {
    test('maps creates, updates and deletes to REST requests', () async {
      final create = await builder.build(
        buildTestOperation(id: 'op-1', entityId: 'c-1'),
      );
      final update = await builder.build(
        buildTestOperation(
          id: 'op-2',
          entityId: 'c-1',
          operationType: SyncOperationType.update,
          payload: {'name': 'Renamed'},
        ),
      );
      final delete = await builder.build(
        buildTestOperation(
          id: 'op-3',
          entityId: 'c-1',
          operationType: SyncOperationType.delete,
          payload: const {},
        ),
      );

      expect((create.method, create.path), (SyncHttpMethod.post, '/customers'));
      expect(create.body, {'name': 'Example'});
      expect(create.idempotencyKey, 'idem-op-1');
      expect(create.operationId, 'op-1');
      expect(create.accountId, 'account-a');
      expect(create.timeout, const Duration(seconds: 15));
      expect(
        (update.method, update.path),
        (SyncHttpMethod.patch, '/customers/c-1'),
      );
      expect(update.body, {'name': 'Renamed'});
      expect(
        (delete.method, delete.path),
        (SyncHttpMethod.delete, '/customers/c-1'),
      );
      expect(delete.body, isNull);
    });

    test('URL-encodes ids and honors custom methods', () async {
      final request = await builder.build(
        buildTestOperation(
          id: 'op-1',
          entityName: 'accounts',
          entityId: 'a/b c?',
          operationType: SyncOperationType.update,
        ),
      );

      expect(request.method, SyncHttpMethod.put);
      expect(request.path, '/accounts/a%2Fb%20c%3F');
    });

    test('sends the base version as If-Match', () async {
      final request = await builder.build(
        buildTestOperation(
          id: 'op-1',
          entityId: 'c-1',
          operationType: SyncOperationType.update,
          baseVersion: '"v4"',
        ),
      );
      final unversioned = await builder.build(
        buildTestOperation(id: 'op-2', entityId: 'c-1'),
      );

      expect(request.headers, {'If-Match': '"v4"'});
      expect(unversioned.headers, isEmpty);
    });

    test('resolves temporary ids in paths and declared references', () async {
      await map('customers', 'tmp-c1', 'srv-100');
      await map('customers', 'tmp-c2', 'srv-200');

      final update = await builder.build(
        buildTestOperation(
          id: 'op-1',
          entityId: 'tmp-c1',
          operationType: SyncOperationType.update,
        ),
      );
      final account = await builder.build(
        buildTestOperation(
          id: 'op-2',
          entityName: 'accounts',
          entityId: 'acc-1',
          payload: {
            'customerId': 'tmp-c1',
            'cosigners': ['tmp-c2', 'known-server-id', 7],
            'note': 'tmp-c1',
          },
        ),
      );

      expect(update.path, '/customers/srv-100');
      expect(account.body, {
        'customerId': 'srv-100',
        'cosigners': ['srv-200', 'known-server-id', 7],
        'note': 'tmp-c1',
      });
    });

    test('mappings are scoped by account and entity', () async {
      await map('accounts', 'tmp-c1', 'srv-wrong-entity');

      final request = await builder.build(
        buildTestOperation(
          id: 'op-1',
          entityId: 'tmp-c1',
          operationType: SyncOperationType.update,
        ),
      );

      expect(request.path, '/customers/tmp-c1');
    });

    test('reports misconfigured operations', () async {
      await expectLater(
        builder.build(buildTestOperation(id: 'op-1', entityName: 'nope')),
        throwsA(isA<UnknownEntityException>()),
      );
      await expectLater(
        builder.build(
          buildTestOperation(
            id: 'op-2',
            entityName: 'audit-log',
            operationType: SyncOperationType.delete,
          ),
        ),
        throwsA(isA<UnsupportedOperationTypeException>()),
      );
    });

    test('delegates to a per-entity request builder', () async {
      entities.register(
        SyncEntity(
          name: 'legacy',
          endpoint: const RestEndpoint(create: '/unused'),
          requestBuilder: (operation) => SyncRequest(
            method: SyncHttpMethod.post,
            path: '/rpc/legacy.${operation.operationType.name}',
            accountId: operation.accountId,
            body: {'args': operation.payload},
          ),
        ),
      );

      final request = await builder.build(
        buildTestOperation(id: 'op-1', entityName: 'legacy'),
      );

      expect(request.path, '/rpc/legacy.create');
      expect(request.body, {
        'args': {'name': 'Example'},
      });
    });
  });

  group('serverIdFromBodyId', () {
    test('reads string and numeric ids from JSON bodies', () {
      SyncResponse body(Object? value) =>
          SyncResponse(statusCode: 201, body: value);

      expect(serverIdFromBodyId(body({'id': 'srv-1'})), 'srv-1');
      expect(serverIdFromBodyId(body({'id': 42})), '42');
      expect(serverIdFromBodyId(body({'id': ''})), isNull);
      expect(serverIdFromBodyId(body({'uuid': 'x'})), isNull);
      expect(serverIdFromBodyId(body('srv-1')), isNull);
      expect(serverIdFromBodyId(body(null)), isNull);
    });
  });

  group('temporary id rewriting through the engine', () {
    late FakeClock clock;
    late FakeSyncTransport transport;
    late OperationQueue queue;
    late SyncEngine engine;
    late List<SyncEvent> events;
    var nextServerId = 100;

    setUp(() async {
      clock = FakeClock(t0);
      nextServerId = 100;
      transport = FakeSyncTransport(
        handler: (request) => SyncResponse(
          statusCode: request.method == SyncHttpMethod.post ? 201 : 200,
          body: request.method == SyncHttpMethod.post
              ? {'id': 'srv-${nextServerId++}'}
              : null,
        ),
      );
      queue = OperationQueue(storage: storage, clock: clock);
      engine = SyncEngine(
        storage: storage,
        transport: transport,
        requestBuilder: builder.build,
        entities: entities,
        activeAccount: () => 'account-a',
        config: const SyncEngineConfig(maxConcurrentOperations: 1),
        clock: clock,
      );
      events = [];
      engine.events.listen(events.add);
      await engine.initialize();
    });

    tearDown(() => engine.close());

    test('operations queued offline follow the server-assigned id', () async {
      // Offline: create a customer and an account for it, then edit both.
      await queue.enqueue(
        SyncMutation.create(
          entity: 'customers',
          id: 'tmp-c1',
          data: const {'name': 'Ada'},
        ),
        accountId: 'account-a',
      );
      await queue.enqueue(
        SyncMutation.update(
          entity: 'customers',
          id: 'tmp-c1',
          data: const {'name': 'Ada L.'},
        ),
        accountId: 'account-a',
      );
      final createCustomer = (await storage.getEligibleOperations(
        accountId: 'account-a',
        now: clock.now(),
        limit: 1,
      ))
          .single;
      await queue.enqueue(
        SyncMutation.create(
          entity: 'accounts',
          id: 'tmp-a1',
          data: const {'customerId': 'tmp-c1'},
          dependencies: [createCustomer.id],
        ),
        accountId: 'account-a',
      );
      await queue.enqueue(
        SyncMutation.delete(entity: 'accounts', id: 'tmp-a1'),
        accountId: 'account-a',
      );

      final result = await engine.syncNow();
      await pumpEventQueue();

      expect(result.acknowledged, 4);
      expect(
        [for (final r in transport.requests) '${r.method.name} ${r.path}'],
        [
          'post /customers',
          'patch /customers/srv-100',
          'post /accounts',
          'delete /accounts/srv-101',
        ],
      );
      expect(transport.requests[2].body, {'customerId': 'srv-100'});
      expect(
        events.whereType<EntityIdAssigned>().map(
              (e) => '${e.entityName}:${e.localId}->${e.serverId}',
            ),
        ['customers:tmp-c1->srv-100', 'accounts:tmp-a1->srv-101'],
      );
    });

    test('no mapping is recorded when the server keeps the client id',
        () async {
      transport.handler = (request) => SyncResponse(
            statusCode: 201,
            body: {'id': 'c-1'},
          );
      await queue.enqueue(
        SyncMutation.create(entity: 'customers', id: 'c-1', data: const {}),
        accountId: 'account-a',
      );

      await engine.syncNow();
      await pumpEventQueue();

      expect(events.whereType<EntityIdAssigned>(), isEmpty);
      expect(
        await storage.resolveServerId(
          accountId: 'account-a',
          entityName: 'customers',
          localId: 'c-1',
        ),
        isNull,
      );
    });

    test('a lost lease records neither acknowledgement nor mapping', () async {
      final shortLease = SyncEngine(
        storage: storage,
        transport: transport,
        requestBuilder: builder.build,
        entities: entities,
        activeAccount: () => 'account-a',
        config: const SyncEngineConfig(leaseDuration: Duration(seconds: 5)),
        clock: clock,
      );
      await shortLease.initialize();
      addTearDown(shortLease.close);
      transport.enqueueHandler((_) async {
        clock.advance(const Duration(seconds: 6));
        await storage.recoverExpiredLeases(clock.now());
        return SyncResponse(statusCode: 201, body: {'id': 'srv-9'});
      });
      await queue.enqueue(
        SyncMutation.create(entity: 'customers', id: 'tmp-c1', data: const {}),
        accountId: 'account-a',
      );

      final result = await shortLease.syncNow();

      expect(result.leaseLost, 1);
      expect(
        await storage.resolveServerId(
          accountId: 'account-a',
          entityName: 'customers',
          localId: 'tmp-c1',
        ),
        isNull,
      );
    });

    test('an unknown entity is rejected without being sent', () async {
      final operation = await queue.enqueue(
        SyncMutation.create(entity: 'invoices', id: 'i-1', data: const {}),
        accountId: 'account-a',
      );

      final result = await engine.syncNow();

      expect(result.rejected, 1);
      expect(transport.requests, isEmpty);
      expect(
        (await storage.getOperation(operation.id))!.lastError!.category,
        SyncErrorCategory.serialization,
      );
    });
  });
}
