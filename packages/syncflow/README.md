# syncflow

Pure Dart core of SyncFlow, an offline-first synchronization engine.

This package has no dependency on Flutter, Drift, Dio or any database. It
defines:

- `SyncOperation`: an immutable, durable unit of synchronization work with a
  stable ID and idempotency key.
- `SyncOperationStatus`: the lifecycle state machine. Invalid transitions throw
  `InvalidStateTransitionException`.
- `OperationQueue`: records `SyncMutation`s as operations and answers queue
  queries.
- `SyncStorage` and `SyncTransport`: the contracts that adapter packages
  implement.
- `SyncEngine`: delivers operations with leases, retries (exponential backoff
  with jitter and `Retry-After`), dependency ordering, account isolation,
  authentication pause and crash recovery. See
  [execution-engine.md](../../docs/architecture/execution-engine.md).

> **Status:** `0.2.0-dev`. There are no production storage or transport
> adapters yet. A full engine example is in
> [example/syncflow_example.dart](example/syncflow_example.dart).

## Example

```dart
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
}
```

## Delivery guarantees

Delivery is **at-least-once**. A request can be processed by the server even if
the response is lost, so the operation is retried with the **same idempotency
key**. Your backend must deduplicate on that key to prevent duplicate business
effects.
