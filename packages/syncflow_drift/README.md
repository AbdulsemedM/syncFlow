# syncflow_drift

Drift (SQLite) storage for [SyncFlow](../syncflow).

- Works with **your existing Drift database**. SyncFlow adds its own
  `syncflow_*` tables and versions them independently. Your schema, your
  migrations and your `schemaVersion` stay untouched, and no code generation is
  needed.
- **Transactional outbox.** A local write and its queued operation commit
  together or not at all.
- **Atomic leases.** Every write is a compare-and-set on the operation's
  revision, so concurrent workers cannot both claim an operation, and a stalled
  worker cannot overwrite recovered state.
- **Durable.** Pending operations survive restarts. Corrupt rows are reported,
  never skipped silently.
- Passes the full `syncflow_test` storage contract suite.

## Usage

```dart
final database = AppDatabase(NativeDatabase.createInBackground(file));

final storage = DriftSyncStorage(database); // shared mode
await storage.initialize();

final queue = OperationQueue(storage: storage);

// The customer row and its sync operation commit atomically.
await database.transaction(() async {
  await database.into(database.customers).insert(customer);
  await queue.enqueue(
    SyncMutation.create(
      entity: 'customers',
      id: customer.id,
      data: customer.toJson(),
    ),
    accountId: currentAccountId,
  );
});
```

### Separate database

```dart
final storage = DriftSyncStorage.separate(
  NativeDatabase.createInBackground(syncFile),
);
```

This is simpler to wire up, but it **cannot be atomic** with your application
data: a crash between your write and `enqueue` can lose one of them. Prefer
the shared mode.

## Schema

| Table | Purpose |
| --- | --- |
| `syncflow_operations` | Durable operations, leases and lifecycle state |
| `syncflow_checkpoints` | Pull cursors per account and entity |
| `syncflow_metadata` | SyncFlow schema version |

Leases are stored on the operation row rather than in a separate locks table,
so claiming an operation is a single atomic `UPDATE`.

A database written by a newer SyncFlow version is refused with a
`SyncStorageException`; its data is left intact.
