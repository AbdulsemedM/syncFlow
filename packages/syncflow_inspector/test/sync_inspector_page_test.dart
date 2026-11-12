import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncflow/syncflow.dart';
import 'package:syncflow_inspector/syncflow_inspector.dart';
import 'package:syncflow_test/syncflow_test.dart';

void main() {
  late InMemorySyncStorage storage;
  late FakeClock clock;
  late FakeSyncTransport transport;
  late OperationQueue queue;
  late SyncEngine engine;
  late SyncInspector inspector;

  Future<void> setUpInspector({bool enabled = true}) async {
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
    inspector = SyncInspector(
      engine: engine,
      storage: storage,
      queue: queue,
      enabled: enabled,
      clock: clock,
    )..start();
  }

  Future<void> cleanUp() async {
    inspector.dispose();
    await engine.close();
    await storage.close();
  }

  Future<SyncOperation> enqueue(
    String id, {
    Map<String, Object?> data = const {'name': 'Ada'},
  }) =>
      queue.enqueue(
        SyncMutation.create(entity: 'customers', id: id, data: data),
        accountId: 'account-a',
      );

  Future<void> showPage(
    WidgetTester tester, {
    ValueChanged<String>? onExport,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SyncInspectorPage(inspector: inspector, onExport: onExport),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openTab(WidgetTester tester, String name) async {
    await tester.tap(find.widgetWithText(Tab, name));
    await tester.pumpAndSettle();
  }

  Finder statTile(String label, int value) => find.ancestor(
        of: find.text(label),
        matching:
            find.ancestor(of: find.text('$value'), matching: find.byType(Card)),
      );

  testWidgets('a disabled inspector is never opened', (tester) async {
    await setUpInspector(enabled: false);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSyncInspector(context, inspector),
            child: const Text('Debug'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Debug'));
    await tester.pumpAndSettle();
    expect(find.byType(SyncInspectorPage), findsNothing);

    await tester.pumpWidget(
      MaterialApp(home: SyncInspectorPage(inspector: inspector)),
    );
    expect(find.textContaining('disabled'), findsOneWidget);
    await cleanUp();
  });

  testWidgets('overview shows queue statistics and conflicts', (tester) async {
    await setUpInspector();
    await enqueue('c-1');
    await enqueue('c-2');
    await enqueue('c-3');
    transport
      ..enqueueStatus(200)
      ..enqueueStatus(422)
      ..enqueueStatus(409);
    await engine.syncNow();
    await enqueue('c-4');

    await showPage(tester);

    expect(find.text('Account: account-a'), findsOneWidget);
    expect(statTile('Pending', 1), findsOneWidget);
    expect(statTile('Completed', 1), findsOneWidget);
    expect(statTile('Rejected', 1), findsOneWidget);
    expect(statTile('Conflicts', 1), findsOneWidget);
    expect(find.textContaining('Last run: completed'), findsOneWidget);
    expect(find.text('Unresolved conflicts'), findsOneWidget);

    await tester.tap(find.text('customers/c-3'));
    await tester.pumpAndSettle();
    expect(find.byType(OperationDetailPage), findsOneWidget);
    expect(find.text('Keep local'), findsOneWidget);
    await cleanUp();
  });

  testWidgets('operations can be filtered and retried after rejection',
      (tester) async {
    // Tall enough for the whole detail page to be built.
    tester.view.physicalSize = const Size(1000, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await setUpInspector();
    final rejected = await enqueue(
      'c-1',
      data: const {'name': 'Ada', 'password': 'hunter2'},
    );
    await enqueue('c-2');
    transport
      ..enqueueStatus(422)
      ..enqueueStatus(200);
    await engine.syncNow();
    await showPage(tester);

    await openTab(tester, 'Operations');
    expect(find.text('create customers/c-1'), findsOneWidget);
    expect(find.text('create customers/c-2'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Failed'));
    await tester.pumpAndSettle();
    expect(find.text('create customers/c-1'), findsOneWidget);
    expect(find.text('create customers/c-2'), findsNothing);

    await tester.tap(find.text('create customers/c-1'));
    await tester.pumpAndSettle();
    expect(find.textContaining('hunter2'), findsNothing);
    expect(find.textContaining('[REDACTED]'), findsOneWidget);
    expect(find.text('validation'), findsOneWidget);
    expect(find.text(rejected.idempotencyKey), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
    await tester.pumpAndSettle();

    expect(
      (await storage.getOperation(rejected.id))!.status,
      SyncOperationStatus.pending,
    );
    expect(find.text('Pending'), findsOneWidget); // status chip refreshed
    expect(find.text('Retry'), findsNothing);
    await cleanUp();
  });

  testWidgets('cancelling asks for confirmation', (tester) async {
    await setUpInspector();
    final op = await enqueue('c-1');
    await tester.pumpWidget(
      MaterialApp(
        home: OperationDetailPage(inspector: inspector, operationId: op.id),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();
    expect(
      (await storage.getOperation(op.id))!.status,
      SyncOperationStatus.pending,
    );

    await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel operation'));
    await tester.pumpAndSettle();
    expect(
      (await storage.getOperation(op.id))!.status,
      SyncOperationStatus.cancelled,
    );
    expect(find.text('Cancelled'), findsOneWidget);
    await cleanUp();
  });

  testWidgets('a failed action is reported, not thrown', (tester) async {
    await setUpInspector();
    final op = await enqueue('c-1');
    await tester.pumpWidget(
      MaterialApp(
        home: OperationDetailPage(inspector: inspector, operationId: op.id),
      ),
    );
    await tester.pumpAndSettle();

    // Delivered behind the page's back: cancelling is no longer allowed.
    await engine.syncNow();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel operation'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Action failed'), findsOneWidget);
    expect(find.text('Acknowledged'), findsOneWidget);
    await cleanUp();
  });

  testWidgets('timeline follows engine events', (tester) async {
    await setUpInspector();
    await showPage(tester);
    await openTab(tester, 'Timeline');
    expect(find.text('No events recorded yet'), findsOneWidget);

    await enqueue('c-1');
    await engine.syncNow();
    await tester.pumpAndSettle();

    expect(find.text('Sync run started'), findsOneWidget);
    expect(find.text('Acknowledged create customers/c-1'), findsOneWidget);
    expect(find.textContaining('HTTP 200'), findsOneWidget);
    await cleanUp();
  });

  testWidgets('app bar pauses and resumes the engine', (tester) async {
    await setUpInspector();
    await showPage(tester);

    await tester.tap(find.byTooltip('Pause synchronization'));
    await tester.pumpAndSettle();
    expect(engine.isPaused, isTrue);

    await tester.tap(find.byTooltip('Resume synchronization'));
    await tester.pumpAndSettle();
    expect(engine.isPaused, isFalse);
    await cleanUp();
  });

  testWidgets('exports through the callback or a dialog', (tester) async {
    await setUpInspector();
    await enqueue('c-1', data: const {'token': 'secret-token-value'});
    String? exported;
    await showPage(tester, onExport: (report) => exported = report);

    await tester.tap(find.byTooltip('Export diagnostics'));
    await tester.pumpAndSettle();
    expect(exported, contains('syncflow-diagnostics'));
    expect(exported, isNot(contains('secret-token-value')));

    await showPage(tester);
    await tester.tap(find.byTooltip('Export diagnostics'));
    await tester.pumpAndSettle();
    expect(find.text('Diagnostic report'), findsOneWidget);
    expect(find.textContaining('approved channels'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Diagnostic report'), findsNothing);
    await cleanUp();
  });
}
