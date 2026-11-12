import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncflow/syncflow.dart';
import 'package:syncflow_flutter/syncflow_flutter.dart';
import 'package:syncflow_test/syncflow_test.dart';

const debounce = Duration(milliseconds: 500);

void main() {
  late InMemorySyncStorage storage;
  late FakeClock clock;
  late FakeSyncTransport transport;
  late OperationQueue queue;
  late SyncEngine engine;
  late StreamController<bool> connectivity;
  SyncFlowFlutter? controller;

  Future<void> setUpEngine() async {
    storage = InMemorySyncStorage();
    await storage.initialize();
    clock = FakeClock(DateTime.utc(2026, 11, 1, 9));
    transport = FakeSyncTransport();
    queue = OperationQueue(storage: storage, clock: clock);
    engine = SyncEngine(
      storage: storage,
      transport: transport,
      activeAccount: () => 'account-a',
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
    connectivity = StreamController<bool>.broadcast();
  }

  SyncFlowFlutter create({
    bool syncOnStart = true,
    Duration? periodicInterval,
    bool pauseWhenBackgrounded = false,
    bool withConnectivity = false,
  }) =>
      controller = SyncFlowFlutter(
        engine: engine,
        connectivity: withConnectivity
            ? StreamConnectivitySource(connectivity.stream)
            : null,
        syncOnStart: syncOnStart,
        periodicInterval: periodicInterval,
        pauseWhenBackgrounded: pauseWhenBackgrounded,
        clock: clock,
      );

  Future<void> enqueue(String id) => queue.enqueue(
        SyncMutation.create(entity: 'customers', id: id, data: const {}),
        accountId: 'account-a',
      );

  Future<void> cleanUp() async {
    await controller?.dispose();
    controller = null;
    await engine.close();
    await connectivity.close();
    await storage.close();
  }

  /// Walks the binding through the states the OS reports when backgrounding.
  void moveToBackground(WidgetTester tester) {
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
  }

  void returnToForeground(WidgetTester tester) {
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
  }

  setUp(() => controller = null);

  group('triggers', () {
    testWidgets('syncs on start after the debounce window', (tester) async {
      await setUpEngine();
      await enqueue('c-1');
      create().start();

      await tester.pump(debounce - const Duration(milliseconds: 1));
      expect(transport.requests, isEmpty);

      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpAndSettle();
      expect(transport.requests, hasLength(1));
      expect(controller!.status.value.lastTrigger, SyncTrigger.startup);

      await cleanUp();
    });

    testWidgets('triggers within the debounce window share one run',
        (tester) async {
      await setUpEngine();
      await enqueue('c-1');
      var runs = 0;
      final subscription = engine.events.listen((event) {
        if (event is SyncRunStarted) runs++;
      });
      create(withConnectivity: true).start();
      connectivity.add(false);
      await tester.pump();
      connectivity.add(true); // restored, inside the startup window
      await tester.pump(const Duration(milliseconds: 200));

      await tester.pump(debounce);
      await tester.pumpAndSettle();

      expect(transport.requests, hasLength(1));
      expect(runs, 1, reason: 'one engine run, not one per trigger');
      unawaited(subscription.cancel());
      await cleanUp();
    });

    testWidgets('syncs when the app returns to the foreground', (tester) async {
      await setUpEngine();
      create(syncOnStart: false).start();
      moveToBackground(tester);
      await enqueue('c-1');

      returnToForeground(tester);
      await tester.pump(debounce);
      await tester.pumpAndSettle();

      expect(transport.requests, hasLength(1));
      expect(controller!.status.value.lastTrigger, SyncTrigger.resumed);
      await cleanUp();
    });

    testWidgets('syncs when connectivity is restored, not while offline',
        (tester) async {
      await setUpEngine();
      final sync = create(syncOnStart: false, withConnectivity: true)..start();
      connectivity.add(false);
      await tester.pump();
      await enqueue('c-1');

      // Automatic triggers are skipped while offline...
      returnToForeground(tester);
      await tester.pump(debounce * 2);
      expect(transport.requests, isEmpty);
      expect(sync.status.value.isOnline, isFalse);

      // ...but the network coming back triggers a sync.
      connectivity.add(true);
      await tester.pump(debounce);
      await tester.pumpAndSettle();
      expect(transport.requests, hasLength(1));
      expect(sync.status.value.lastTrigger, SyncTrigger.connectivityRestored);
      await cleanUp();
    });

    testWidgets('manual syncs run immediately, even when offline',
        (tester) async {
      await setUpEngine();
      final sync = create(syncOnStart: false, withConnectivity: true)..start();
      connectivity.add(false);
      await tester.pump();
      await enqueue('c-1');

      final result = await sync.syncNow();

      expect(result!.acknowledged, 1);
      expect(sync.status.value.lastTrigger, SyncTrigger.manual);
      await cleanUp();
    });

    testWidgets('periodic syncs run only in the foreground', (tester) async {
      await setUpEngine();
      create(
        syncOnStart: false,
        periodicInterval: const Duration(minutes: 1),
      ).start();

      await tester.pump(const Duration(minutes: 1) + debounce);
      await tester.pumpAndSettle();
      final foregroundRuns = controller!.status.value.lastResult;
      expect(foregroundRuns, isNotNull);
      expect(controller!.status.value.lastTrigger, SyncTrigger.periodic);

      moveToBackground(tester);
      await enqueue('c-1');
      await tester.pump(const Duration(minutes: 5));
      expect(transport.requests, isEmpty, reason: 'no runs in background');

      await cleanUp();
    });
  });

  group('retries', () {
    testWidgets('wakes up when a scheduled retry is due', (tester) async {
      await setUpEngine();
      await enqueue('c-1');
      transport.enqueueStatus(503);
      create().start();

      await tester.pump(debounce);
      await tester.pumpAndSettle();
      expect(transport.requests, hasLength(1));
      expect(controller!.status.value.pendingOperations, 1);

      // The retry is due one second later (backoff without jitter).
      clock.advance(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(debounce);
      await tester.pumpAndSettle();

      expect(transport.requests, hasLength(2));
      expect(controller!.status.value.lastTrigger, SyncTrigger.retryDue);
      expect(controller!.status.value.pendingOperations, 0);
      await cleanUp();
    });

    testWidgets('does not wake up for retries while in the background',
        (tester) async {
      await setUpEngine();
      await enqueue('c-1');
      transport.enqueueStatus(503);
      create().start();
      await tester.pump(debounce);
      await tester.pumpAndSettle();

      moveToBackground(tester);
      clock.advance(const Duration(minutes: 1));
      await tester.pump(const Duration(minutes: 1));

      expect(transport.requests, hasLength(1));
      await cleanUp();
    });
  });

  group('status', () {
    testWidgets('reports syncing, counts and the last result', (tester) async {
      await setUpEngine();
      await enqueue('c-1');
      await enqueue('c-2');
      final gate = Completer<void>();
      transport.handler = (_) async {
        await gate.future;
        return SyncResponse(statusCode: 422);
      };
      final sync = create(syncOnStart: false)..start();
      await tester.pumpAndSettle();
      expect(sync.status.value.pendingOperations, 2);

      final run = sync.syncNow();
      await tester.pump();
      expect(sync.status.value.isSyncing, isTrue);

      gate.complete();
      await run;
      await tester.pumpAndSettle();

      final status = sync.status.value;
      expect(status.isSyncing, isFalse);
      expect(status.lastResult!.rejected, 2);
      expect(status.failedOperations, 2);
      expect(status.pendingOperations, 0);
      expect(status.lastCompletedAt, clock.now());
      expect(status.lastError, isNull);
      await cleanUp();
    });

    testWidgets('records unexpected errors and clears them on success',
        (tester) async {
      await setUpEngine();
      await enqueue('c-1');
      transport.handler = (_) => throw ArgumentError('transport bug');
      final sync = create(syncOnStart: false)..start();

      await expectLater(sync.syncNow(), throwsArgumentError);
      expect(sync.status.value.lastError, isA<ArgumentError>());
      expect(sync.status.value.isSyncing, isFalse);

      // The lease expires and the operation is recovered on the next run.
      transport.handler = (_) => SyncResponse(statusCode: 200);
      clock.advance(const Duration(minutes: 3));
      final result = await sync.syncNow();

      expect(result!.acknowledged, 1);
      expect(sync.status.value.lastError, isNull);
      await cleanUp();
    });

    testWidgets('works with ValueListenableBuilder', (tester) async {
      await setUpEngine();
      await enqueue('c-1');
      final sync = create(syncOnStart: false)..start();

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ValueListenableBuilder<SyncStatus>(
            valueListenable: sync.status,
            builder: (context, status, _) =>
                Text('pending: ${status.pendingOperations}'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('pending: 1'), findsOneWidget);

      await sync.syncNow();
      await tester.pumpAndSettle();
      expect(find.text('pending: 0'), findsOneWidget);
      await cleanUp();
    });
  });

  group('lifecycle', () {
    testWidgets('can pause the engine while in the background', (tester) async {
      await setUpEngine();
      create(syncOnStart: false, pauseWhenBackgrounded: true).start();

      moveToBackground(tester);
      expect(engine.isPaused, isTrue);

      returnToForeground(tester);
      expect(engine.isPaused, isFalse);
      await tester.pump(debounce);
      await tester.pumpAndSettle();
      await cleanUp();
    });

    testWidgets('dispose stops all triggers but leaves the engine open',
        (tester) async {
      await setUpEngine();
      final sync = create(periodicInterval: const Duration(seconds: 10))
        ..start();
      await sync.dispose();
      await sync.dispose(); // idempotent
      await enqueue('c-1');

      returnToForeground(tester);
      await tester.pump(const Duration(minutes: 1));

      expect(transport.requests, isEmpty);
      expect(engine.isClosed, isFalse);
      expect(sync.start, throwsStateError);
      controller = null;
      await cleanUp();
    });

    testWidgets('a closed engine is treated as shutdown, not failure',
        (tester) async {
      await setUpEngine();
      final sync = create(syncOnStart: false)..start();
      await engine.close();

      expect(await sync.syncNow(), isNull);
      expect(sync.status.value.lastError, isNull);
      await cleanUp();
    });
  });
}
