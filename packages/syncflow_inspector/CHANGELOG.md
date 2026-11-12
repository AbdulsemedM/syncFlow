## 0.7.0-dev.1

- Initial `SyncInspector`: queue snapshot, operation list and details,
  bounded event timeline, developer actions (retry, cancel, conflict
  resolution, pause, resume, sync now) scoped to the active account.
- `SyncRedactor` for payloads and conflict states; masked idempotency keys.
- `exportReport()` diagnostic JSON with redaction and account placeholder.
- `SyncInspectorPage`, `OperationDetailPage` and `showSyncInspector`.
- Disabled in release builds unless `enabled: true`.
