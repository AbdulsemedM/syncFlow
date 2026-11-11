# syncflow_test

Test utilities for [SyncFlow](../syncflow):

- `InMemorySyncStorage`: a complete `SyncStorage` for tests and prototypes.
- `FakeClock`: a clock that moves only when told to.
- `SequentialIdGenerator`: predictable IDs (`id-1`, `id-2`, ...).
- `buildTestOperation`: valid operations with sensible defaults.
- `runSyncStorageContractTests`: the contract suite every storage adapter
  should pass.

## Verifying a custom storage adapter

```dart
import 'package:syncflow_test/syncflow_test.dart';

void main() {
  // The factory must return a fresh, empty, uninitialized storage.
  runSyncStorageContractTests(() => MyStorage.inMemory());
}
```
