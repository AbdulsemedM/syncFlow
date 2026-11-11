## 0.1.0-dev.1

- Initial operation model (`SyncOperation`, `SyncOperationType`,
  `SyncOperationStatus`) with validated state transitions.
- `SyncMutation` and `OperationQueue` (enqueue, eligibility, cancel).
- `SyncStorage` and `SyncTransport` contracts.
- `SyncRequest`, `SyncResponse`, `SyncError`, `SyncCheckpoint` models.
- Typed exceptions, `Clock` and `IdGenerator` abstractions.
