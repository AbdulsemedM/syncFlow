# syncflow_flutter

Flutter integration for [SyncFlow](../syncflow): it runs synchronization at
the right moments in your app's lifecycle and exposes a listenable status for
your UI.

## Usage

```dart
final sync = SyncFlowFlutter(
  engine: engine,
  connectivity: StreamConnectivitySource(
    Connectivity().onConnectivityChanged.map(
      (results) => !results.contains(ConnectivityResult.none),
    ),
  ),
  periodicInterval: const Duration(minutes: 5), // optional
)..start();

// In your widget tree:
ValueListenableBuilder<SyncStatus>(
  valueListenable: sync.status,
  builder: (context, status, _) => status.isSyncing
      ? const LinearProgressIndicator()
      : Text('${status.pendingOperations} changes waiting'),
);

// Pull-to-refresh or a "Sync now" button:
await sync.syncNow();

// On shutdown (the engine is not closed for you):
await sync.dispose();
await engine.close();
```

The example uses `connectivity_plus`, but any `Stream<bool>` works.
`syncflow_flutter` itself has no plugin dependencies.

## When it syncs

| Trigger | When |
| --- | --- |
| `startup` | `start()` is called (`syncOnStart`) |
| `resumed` | The app returns to the foreground (`syncOnResume`) |
| `connectivityRestored` | The connectivity source goes from offline to online |
| `retryDue` | The earliest scheduled retry becomes due, while in the foreground |
| `periodic` | `periodicInterval` elapses, while in the foreground |
| `manual` | `syncNow()` |

- **Debouncing:** automatic triggers within `debounce` (default 500 ms) of
  each other collapse into a single run.
- **Offline:** automatic triggers are skipped while the connectivity source
  says offline (`skipWhenOffline`). `syncNow()` always runs.
- **Connectivity is only a hint:** the engine handles unreachable servers
  safely either way.
- **Retries:** without the `retryDue` wake-up, a failed delivery would wait
  for the next resume or connectivity change. With it, retries happen on
  schedule while the app is open.

## Status

`SyncStatus` exposes:

- `isSyncing`
- `isOnline`
- `lastTrigger`
- `lastResult` (the full `SyncRunResult`)
- `lastCompletedAt`
- `lastError` (unexpected failures such as storage errors)
- `pendingOperations` and `failedOperations` (rejected or in conflict)
- `authenticationRequired`

## Background execution

This package does foreground synchronization only. Android and iOS decide if
and when background work runs, so nothing here promises it.

For opportunistic background sync, call the engine from your background task
plugin. Open your own storage and engine inside the background isolate:

```dart
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    final engine = await openSyncEngine(); // your setup code
    try {
      final result = await engine.syncNow();
      return result.isComplete;
    } finally {
      await engine.close();
    }
  });
}
```

This is safe even if the foreground app syncs at the same time. Leases
guarantee that each operation is delivered by one worker at a time, and the
idempotency key deduplicates the rare double delivery after a lease expires.

## Testing tip

`dispose()` doesn't await stream cancellations. A broadcast subscription's
`cancel()` returns a root-zone future, and awaiting it inside
`flutter_test`'s fake-async zone would hang later `tester.pump` calls. Do the
same in your own `dispose` methods.
