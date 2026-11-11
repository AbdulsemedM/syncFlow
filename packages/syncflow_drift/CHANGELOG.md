## 0.3.0-dev.1

- Initial `DriftSyncStorage` (shared and separate database modes), passing the
  full storage contract suite.
- Independent, versioned `syncflow_*` schema with indexed eligibility, entity
  and lease queries.
- Transactional outbox through Drift's zone-based transactions.
- `SyncFlowDatabase` for dedicated metadata databases.
