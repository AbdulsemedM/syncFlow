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
