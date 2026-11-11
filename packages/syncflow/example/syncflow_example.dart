// ignore_for_file: avoid_print

import 'package:syncflow/syncflow.dart';
import 'package:syncflow_test/syncflow_test.dart';

Future<void> main() async {
  final storage = InMemorySyncStorage();
  await storage.initialize();

  final queue = OperationQueue(storage: storage);

  final operation = await queue.enqueue(
    SyncMutation.create(
      entity: 'customers',
      id: 'customer-123',
      data: {'name': 'Example Customer'},
    ),
    accountId: 'account-a',
  );

  final ready = await queue.eligible(accountId: 'account-a');
  print('${operation.id} queued; ${ready.length} operation(s) ready');

  await storage.close();
}
