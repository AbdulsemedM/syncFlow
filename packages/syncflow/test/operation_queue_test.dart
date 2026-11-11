import 'package:syncflow/syncflow.dart';
import 'package:syncflow_test/syncflow_test.dart';
import 'package:test/test.dart';

void main() {
  late InMemorySyncStorage storage;
  late FakeClock clock;
  late OperationQueue queue;

  setUp(() async {
    storage = InMemorySyncStorage();
    await storage.initialize();
    clock = FakeClock(DateTime.utc(2026, 2, 1));
    queue = OperationQueue(
      storage: storage,
      clock: clock,
      idGenerator: SequentialIdGenerator(prefix: 'gen'),
    );
  });

  tearDown(() => storage.close());

  SyncMutation createCustomer(String id, {List<String> dependsOn = const []}) =>
      SyncMutation.create(
        entity: 'customers',
        id: id,
        data: {'name': 'Customer $id'},
        dependencies: dependsOn,
      );

  group('enqueue', () {
    test('persists a pending operation with stable identifiers', () async {
      final operation = await queue.enqueue(
        createCustomer('c-1'),
        accountId: 'account-a',
      );

      expect(operation.id, 'gen-1');
      expect(operation.idempotencyKey, 'gen-2');
      expect(operation.status, SyncOperationStatus.pending);
      expect(operation.entityName, 'customers');
      expect(operation.entityId, 'c-1');
      expect(operation.operationType, SyncOperationType.create);
      expect(operation.payload, {'name': 'Customer c-1'});
      expect(operation.createdAt, clock.now());

      final stored = await queue.get(operation.id);
      expect(stored?.toJson(), operation.toJson());
    });

    test('uses an explicit idempotency key when provided', () async {
      final operation = await queue.enqueue(
        SyncMutation.update(
          entity: 'customers',
          id: 'c-1',
          data: const {'name': 'New'},
          baseVersion: '4',
          idempotencyKey: 'app-key-1',
        ),
        accountId: 'account-a',
      );

      expect(operation.idempotencyKey, 'app-key-1');
      expect(operation.baseVersion, '4');
      expect(operation.operationType, SyncOperationType.update);
    });

    test('delete mutations carry an empty payload', () async {
      final operation = await queue.enqueue(
        SyncMutation.delete(entity: 'customers', id: 'c-1', baseVersion: '9'),
        accountId: 'account-a',
      );

      expect(operation.operationType, SyncOperationType.delete);
      expect(operation.payload, isEmpty);
    });

    test('accepts dependencies on existing operations', () async {
      final customer = await queue.enqueue(
        createCustomer('c-1'),
        accountId: 'account-a',
      );
      final account = await queue.enqueue(
        SyncMutation.create(
          entity: 'accounts',
          id: 'acc-1',
          data: const {'customerId': 'c-1'},
          dependencies: [customer.id, customer.id],
        ),
        accountId: 'account-a',
      );

      expect(account.dependencies, [customer.id], reason: 'deduplicated');
    });

    test('rejects unknown dependencies without persisting', () async {
      await expectLater(
        queue.enqueue(
          createCustomer('c-1', dependsOn: ['missing']),
          accountId: 'account-a',
        ),
        throwsA(isA<InvalidDependencyException>()),
      );
      expect(storage.length, 0);
    });

    test('rejects dependencies from another account', () async {
      final other = await queue.enqueue(
        createCustomer('c-1'),
        accountId: 'account-b',
      );

      await expectLater(
        queue.enqueue(
          createCustomer('c-2', dependsOn: [other.id]),
          accountId: 'account-a',
        ),
        throwsA(isA<InvalidDependencyException>()),
      );
    });
  });

  group('eligible', () {
    test('returns operations in FIFO order', () async {
      final ids = <String>[];
      for (var i = 0; i < 5; i++) {
        ids.add(
          (await queue.enqueue(createCustomer('c-$i'), accountId: 'account-a'))
              .id,
        );
        if (i.isEven) clock.advance(const Duration(milliseconds: 1));
      }

      final eligible = await queue.eligible(accountId: 'account-a');

      expect([for (final o in eligible) o.id], ids);
    });

    test('is isolated by account', () async {
      await queue.enqueue(createCustomer('a'), accountId: 'account-a');
      await queue.enqueue(createCustomer('b'), accountId: 'account-b');

      final eligible = await queue.eligible(accountId: 'account-b');

      expect([for (final o in eligible) o.entityId], ['b']);
    });

    test('honors the limit and rejects non-positive limits', () async {
      for (var i = 0; i < 3; i++) {
        await queue.enqueue(createCustomer('c-$i'), accountId: 'account-a');
      }

      expect(
          await queue.eligible(accountId: 'account-a', limit: 2), hasLength(2));
      expect(
        () => queue.eligible(accountId: 'account-a', limit: 0),
        throwsArgumentError,
      );
    });

    test('excludes retries until they are due', () async {
      final operation = await queue.enqueue(
        createCustomer('c-1'),
        accountId: 'account-a',
      );
      final leased = (await storage.acquireLease(
        operationId: operation.id,
        workerId: 'worker-a',
        now: clock.now(),
        expiresAt: clock.now().add(const Duration(minutes: 1)),
      ))!;
      final sending = await storage.updateOperation(
        leased.transitionTo(SyncOperationStatus.sending, at: clock.now()),
      );
      await storage.updateOperation(
        sending
            .transitionTo(SyncOperationStatus.retryScheduled, at: clock.now())
            .copyWith(
              attempts: 1,
              nextAttemptAt: clock.now().add(const Duration(seconds: 30)),
            ),
      );

      expect(await queue.eligible(accountId: 'account-a'), isEmpty);
      clock.advance(const Duration(seconds: 30));
      final due = await queue.eligible(accountId: 'account-a');
      expect(due.single.idempotencyKey, operation.idempotencyKey);
    });
  });

  group('cancel', () {
    test('cancels a pending operation', () async {
      final operation = await queue.enqueue(
        createCustomer('c-1'),
        accountId: 'account-a',
      );

      final cancelled = await queue.cancel(operation.id);

      expect(cancelled.status, SyncOperationStatus.cancelled);
      expect(await queue.eligible(accountId: 'account-a'), isEmpty);
    });

    test('refuses to cancel an in-flight operation', () async {
      final operation = await queue.enqueue(
        createCustomer('c-1'),
        accountId: 'account-a',
      );
      await storage.acquireLease(
        operationId: operation.id,
        workerId: 'worker-a',
        now: clock.now(),
        expiresAt: clock.now().add(const Duration(minutes: 1)),
      );

      await expectLater(
        queue.cancel(operation.id),
        throwsA(isA<InvalidStateTransitionException>()),
      );
    });

    test('reports unknown operations', () async {
      await expectLater(
        queue.cancel('missing'),
        throwsA(isA<OperationNotFoundException>()),
      );
    });
  });

  group('UuidV4Generator', () {
    test('produces unique RFC 4122 version 4 identifiers', () {
      const generator = UuidV4Generator();
      final pattern = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      final ids = {for (var i = 0; i < 1000; i++) generator.next()};

      expect(ids, hasLength(1000));
      expect(ids.every(pattern.hasMatch), isTrue);
    });
  });
}
