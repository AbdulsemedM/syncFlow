import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncflow/syncflow.dart';
import 'package:syncflow_inspector/syncflow_inspector.dart';
import 'package:syncflow_test/syncflow_test.dart';

void main() {
  group('SyncRedactor', () {
    const redactor = SyncRedactor();

    test('redacts sensitive keys, whatever their spelling or nesting', () {
      final redacted = redactor.redactMap({
        'name': 'Ada',
        'password': 'hunter2',
        'access_token': 'abc',
        'Refresh-Token': 'def',
        'PIN': 1234,
        'profile': {
          'newPassword': 'x',
          'cards': [
            {'cardNumber': '4111', 'label': 'work'},
          ],
          'secret': {'nested': 'whole subtree'},
        },
      });

      expect(redacted, {
        'name': 'Ada',
        'password': '[REDACTED]',
        'access_token': '[REDACTED]',
        'Refresh-Token': '[REDACTED]',
        'PIN': '[REDACTED]',
        'profile': {
          'newPassword': '[REDACTED]',
          'cards': [
            {'cardNumber': '[REDACTED]', 'label': 'work'},
          ],
          'secret': '[REDACTED]',
        },
      });
    });

    test('matches short keys exactly, not as fragments', () {
      expect(
        redactor.redactMap({'shipping': 'express', 'pinned': true}),
        {'shipping': 'express', 'pinned': true},
      );
    });

    test('does not modify the input', () {
      final payload = {
        'password': 'hunter2',
        'nested': {'token': 't'},
      };
      redactor.redactMap(payload);
      expect(payload['password'], 'hunter2');
      expect(payload['nested'], {'token': 't'});
    });

    test('supports extra keys and masking every value', () {
      expect(
        redactor.withKeys(['Email_Address']).redactMap(
          {'emailAddress': 'a@b.c', 'name': 'Ada'},
        ),
        {'emailAddress': '[REDACTED]', 'name': 'Ada'},
      );
      expect(
        const SyncRedactor(maskAllValues: true).redactMap({
          'name': 'Ada',
          'age': 36,
          'active': true,
          'note': null,
          'tags': ['a'],
        }),
        {
          'name': '<string>',
          'age': '<number>',
          'active': '<bool>',
          'note': null,
          'tags': ['<string>'],
        },
      );
    });

    test('masks identifiers but keeps the last four characters', () {
      expect(SyncRedactor.maskIdentifier('0123456789'), '••••6789');
      expect(SyncRedactor.maskIdentifier('abc'), '••••');
    });
  });

  group('SyncInspector', () {
    late InMemorySyncStorage storage;
    late FakeClock clock;
    late FakeSyncTransport transport;
    late OperationQueue queue;
    late SyncEngine engine;
    late SyncInspector inspector;
    String? account;

    setUp(() async {
      account = 'account-a';
      storage = InMemorySyncStorage();
      await storage.initialize();
      clock = FakeClock(DateTime.utc(2026, 11, 1, 9));
      transport = FakeSyncTransport();
      queue = OperationQueue(
        storage: storage,
        clock: clock,
        idGenerator: SequentialIdGenerator(),
      );
      engine = SyncEngine(
        storage: storage,
        transport: transport,
        activeAccount: () => account,
        requestBuilder: (op) => SyncRequest(
          method: SyncHttpMethod.post,
          path: '/${op.entityName}',
          accountId: op.accountId,
          body: op.payload,
        ),
        retryPolicy: ExponentialBackoffRetryPolicy(jitter: 0),
        clock: clock,
      );
      await engine.initialize();
      inspector = SyncInspector(
        engine: engine,
        storage: storage,
        queue: queue,
        enabled: true,
        clock: clock,
      )..start();
    });

    tearDown(() async {
      inspector.dispose();
      await engine.close();
      await storage.close();
    });

    // Engine events are delivered asynchronously; let them arrive.
    Future<void> sync() async {
      await engine.syncNow();
      await pumpEventQueue();
    }

    Future<SyncOperation> enqueue(
      String id, {
      Map<String, Object?> data = const {'name': 'Ada'},
      String accountId = 'account-a',
    }) =>
        queue.enqueue(
          SyncMutation.create(entity: 'customers', id: id, data: data),
          accountId: accountId,
        );

    test('records engine events newest first', () async {
      await enqueue('c-1');
      await sync();

      expect(
        [for (final event in inspector.timeline) event.kind],
        [
          InspectorEventKind.runCompleted,
          InspectorEventKind.acknowledged,
          InspectorEventKind.runStarted,
        ],
      );
      expect(inspector.timeline[1].httpStatus, 200);
    });

    test('keeps at most maxTimelineEvents entries', () async {
      final small = SyncInspector(
        engine: engine,
        storage: storage,
        enabled: true,
        maxTimelineEvents: 2,
      )..start();
      await enqueue('c-1');
      await sync();

      expect(
        [for (final event in small.timeline) event.kind],
        [InspectorEventKind.runCompleted, InspectorEventKind.acknowledged],
      );
      small.dispose();
    });

    test('notifies listeners when an event is recorded', () async {
      var notifications = 0;
      inspector.addListener(() => notifications++);
      await sync();
      expect(notifications, 2); // run started, run completed
    });

    test('snapshot reports counts and the last successful sync', () async {
      await enqueue('c-1');
      await enqueue('c-2');
      await enqueue('c-3');
      transport
        ..enqueueStatus(200)
        ..enqueueStatus(422)
        ..enqueueStatus(503);
      await sync();

      final snapshot = await inspector.loadSnapshot();

      expect(snapshot.accountId, 'account-a');
      expect(snapshot.completed, 1);
      expect(snapshot.rejected, 1);
      expect(snapshot.pending, 1);
      expect(snapshot.lastRunResult!.acknowledged, 1);
      expect(snapshot.lastSuccessfulSyncAt, clock.now());
      expect(snapshot.isPaused, isFalse);
    });

    test('a run that did not complete is not a successful sync', () async {
      await enqueue('c-1');
      transport.enqueueStatus(401);
      await sync();

      final snapshot = await inspector.loadSnapshot();
      expect(
        snapshot.lastRunResult!.stopReason,
        SyncRunStopReason.authenticationRequired,
      );
      expect(snapshot.lastSuccessfulSyncAt, isNull);
      expect(snapshot.authenticationRequired, isTrue);
    });

    test('without an active account, the snapshot is empty', () async {
      await enqueue('c-1');
      account = null;

      final snapshot = await inspector.loadSnapshot();
      expect(snapshot.accountId, isNull);
      expect(snapshot.counts, isEmpty);
      expect(snapshot.conflicts, isEmpty);
    });

    test('lists only the active account, newest first, filtered', () async {
      await enqueue('c-1');
      clock.advance(const Duration(seconds: 1));
      await enqueue('c-2');
      await enqueue('b-1', accountId: 'account-b');
      transport.enqueueStatus(422);
      await sync(); // c-1 rejected, c-2 acknowledged

      final all = await inspector.listOperations();
      expect([for (final op in all) op.entityId], ['c-2', 'c-1']);

      final rejected = await inspector.listOperations(
        statuses: {SyncOperationStatus.rejected},
      );
      expect([for (final op in rejected) op.entityId], ['c-1']);

      account = null;
      expect(await inspector.listOperations(), isEmpty);
    });

    group('operation details', () {
      test('redact the payload and mask the idempotency key', () async {
        final op = await enqueue(
          'c-1',
          data: const {'name': 'Ada', 'password': 'hunter2'},
        );

        final details = (await inspector.loadOperation(op.id))!;

        expect(details.payload, {'name': 'Ada', 'password': '[REDACTED]'});
        expect(details.idempotencyKey, isNot(op.idempotencyKey));
        expect(details.idempotencyKey, startsWith('••••'));
        expect(
          op.idempotencyKey,
          endsWith(details.idempotencyKey.substring(4)),
        );
      });

      test('can expose idempotency keys when configured', () async {
        final op = await enqueue('c-1');
        final exposing = SyncInspector(
          engine: engine,
          storage: storage,
          enabled: true,
          exposeIdempotencyKeys: true,
        );

        final details = (await exposing.loadOperation(op.id))!;
        expect(details.idempotencyKey, op.idempotencyKey);
        exposing.dispose();
      });

      test('include dependencies, dependents and history', () async {
        final create = await enqueue('c-1');
        final update = await queue.enqueue(
          SyncMutation.update(
            entity: 'customers',
            id: 'c-1',
            data: const {'name': 'Ada L.'},
          ),
          accountId: 'account-a',
        );
        transport.enqueueStatus(503);
        await sync();

        final updateDetails = (await inspector.loadOperation(update.id))!;
        expect(updateDetails.dependencies, hasLength(1));
        expect(updateDetails.dependencies.single.id, create.id);
        expect(
          updateDetails.dependencies.single.status,
          SyncOperationStatus.retryScheduled,
        );
        expect(updateDetails.dependencies.single.isSatisfied, isFalse);

        final createDetails = (await inspector.loadOperation(create.id))!;
        expect([for (final op in createDetails.dependents) op.id], [update.id]);
        expect(
          [for (final event in createDetails.history) event.kind],
          [InspectorEventKind.retryScheduled],
        );
        expect(createDetails.history.single.summary, contains('server'));
      });

      test('are hidden for other accounts and missing operations', () async {
        final other = await enqueue('b-1', accountId: 'account-b');

        expect(await inspector.loadOperation(other.id), isNull);
        expect(await inspector.loadOperation('missing'), isNull);
      });

      test('show the redacted server state of a conflict', () async {
        final op = await enqueue('c-1');
        transport.enqueueHandler(
          (_) => SyncResponse(
            statusCode: 409,
            body: const {
              'version': 7,
              'name': 'Remote Ada',
              'apiKey': 'k-123',
            },
          ),
        );
        await sync();

        final details = (await inspector.loadOperation(op.id))!;
        expect(details.canResolveConflict, isTrue);
        expect(details.conflict!.remoteVersion, '7');
        expect(details.remoteData, {
          'version': 7,
          'name': 'Remote Ada',
          'apiKey': '[REDACTED]',
        });
      });

      test('report the server ID of an acknowledged create', () async {
        final op = await enqueue('tmp-1');
        await sync();
        await storage.saveIdMapping(
          SyncIdMapping(
            accountId: 'account-a',
            entityName: 'customers',
            localId: 'tmp-1',
            serverId: 'srv-9',
            createdAt: clock.now(),
          ),
        );

        expect((await inspector.loadOperation(op.id))!.serverId, 'srv-9');
      });
    });

    group('actions', () {
      test('retry re-queues a rejected operation and is recorded', () async {
        final op = await enqueue('c-1');
        transport.enqueueStatus(422);
        await sync();

        final requeued = await inspector.retry(op.id);

        expect(requeued.single.status, SyncOperationStatus.pending);
        expect(
            inspector.timeline.first.kind, InspectorEventKind.developerAction);
        expect(inspector.timeline.first.operationId, op.id);
        await sync();
        expect(
          (await storage.getOperation(op.id))!.status,
          SyncOperationStatus.acknowledged,
        );
      });

      test('cancel respects the state machine', () async {
        final pending = await enqueue('c-1');
        expect(
          (await inspector.cancel(pending.id)).status,
          SyncOperationStatus.cancelled,
        );

        final delivered = await enqueue('c-2');
        await sync();
        await expectLater(
          inspector.cancel(delivered.id),
          throwsA(isA<InvalidStateTransitionException>()),
        );
        await expectLater(
          inspector.retry(delivered.id),
          throwsA(isA<InvalidStateTransitionException>()),
        );
      });

      test('never act on another account\'s operations', () async {
        final other = await enqueue('b-1', accountId: 'account-b');

        await expectLater(
          inspector.cancel(other.id),
          throwsA(isA<OperationNotFoundException>()),
        );
        expect(
          (await storage.getOperation(other.id))!.status,
          SyncOperationStatus.pending,
        );
      });

      test('resolve conflicts through the engine', () async {
        final op = await enqueue('c-1');
        transport.enqueueStatus(409);
        await sync();

        final resolved =
            await inspector.resolveConflict(op.id, const UseLocal());

        expect(resolved.status, SyncOperationStatus.pending);
        expect(await storage.getConflict(op.id), isNull);
      });

      test('pause and resume the engine', () {
        inspector.pause();
        expect(engine.isPaused, isTrue);
        inspector.resume();
        expect(engine.isPaused, isFalse);
        expect(
          [for (final event in inspector.timeline.take(2)) event.summary],
          ['Resumed synchronization', 'Paused synchronization'],
        );
      });
    });

    group('export', () {
      Future<Map<String, Object?>> export({
        bool includePayloads = true,
        bool includeAccountId = false,
        int maxOperations = 500,
      }) async =>
          jsonDecode(
            await inspector.exportReport(
              includePayloads: includePayloads,
              includeAccountId: includeAccountId,
              maxOperations: maxOperations,
            ),
          ) as Map<String, Object?>;

      test('contains a redacted, sanitized report', () async {
        final op = await enqueue(
          'c-1',
          data: const {'name': 'Ada', 'token': 'secret-token-value'},
        );
        transport.enqueueStatus(422);
        await sync();

        final raw = await inspector.exportReport();
        expect(raw, isNot(contains('secret-token-value')));
        expect(raw, isNot(contains(op.idempotencyKey)));
        expect(raw, isNot(contains('account-a')));

        final report = jsonDecode(raw) as Map<String, Object?>;
        expect(report['format'], 'syncflow-diagnostics');
        expect(report['account'], '[REDACTED]');
        expect(report['counts'], {'rejected': 1});
        final operations = report['operations']! as List<Object?>;
        final exported = operations.single! as Map<String, Object?>;
        expect(exported['payload'], {'name': 'Ada', 'token': '[REDACTED]'});
        expect(
          (exported['lastError']! as Map<String, Object?>)['httpStatus'],
          422,
        );
        expect(report['timeline'], isNotEmpty);
      });

      test('can omit payloads, include the account and truncate', () async {
        await enqueue('c-1');
        await enqueue('c-2');

        final report = await export(
          includePayloads: false,
          includeAccountId: true,
          maxOperations: 1,
        );

        expect(report['account'], 'account-a');
        final operations = report['operations']! as List<Object?>;
        expect(operations, hasLength(1));
        expect(
          (operations.single! as Map<String, Object?>).containsKey('payload'),
          isFalse,
        );
        expect(report['operationsTruncated'], isTrue);
      });
    });

    test('a disabled inspector records nothing and refuses to work', () async {
      final disabled = SyncInspector(
        engine: engine,
        storage: storage,
        enabled: false,
      )..start();
      await sync();

      expect(disabled.isEnabled, isFalse);
      expect(disabled.timeline, isEmpty);
      expect(disabled.startedAt, isNull);
      expect(disabled.loadSnapshot, throwsStateError);
      expect(disabled.exportReport, throwsStateError);
      expect(disabled.pause, throwsStateError);
      disabled.dispose();
    });

    test('stops recording once disposed', () async {
      final short = SyncInspector(
        engine: engine,
        storage: storage,
        enabled: true,
      )..start();
      short.dispose();
      await sync();

      expect(short.timeline, isEmpty);
      expect(short.start, throwsStateError);
    });
  });
}
