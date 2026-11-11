import 'dart:async';

import 'package:syncflow/syncflow.dart';
import 'package:syncflow_test/syncflow_test.dart';
import 'package:test/test.dart';

/// Retries immediately, forever.
final class _ImmediateRetryPolicy implements RetryPolicy {
  @override
  Duration? delayFor({
    required int attempts,
    required SyncError error,
    Duration? retryAfter,
  }) =>
      Duration.zero;
}

void main() {
  late InMemorySyncStorage storage;
  late FakeClock clock;
  late FakeSyncTransport transport;
  late OperationQueue queue;
  late SyncEngine engine;
  late List<SyncEvent> events;
  String? activeAccount;

  SyncRequest buildRequest(SyncOperation operation) => SyncRequest(
        method: SyncHttpMethod.post,
        path: '/${operation.entityName}',
        accountId: operation.accountId,
        body: operation.payload,
      );

  SyncEngine createEngine({
    SyncEngineConfig config = const SyncEngineConfig(),
    RetryPolicy? retryPolicy,
    SyncRequestBuilder? requestBuilder,
  }) =>
      SyncEngine(
        storage: storage,
        transport: transport,
        requestBuilder: requestBuilder ?? buildRequest,
        activeAccount: () => activeAccount,
        config: config,
        retryPolicy: retryPolicy ?? ExponentialBackoffRetryPolicy(jitter: 0),
        clock: clock,
        idGenerator: SequentialIdGenerator(prefix: 'worker'),
      );

  /// Replaces the default engine (e.g. to change its configuration).
  Future<void> useEngine(SyncEngine replacement) async {
    await engine.close();
    engine = replacement;
    events.clear();
    engine.events.listen(events.add);
    await engine.initialize();
  }

  Future<SyncOperation> enqueue(
    String entityId, {
    String accountId = 'account-a',
    String entity = 'customers',
    List<String> dependsOn = const [],
  }) =>
      queue.enqueue(
        SyncMutation.create(
          entity: entity,
          id: entityId,
          data: {'name': entityId},
          dependencies: dependsOn,
        ),
        accountId: accountId,
      );

  Future<SyncOperation> stored(SyncOperation operation) async =>
      (await storage.getOperation(operation.id))!;

  List<String?> sentOperationIds() =>
      [for (final request in transport.requests) request.operationId];

  setUp(() async {
    storage = InMemorySyncStorage();
    await storage.initialize();
    clock = FakeClock(DateTime.utc(2026, 4, 1, 10));
    transport = FakeSyncTransport();
    queue = OperationQueue(
      storage: storage,
      clock: clock,
      idGenerator: SequentialIdGenerator(prefix: 'op'),
    );
    activeAccount = 'account-a';
    events = [];
    engine = createEngine();
    engine.events.listen(events.add);
    await engine.initialize();
  });

  tearDown(() async {
    await engine.close();
    await storage.close();
  });

  group('successful delivery', () {
    test('acknowledges the operation and records the attempt', () async {
      final operation = await enqueue('c-1');

      final result = await engine.syncNow();

      expect(result.isComplete, isTrue);
      expect(result.acknowledged, 1);
      final after = await stored(operation);
      expect(after.status, SyncOperationStatus.acknowledged);
      expect(after.attempts, 1);
      expect(after.lastAttemptAt, clock.now());
      expect(after.leaseOwner, isNull);
    });

    test('sends the operation identity regardless of the builder', () async {
      final operation = await enqueue('c-1');
      await useEngine(
        createEngine(
          requestBuilder: (op) => SyncRequest(
            method: SyncHttpMethod.put,
            path: '/customers/${op.entityId}',
            accountId: 'someone-else',
            idempotencyKey: 'builder-key',
            operationId: 'wrong',
            body: op.payload,
          ),
        ),
      );

      await engine.syncNow();

      final request = transport.requests.single;
      expect(request.method, SyncHttpMethod.put);
      expect(request.path, '/customers/c-1');
      expect(request.accountId, 'account-a');
      expect(request.idempotencyKey, operation.idempotencyKey);
      expect(request.operationId, operation.id);
      expect(request.body, {'name': 'c-1'});
    });

    test('emits events in order, after the state is stored', () async {
      final operation = await enqueue('c-1');
      final statusAtEvent = <SyncOperationStatus>[];
      final reads = <Future<void>>[];
      engine.events.listen((event) {
        if (event is OperationAcknowledged) {
          reads.add(
            storage
                .getOperation(operation.id)
                .then((op) => statusAtEvent.add(op!.status)),
          );
        }
      });

      await engine.syncNow();
      await pumpEventQueue();
      await Future.wait(reads);

      expect(events.map((e) => e.runtimeType), [
        SyncRunStarted,
        OperationAcknowledged,
        SyncRunCompleted,
      ]);
      expect(statusAtEvent, [SyncOperationStatus.acknowledged]);
      expect(
        (events.last as SyncRunCompleted).result.acknowledged,
        1,
      );
    });
  });

  group('retries', () {
    test('schedules a retry with backoff and reuses the idempotency key',
        () async {
      final operation = await enqueue('c-1');
      transport.enqueueStatus(503);

      final first = await engine.syncNow();

      expect(first.retryScheduled, 1);
      var after = await stored(operation);
      expect(after.status, SyncOperationStatus.retryScheduled);
      expect(after.nextAttemptAt, clock.now().add(const Duration(seconds: 1)));
      expect(after.lastError!.category, SyncErrorCategory.server);
      expect(after.lastError!.httpStatus, 503);

      expect((await engine.syncNow()).acknowledged, 0, reason: 'not yet due');
      expect(transport.requests, hasLength(1));

      clock.advance(const Duration(seconds: 1));
      final second = await engine.syncNow();

      expect(second.acknowledged, 1);
      after = await stored(operation);
      expect(after.attempts, 2);
      expect(after.lastError, isNull);
      expect(
        transport.requests.map((r) => r.idempotencyKey).toSet(),
        {operation.idempotencyKey},
      );
    });

    test('backs off exponentially across attempts', () async {
      final operation = await enqueue('c-1');
      transport.handler = (_) => SyncResponse(statusCode: 500);

      final delays = <Duration>[];
      for (var i = 0; i < 4; i++) {
        await engine.syncNow();
        final after = await stored(operation);
        delays.add(after.nextAttemptAt!.difference(clock.now()));
        clock.setTo(after.nextAttemptAt!);
      }

      expect(delays.map((d) => d.inSeconds), [1, 2, 4, 8]);
    });

    test('honors Retry-After', () async {
      final operation = await enqueue('c-1');
      transport.enqueueStatus(429, headers: {'Retry-After': '120'});

      await engine.syncNow();

      expect(
        (await stored(operation)).nextAttemptAt,
        clock.now().add(const Duration(seconds: 120)),
      );
    });

    test('rejects the operation once retries are exhausted', () async {
      await useEngine(
        createEngine(
          retryPolicy: ExponentialBackoffRetryPolicy(jitter: 0, maxAttempts: 2),
        ),
      );
      final operation = await enqueue('c-1');
      transport.handler = (_) => SyncResponse(statusCode: 503);

      await engine.syncNow();
      clock.advance(const Duration(seconds: 1));
      final result = await engine.syncNow();

      expect(result.rejected, 1);
      final after = await stored(operation);
      expect(after.status, SyncOperationStatus.rejected);
      expect(after.attempts, 2);
      expect(after.lastError!.isRetryable, isFalse);
      expect(after.lastError!.message, contains('Retry limit reached'));
    });

    test('retries network failures', () async {
      final operation = await enqueue('c-1');
      transport.enqueueFailure(
        const SyncTransportException(
          'No route to host.',
          category: SyncErrorCategory.network,
        ),
      );

      final result = await engine.syncNow();

      expect(result.retryScheduled, 1);
      expect(
        (await stored(operation)).lastError!.category,
        SyncErrorCategory.network,
      );
    });

    test('retries unexpected transport exceptions as unknown', () async {
      final operation = await enqueue('c-1');
      transport.enqueueHandler((_) => throw const FormatException('boom'));

      await engine.syncNow();

      final after = await stored(operation);
      expect(after.status, SyncOperationStatus.retryScheduled);
      expect(after.lastError!.category, SyncErrorCategory.unknown);
      expect(after.lastError!.message, isNot(contains('boom')));
    });

    test('attempts each operation at most once per run', () async {
      await useEngine(createEngine(retryPolicy: _ImmediateRetryPolicy()));
      await enqueue('c-1');
      // Succeeds from the 4th request on, so a regression fails the assertions
      // below instead of spinning forever.
      transport.handler = (_) => SyncResponse(
            statusCode: transport.requests.length > 3 ? 200 : 503,
          );

      final result = await engine.syncNow();

      expect(result.retryScheduled, 1);
      expect(transport.requests, hasLength(1));
    });
  });

  group('permanent outcomes', () {
    test('422 rejects the operation and it is not retried', () async {
      final operation = await enqueue('c-1');
      transport.enqueueStatus(422);

      final result = await engine.syncNow();
      clock.advance(const Duration(days: 1));
      await engine.syncNow();

      expect(result.rejected, 1);
      expect(result.failed, 1);
      final after = await stored(operation);
      expect(after.status, SyncOperationStatus.rejected);
      expect(after.lastError!.category, SyncErrorCategory.validation);
      expect(transport.requests, hasLength(1));
    });

    test('409 marks a conflict and emits the response', () async {
      final operation = await enqueue('c-1');
      transport.enqueueHandler(
        (_) => SyncResponse(statusCode: 409, body: {'version': 7}),
      );

      final result = await engine.syncNow();
      await pumpEventQueue();

      expect(result.conflicts, 1);
      expect((await stored(operation)).status, SyncOperationStatus.conflict);
      final event = events.whereType<OperationConflicted>().single;
      expect(event.response.body, {'version': 7});
    });

    test('a failing request builder rejects without sending', () async {
      await useEngine(
        createEngine(
          requestBuilder: (_) => throw const FormatException('bad payload'),
        ),
      );
      final operation = await enqueue('c-1');

      final result = await engine.syncNow();

      expect(result.rejected, 1);
      expect(transport.requests, isEmpty);
      final after = await stored(operation);
      expect(after.status, SyncOperationStatus.rejected);
      expect(after.lastError!.category, SyncErrorCategory.serialization);
    });
  });

  group('authentication', () {
    setUp(() async {
      await useEngine(
        createEngine(
          config: const SyncEngineConfig(maxConcurrentOperations: 1),
        ),
      );
    });

    test('401 pauses the account until authentication is resumed', () async {
      final first = await enqueue('c-1');
      final second = await enqueue('c-2');
      transport.enqueueStatus(401);

      final result = await engine.syncNow();
      await pumpEventQueue();

      expect(result.stopReason, SyncRunStopReason.authenticationRequired);
      expect(engine.isAuthenticationRequired('account-a'), isTrue);
      final afterFirst = await stored(first);
      expect(afterFirst.status, SyncOperationStatus.pending);
      expect(afterFirst.lastError!.category, SyncErrorCategory.authentication);
      expect(sentOperationIds(), [first.id]);
      expect(events.whereType<AuthenticationRequired>().single.accountId,
          'account-a');

      final whilePaused = await engine.syncNow();
      expect(whilePaused.stopReason, SyncRunStopReason.authenticationRequired);
      expect(transport.requests, hasLength(1));

      engine.resumeAuthentication('account-a');
      final resumed = await engine.syncNow();

      expect(resumed.acknowledged, 2);
      expect(sentOperationIds(), [first.id, first.id, second.id]);
    });

    test('authentication pauses are per account', () async {
      await enqueue('c-1');
      await enqueue('b-1', accountId: 'account-b');
      transport.enqueueStatus(401);

      await engine.syncNow();
      activeAccount = 'account-b';
      final result = await engine.syncNow();

      expect(result.acknowledged, 1);
      expect(engine.isAuthenticationRequired('account-b'), isFalse);
    });
  });

  group('account isolation', () {
    test('does nothing without an active account', () async {
      await enqueue('c-1');
      activeAccount = null;

      final result = await engine.syncNow();

      expect(result.stopReason, SyncRunStopReason.noActiveAccount);
      expect(transport.requests, isEmpty);
    });

    test('only delivers operations of the active account', () async {
      final a = await enqueue('a-1', accountId: 'account-a');
      final b = await enqueue('b-1', accountId: 'account-b');

      await engine.syncNow();
      expect(sentOperationIds(), [a.id]);

      activeAccount = 'account-b';
      await engine.syncNow();
      expect(sentOperationIds(), [a.id, b.id]);
      expect(transport.requests.last.accountId, 'account-b');
    });

    test('stops when the active account changes mid-run', () async {
      await useEngine(
        createEngine(
          config: const SyncEngineConfig(maxConcurrentOperations: 1),
        ),
      );
      for (var i = 0; i < 3; i++) {
        await enqueue('c-$i');
      }
      transport.enqueueHandler((_) {
        activeAccount = 'account-b';
        return SyncResponse(statusCode: 200);
      });

      final result = await engine.syncNow();

      expect(result.stopReason, SyncRunStopReason.accountChanged);
      expect(result.acknowledged, 1);
      expect(transport.requests, hasLength(1));
    });
  });

  group('pause', () {
    test('a paused engine sends nothing until resumed', () async {
      await enqueue('c-1');
      engine.pause();

      expect((await engine.syncNow()).stopReason, SyncRunStopReason.paused);
      expect(transport.requests, isEmpty);

      engine.resume();
      expect((await engine.syncNow()).acknowledged, 1);
    });

    test('pausing mid-run lets in-flight work finish', () async {
      await useEngine(
        createEngine(
          config: const SyncEngineConfig(maxConcurrentOperations: 1),
        ),
      );
      await enqueue('c-1');
      await enqueue('c-2');
      transport.enqueueHandler((_) {
        engine.pause();
        return SyncResponse(statusCode: 200);
      });

      final result = await engine.syncNow();

      expect(result.stopReason, SyncRunStopReason.paused);
      expect(result.acknowledged, 1);
    });
  });

  group('ordering', () {
    test('holds back operations until dependencies are acknowledged', () async {
      final customer = await enqueue('c-1');
      final account = await enqueue(
        'acc-1',
        entity: 'accounts',
        dependsOn: [customer.id],
      );
      transport.enqueueStatus(503);

      final first = await engine.syncNow();

      expect(sentOperationIds(), [customer.id]);
      expect(first.blocked, 1);

      clock.advance(const Duration(seconds: 1));
      final second = await engine.syncNow();

      expect(second.acknowledged, 2);
      expect(second.blocked, 0);
      expect(sentOperationIds(), [customer.id, customer.id, account.id]);
    });

    test('a rejected dependency keeps dependents blocked', () async {
      final customer = await enqueue('c-1');
      await enqueue('acc-1', entity: 'accounts', dependsOn: [customer.id]);
      transport.enqueueStatus(422);

      await engine.syncNow();
      final later = await engine.syncNow();

      expect(sentOperationIds(), [customer.id]);
      expect(later.blocked, 1);
    });

    test('mutations of one entity are delivered in order', () async {
      final create = await enqueue('c-1');
      final update = await queue.enqueue(
        SyncMutation.update(
          entity: 'customers',
          id: 'c-1',
          data: const {'name': 'Renamed'},
        ),
        accountId: 'account-a',
      );
      transport.enqueueStatus(503);

      await engine.syncNow();
      expect(sentOperationIds(), [create.id], reason: 'update must wait');

      clock.advance(const Duration(seconds: 1));
      await engine.syncNow();
      expect(sentOperationIds(), [create.id, create.id, update.id]);
    });
  });

  group('concurrency', () {
    test('never exceeds maxConcurrentOperations', () async {
      for (var i = 0; i < 10; i++) {
        await enqueue('c-$i');
      }
      var inFlight = 0;
      var maxInFlight = 0;
      transport.handler = (_) async {
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 2));
        inFlight--;
        return SyncResponse(statusCode: 200);
      };

      final result = await engine.syncNow();

      expect(result.acknowledged, 10);
      expect(maxInFlight, 3);
    });

    test('two engines sharing storage deliver each operation once', () async {
      for (var i = 0; i < 20; i++) {
        await enqueue('c-$i');
      }
      transport.handler = (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return SyncResponse(statusCode: 200);
      };
      final other = createEngine();
      await other.initialize();

      final results = await Future.wait([engine.syncNow(), other.syncNow()]);
      await other.close();

      expect(transport.requests, hasLength(20));
      expect(sentOperationIds().toSet(), hasLength(20));
      expect(results[0].acknowledged + results[1].acknowledged, 20);
    });

    test('overlapping syncNow calls share one follow-up run', () async {
      await enqueue('c-1');
      final gate = Completer<void>();
      transport.enqueueHandler((_) async {
        await gate.future;
        return SyncResponse(statusCode: 200);
      });

      final first = engine.syncNow();
      await pumpEventQueue();
      expect(engine.isSyncing, isTrue);
      final second = engine.syncNow();
      final third = engine.syncNow();

      expect(identical(second, third), isTrue);
      expect(identical(first, second), isFalse);

      gate.complete();
      expect((await first).acknowledged, 1);
      expect((await second).acknowledged, 0);
      expect(engine.isSyncing, isFalse);
    });
  });

  group('crash recovery', () {
    test('recovers an operation left sending by a crashed process', () async {
      final crashed = buildTestOperation(
        id: 'op-crashed',
        status: SyncOperationStatus.sending,
        attempts: 1,
        createdAt: clock.now().subtract(const Duration(minutes: 10)),
        leaseOwner: 'dead-worker',
        leaseExpiresAt: clock.now().subtract(const Duration(minutes: 1)),
      );
      await storage.insertOperation(crashed);

      await useEngine(createEngine());
      final result = await engine.syncNow();
      await pumpEventQueue();

      expect(events.first, isA<LeasesRecovered>());
      expect(result.acknowledged, 1);
      expect(transport.requests.single.idempotencyKey, crashed.idempotencyKey);
      expect((await stored(crashed)).attempts, 2);
    });

    test('does not steal an unexpired lease from a live worker', () async {
      final busy = buildTestOperation(
        id: 'op-busy',
        status: SyncOperationStatus.sending,
        leaseOwner: 'background-isolate',
        leaseExpiresAt: clock.now().add(const Duration(minutes: 1)),
      );
      await storage.insertOperation(busy);

      await engine.syncNow();
      expect(transport.requests, isEmpty);

      clock.advance(const Duration(minutes: 1));
      await engine.syncNow();
      expect(transport.requests.single.operationId, busy.id);
    });

    test('a lost response is retried and deduplicated by the server', () async {
      final server = FakeIdempotentServer();
      transport.handler = server.handle;
      transport.enqueueHandler((request) async {
        await server.handle(request);
        throw const SyncTransportException(
          'Connection reset.',
          category: SyncErrorCategory.network,
        );
      });
      final operation = await enqueue('c-1');

      final first = await engine.syncNow();
      clock.advance(const Duration(seconds: 1));
      final second = await engine.syncNow();

      expect(first.retryScheduled, 1);
      expect(second.acknowledged, 1);
      expect(server.received, 2);
      expect(server.effects, hasLength(1));
      expect(
          (await stored(operation)).status, SyncOperationStatus.acknowledged);
    });

    test('a result arriving after the lease expired is discarded', () async {
      await useEngine(
        createEngine(
          config: const SyncEngineConfig(
            leaseDuration: Duration(seconds: 10),
          ),
        ),
      );
      final operation = await enqueue('c-1');
      transport.enqueueHandler((_) async {
        // The request outlives its lease and another worker recovers it.
        clock.advance(const Duration(seconds: 11));
        await storage.recoverExpiredLeases(clock.now());
        return SyncResponse(statusCode: 200);
      });

      final result = await engine.syncNow();
      await pumpEventQueue();

      expect(result.leaseLost, 1);
      expect(result.acknowledged, 0);
      expect((await stored(operation)).status, SyncOperationStatus.pending);
      expect(events.whereType<OperationLeaseLost>().single.operationId,
          operation.id);

      final retry = await engine.syncNow();
      expect(retry.acknowledged, 1);
      expect(
        transport.requests.map((r) => r.idempotencyKey).toSet(),
        {operation.idempotencyKey},
      );
    });
  });

  group('lifecycle', () {
    test('syncNow requires initialize', () {
      final fresh = createEngine();
      expect(fresh.syncNow, throwsStateError);
    });

    test('close waits for the active run and rejects new runs', () async {
      await enqueue('c-1');
      final gate = Completer<void>();
      transport.enqueueHandler((_) async {
        await gate.future;
        return SyncResponse(statusCode: 200);
      });

      final run = engine.syncNow();
      await pumpEventQueue();
      final closing = engine.close();
      gate.complete();
      await closing;

      expect((await run).acknowledged, 1);
      expect(engine.syncNow, throwsStateError);
    });

    test('rejects invalid configuration', () {
      expect(
        () => createEngine(
          config: const SyncEngineConfig(maxConcurrentOperations: 0),
        ),
        throwsArgumentError,
      );
      expect(
        () => createEngine(
          config: const SyncEngineConfig(leaseDuration: Duration.zero),
        ),
        throwsArgumentError,
      );
    });
  });
}
