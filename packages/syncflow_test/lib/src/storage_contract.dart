import 'dart:async';

import 'package:syncflow/syncflow.dart';
import 'package:test/test.dart';

import 'operation_builder.dart';

/// Registers the [SyncStorage] contract test suite.
///
/// Every storage adapter should call this from its own tests, passing a
/// factory that returns a fresh, empty, uninitialized storage:
///
/// ```dart
/// void main() {
///   runSyncStorageContractTests(() => MyStorage.inMemory());
/// }
/// ```
void runSyncStorageContractTests(
  FutureOr<SyncStorage> Function() createStorage,
) {
  group('SyncStorage contract', () {
    late SyncStorage storage;
    final t0 = DateTime.utc(2026, 1, 1, 12);

    setUp(() async {
      storage = await createStorage();
      await storage.initialize();
    });

    tearDown(() => storage.close());

    group('insert and read', () {
      test('round-trips every field', () async {
        final operation = buildTestOperation(
          id: 'op-1',
          operationType: SyncOperationType.update,
          payload: {
            'name': 'Ada',
            'tags': ['a', 'b'],
            'address': {'city': 'Addis Ababa', 'zip': null},
            'score': 4.5,
          },
          status: SyncOperationStatus.retryScheduled,
          baseVersion: '7',
          attempts: 2,
          createdAt: t0,
          nextAttemptAt: t0.add(const Duration(seconds: 30)),
          lastError: SyncError(
            category: SyncErrorCategory.server,
            message: 'Service unavailable',
            isRetryable: true,
            httpStatus: 503,
            occurredAt: t0,
            operationId: 'op-1',
          ),
        );
        await storage.insertOperation(buildTestOperation(id: 'dep-1'));
        await storage.insertOperation(
          operation.copyWith(dependencies: ['dep-1']),
        );

        final read = await storage.getOperation('op-1');

        expect(read, isNotNull);
        expect(read!.toJson(), {
          ...operation.toJson(),
          'dependencies': ['dep-1'],
        });
      });

      test('returns null for an unknown id', () async {
        expect(await storage.getOperation('missing'), isNull);
      });

      test('rejects a duplicate id', () async {
        await storage.insertOperation(buildTestOperation(id: 'op-1'));
        await expectLater(
          storage.insertOperation(buildTestOperation(id: 'op-1')),
          throwsA(isA<DuplicateOperationException>()),
        );
      });

      test('batch insert stores all operations', () async {
        await storage.insertOperations([
          buildTestOperation(id: 'op-1'),
          buildTestOperation(id: 'op-2'),
        ]);
        expect(await storage.getOperation('op-1'), isNotNull);
        expect(await storage.getOperation('op-2'), isNotNull);
      });

      test('batch insert is atomic when an id already exists', () async {
        await storage.insertOperation(buildTestOperation(id: 'op-2'));
        await expectLater(
          storage.insertOperations([
            buildTestOperation(id: 'op-1'),
            buildTestOperation(id: 'op-2'),
          ]),
          throwsA(isA<DuplicateOperationException>()),
        );
        expect(await storage.getOperation('op-1'), isNull);
      });

      test('batch insert rejects duplicates within the batch', () async {
        await expectLater(
          storage.insertOperations([
            buildTestOperation(id: 'op-1'),
            buildTestOperation(id: 'op-1'),
          ]),
          throwsA(isA<DuplicateOperationException>()),
        );
        expect(await storage.getOperation('op-1'), isNull);
      });
    });

    group('update', () {
      test('stores changes and increments the revision', () async {
        await storage.insertOperation(buildTestOperation(id: 'op-1'));
        final read = (await storage.getOperation('op-1'))!;

        final updated = await storage.updateOperation(
          read.copyWith(attempts: 3, updatedAt: t0),
        );

        expect(updated.revision, read.revision + 1);
        expect(updated.attempts, 3);
        final reread = (await storage.getOperation('op-1'))!;
        expect(reread.revision, updated.revision);
        expect(reread.attempts, 3);
      });

      test('rejects an update based on a stale revision', () async {
        await storage.insertOperation(buildTestOperation(id: 'op-1'));
        final read = (await storage.getOperation('op-1'))!;
        await storage.updateOperation(read.copyWith(attempts: 1));

        await expectLater(
          storage.updateOperation(read.copyWith(attempts: 2)),
          throwsA(isA<StaleOperationException>()),
        );
        expect((await storage.getOperation('op-1'))!.attempts, 1);
      });

      test('rejects an update of an unknown operation', () async {
        await expectLater(
          storage.updateOperation(buildTestOperation(id: 'missing')),
          throwsA(isA<OperationNotFoundException>()),
        );
      });

      test('delete removes the operation and ignores unknown ids', () async {
        await storage.insertOperation(buildTestOperation(id: 'op-1'));
        await storage.deleteOperation('op-1');
        await storage.deleteOperation('missing');
        expect(await storage.getOperation('op-1'), isNull);
      });
    });

    group('eligibility', () {
      Future<List<String>> eligibleIds({
        String accountId = 'account-a',
        DateTime? now,
        int limit = 100,
      }) async {
        final operations = await storage.getEligibleOperations(
          accountId: accountId,
          now: now ?? t0,
          limit: limit,
        );
        return [for (final operation in operations) operation.id];
      }

      test('includes only due pending and retry-scheduled operations',
          () async {
        await storage.insertOperations([
          for (final status in SyncOperationStatus.values)
            buildTestOperation(id: status.name, status: status, createdAt: t0),
          buildTestOperation(
            id: 'retry-later',
            status: SyncOperationStatus.retryScheduled,
            createdAt: t0,
            nextAttemptAt: t0.add(const Duration(seconds: 1)),
          ),
          buildTestOperation(
            id: 'pending-later',
            createdAt: t0,
            nextAttemptAt: t0.add(const Duration(seconds: 1)),
          ),
        ]);

        expect(await eligibleIds(), ['pending', 'retryScheduled']);
        expect(
          await eligibleIds(now: t0.add(const Duration(seconds: 1))),
          ['pending', 'retryScheduled', 'retry-later', 'pending-later'],
        );
      });

      test('orders by creation time, then insertion order', () async {
        await storage.insertOperations([
          buildTestOperation(id: 'c', createdAt: t0.add(Duration(seconds: 2))),
          buildTestOperation(id: 'b', createdAt: t0),
          buildTestOperation(id: 'a', createdAt: t0),
          buildTestOperation(id: 'd', createdAt: t0.add(Duration(seconds: 1))),
        ]);

        expect(
          await eligibleIds(now: t0.add(const Duration(minutes: 1))),
          ['b', 'a', 'd', 'c'],
        );
      });

      test('keeps insertion order after updates', () async {
        await storage.insertOperation(buildTestOperation(id: 'first'));
        await storage.insertOperation(buildTestOperation(id: 'second'));
        final first = (await storage.getOperation('first'))!;
        await storage.updateOperation(first.copyWith(attempts: 1));

        expect(await eligibleIds(), ['first', 'second']);
      });

      test('is isolated by account', () async {
        await storage.insertOperations([
          buildTestOperation(id: 'a-1', accountId: 'account-a'),
          buildTestOperation(id: 'b-1', accountId: 'account-b'),
        ]);

        expect(await eligibleIds(accountId: 'account-a'), ['a-1']);
        expect(await eligibleIds(accountId: 'account-b'), ['b-1']);
        expect(await eligibleIds(accountId: 'account-c'), isEmpty);
      });

      test('respects the limit', () async {
        await storage.insertOperations([
          for (var i = 0; i < 5; i++)
            buildTestOperation(
              id: 'op-$i',
              createdAt: t0.add(Duration(seconds: i)),
            ),
        ]);

        expect(
          await eligibleIds(now: t0.add(const Duration(minutes: 1)), limit: 2),
          ['op-0', 'op-1'],
        );
      });
    });

    group('leases', () {
      final expiry = t0.add(const Duration(minutes: 5));

      test('acquiring moves a pending operation to leased', () async {
        await storage.insertOperation(buildTestOperation(id: 'op-1'));

        final leased = await storage.acquireLease(
          operationId: 'op-1',
          workerId: 'worker-a',
          now: t0,
          expiresAt: expiry,
        );

        expect(leased, isNotNull);
        expect(leased!.status, SyncOperationStatus.leased);
        expect(leased.leaseOwner, 'worker-a');
        expect(leased.leaseExpiresAt, expiry);
        expect(leased.revision, 1);
        expect(leased.idempotencyKey, 'idem-op-1');
        expect((await storage.getOperation('op-1'))!.leaseOwner, 'worker-a');
      });

      test('only one worker can hold a lease', () async {
        await storage.insertOperation(buildTestOperation(id: 'op-1'));

        final results = await Future.wait([
          for (final worker in ['worker-a', 'worker-b', 'worker-c'])
            storage.acquireLease(
              operationId: 'op-1',
              workerId: worker,
              now: t0,
              expiresAt: expiry,
            ),
        ]);

        expect(results.whereType<SyncOperation>(), hasLength(1));
      });

      test('a due retry can be claimed; a future retry cannot', () async {
        await storage.insertOperations([
          buildTestOperation(
            id: 'due',
            status: SyncOperationStatus.retryScheduled,
            nextAttemptAt: t0,
          ),
          buildTestOperation(
            id: 'later',
            status: SyncOperationStatus.retryScheduled,
            nextAttemptAt: t0.add(const Duration(seconds: 1)),
          ),
        ]);

        Future<SyncOperation?> claim(String id) => storage.acquireLease(
              operationId: id,
              workerId: 'worker-a',
              now: t0,
              expiresAt: expiry,
            );

        expect(await claim('due'), isNotNull);
        expect(await claim('later'), isNull);
      });

      test('cannot claim unknown, terminal or blocked operations', () async {
        await storage.insertOperations([
          for (final status in [
            SyncOperationStatus.sending,
            SyncOperationStatus.conflict,
            SyncOperationStatus.rejected,
            SyncOperationStatus.acknowledged,
            SyncOperationStatus.cancelled,
          ])
            buildTestOperation(id: status.name, status: status),
        ]);

        for (final id in [
          'missing',
          'sending',
          'conflict',
          'rejected',
          'acknowledged',
          'cancelled',
        ]) {
          final result = await storage.acquireLease(
            operationId: id,
            workerId: 'worker-a',
            now: t0,
            expiresAt: expiry,
          );
          expect(result, isNull, reason: id);
        }
      });

      test('release by the owner returns the operation to pending', () async {
        await storage.insertOperation(buildTestOperation(id: 'op-1'));
        await storage.acquireLease(
          operationId: 'op-1',
          workerId: 'worker-a',
          now: t0,
          expiresAt: expiry,
        );

        expect(
          await storage.releaseLease(
            operationId: 'op-1',
            workerId: 'worker-b',
            now: t0,
          ),
          isFalse,
        );
        expect(
          await storage.releaseLease(
            operationId: 'op-1',
            workerId: 'worker-a',
            now: t0,
          ),
          isTrue,
        );

        final released = (await storage.getOperation('op-1'))!;
        expect(released.status, SyncOperationStatus.pending);
        expect(released.leaseOwner, isNull);
        expect(released.leaseExpiresAt, isNull);
      });

      test('release does not apply once the operation is sending', () async {
        await storage.insertOperation(
          buildTestOperation(
            id: 'op-1',
            status: SyncOperationStatus.sending,
            leaseOwner: 'worker-a',
            leaseExpiresAt: expiry,
          ),
        );

        expect(
          await storage.releaseLease(
            operationId: 'op-1',
            workerId: 'worker-a',
            now: t0,
          ),
          isFalse,
        );
        expect(
          (await storage.getOperation('op-1'))!.status,
          SyncOperationStatus.sending,
        );
      });

      test('recovers expired leases and preserves identity', () async {
        await storage.insertOperations([
          buildTestOperation(
            id: 'leased-expired',
            status: SyncOperationStatus.leased,
            leaseExpiresAt: t0,
          ),
          buildTestOperation(
            id: 'sending-expired',
            status: SyncOperationStatus.sending,
            attempts: 1,
            leaseExpiresAt: t0.subtract(const Duration(seconds: 1)),
          ),
          buildTestOperation(
            id: 'leased-active',
            status: SyncOperationStatus.leased,
            leaseExpiresAt: t0.add(const Duration(seconds: 1)),
          ),
        ]);

        expect(await storage.recoverExpiredLeases(t0), 2);

        final leasedExpired = (await storage.getOperation('leased-expired'))!;
        final sendingExpired = (await storage.getOperation('sending-expired'))!;
        final active = (await storage.getOperation('leased-active'))!;

        expect(leasedExpired.status, SyncOperationStatus.pending);
        expect(leasedExpired.leaseOwner, isNull);
        expect(sendingExpired.status, SyncOperationStatus.pending);
        expect(sendingExpired.idempotencyKey, 'idem-sending-expired');
        expect(sendingExpired.attempts, 1);
        expect(active.status, SyncOperationStatus.leased);
        expect(await storage.recoverExpiredLeases(t0), 0);
      });

      test('a worker with an expired lease cannot overwrite recovered state',
          () async {
        await storage.insertOperation(buildTestOperation(id: 'op-1'));
        final leased = (await storage.acquireLease(
          operationId: 'op-1',
          workerId: 'worker-a',
          now: t0,
          expiresAt: expiry,
        ))!;
        await storage.recoverExpiredLeases(expiry);

        final stale = leased.transitionTo(SyncOperationStatus.sending, at: t0);
        await expectLater(
          storage.updateOperation(stale),
          throwsA(isA<StaleOperationException>()),
        );
        expect(
          (await storage.getOperation('op-1'))!.status,
          SyncOperationStatus.pending,
        );
      });
    });

    group('checkpoints', () {
      SyncCheckpoint checkpoint(String account, String entity, String cursor) =>
          SyncCheckpoint(
            accountId: account,
            entityName: entity,
            cursor: cursor,
            updatedAt: t0,
          );

      test('saves, replaces and scopes by account and entity', () async {
        expect(
          await storage.getCheckpoint(
            accountId: 'account-a',
            entityName: 'customers',
          ),
          isNull,
        );

        await storage.saveCheckpoint(checkpoint('account-a', 'customers', '1'));
        await storage.saveCheckpoint(checkpoint('account-a', 'customers', '2'));
        await storage.saveCheckpoint(checkpoint('account-b', 'customers', '9'));
        await storage.saveCheckpoint(checkpoint('account-a', 'orders', '5'));

        Future<String?> cursor(String account, String entity) async =>
            (await storage.getCheckpoint(
              accountId: account,
              entityName: entity,
            ))
                ?.cursor;

        expect(await cursor('account-a', 'customers'), '2');
        expect(await cursor('account-b', 'customers'), '9');
        expect(await cursor('account-a', 'orders'), '5');
      });
    });
  });
}
