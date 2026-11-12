## 0.5.0-dev.1

- Conflict resolution: `SyncConflict` records stored atomically with the
  `conflict` state; `UseLocal`, `UseRemote`, `MergeResolution` and
  `RequireManualResolution`; `ConflictStrategy` (server wins, client wins,
  last write wins, manual); per-entity `conflictResolver`;
  `SyncEngine.resolveConflict`; `ConflictDetected` and `ConflictResolved` events.
- Pull synchronization: `PullEndpoint`, `SyncEntityAdapter`, `RemoteChange`
  with tombstones, `parsePullPage`; each page applied atomically with its
  checkpoint; expired-cursor full resync; `hasPendingLocalChanges` flag;
  `RemoteChangesApplied`, `FullResyncStarted` and `PullFailed` events.
- `syncNow()` pushes, then pulls. `SyncEngineConfig.pullEnabled` and
  `maxPullPagesPerEntity`. `SyncRunResult` reports `conflictsResolved`,
  `pulledChanges` and `pullFailures`.
- **Breaking:** `SyncStorage.saveConflict`, `getConflict`, `listConflicts`
  and `deleteConflict` added.

## 0.4.0-dev.1

- `SyncEntity`, `RestEndpoint` and `SyncEntityRegistry` for entity registration.
- `RestRequestBuilder`: REST mapping per operation type, `{id}` path templates,
  `If-Match` from the base version, per-entity request builder override.
- Temporary-ID rewriting: acknowledged creates store a `SyncIdMapping` in the
  same transaction as the acknowledgement; paths and declared references are
  resolved at send time. New `EntityIdAssigned` event.
- Dependency failure propagation: dependents of a rejected operation are
  rejected (category `dependency`), transitively. Cancelled dependencies no
  longer block. New transitions `pending/retryScheduled → rejected`.
- `OperationQueue.retry` re-queues a rejected operation and the dependents
  rejected because of it.
- **Breaking:** `SyncStorage.findDependentOperations`, `saveIdMapping` and
  `resolveServerId` added; `SyncEngine` accepts `entities`.
- `UnknownEntityException`, `UnsupportedOperationTypeException`.

## 0.3.0-dev.1

- **Breaking:** `SyncStorage.runInTransaction` added (atomic, nestable,
  joins the caller's database transaction where supported).
- `OperationQueue.enqueue` runs in a storage transaction, enabling the
  transactional outbox; the in-process enqueue lock was removed.
- `SyncStorageException` for backend failures.

## 0.2.0-dev.1

- `SyncEngine`: lease-based delivery with bounded concurrency, dependency
  gating, account isolation, authentication pause, manual pause, crash
  recovery and coalesced `syncNow()` runs.
- `RetryPolicy` and `ExponentialBackoffRetryPolicy` (jitter, `Retry-After`,
  optional attempt limit).
- `SyncResponseClassifier` and `HttpResponseClassifier`, producing
  `DeliveryOutcome`s.
- `SyncEvent` stream (`OperationAcknowledged`, `OperationRetryScheduled`,
  `OperationRejected`, `OperationConflicted`, `OperationLeaseLost`,
  `AuthenticationRequired`, run and recovery events).
- `parseRetryAfter` and `parseHttpDate`.
- `OperationQueue` orders mutations of the same entity automatically
  (`serializeEntityOperations`).
- **Breaking:** `SyncStorage.findLatestActiveOperation` added.
- `SyncRequest.copyWith`.

## 0.1.0-dev.1

- Initial operation model (`SyncOperation`, `SyncOperationType`,
  `SyncOperationStatus`) with validated state transitions.
- `SyncMutation` and `OperationQueue` (enqueue, eligibility, cancel).
- `SyncStorage` and `SyncTransport` contracts.
- `SyncRequest`, `SyncResponse`, `SyncError`, `SyncCheckpoint` models.
- Typed exceptions, `Clock` and `IdGenerator` abstractions.
