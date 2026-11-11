// ignore_for_file: avoid_print

import 'package:syncflow/syncflow.dart';
import 'package:syncflow_test/syncflow_test.dart';

Future<void> main() async {
  final storage = InMemorySyncStorage();
  await storage.initialize();

  // A fake backend: the first request fails, the retry succeeds.
  final transport = FakeSyncTransport()..enqueueStatus(503);

  final queue = OperationQueue(storage: storage);
  final engine = SyncEngine(
    storage: storage,
    transport: transport,
    activeAccount: () => 'account-a',
    requestBuilder: (operation) => SyncRequest(
      method: SyncHttpMethod.post,
      path: '/${operation.entityName}',
      accountId: operation.accountId,
      body: operation.payload,
    ),
    retryPolicy: ExponentialBackoffRetryPolicy(
      baseDelay: const Duration(milliseconds: 100),
    ),
  );
  engine.events.listen((event) => print('event: ${event.runtimeType}'));
  await engine.initialize();

  await queue.enqueue(
    SyncMutation.create(
      entity: 'customers',
      id: 'customer-123',
      data: {'name': 'Example Customer'},
    ),
    accountId: 'account-a',
  );

  print(await engine.syncNow()); // retry scheduled
  await Future<void>.delayed(const Duration(milliseconds: 150));
  print(await engine.syncNow()); // acknowledged

  await engine.close();
  await transport.close();
  await storage.close();
}
