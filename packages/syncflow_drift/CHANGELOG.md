## 0.7.0-dev.1

- `listOperations` (`ORDER BY created_at DESC, seq DESC` with `LIMIT` and
  `OFFSET`).

## 0.6.0-dev.1

- `countOperations` (`GROUP BY status`).

## 0.5.0-dev.1

- Schema version 3: `syncflow_conflicts` table.
- Conflict persistence methods.

## 0.4.0-dev.1

- Schema version 2: `syncflow_id_mappings` table (migration tested with pending
  operations).
- `findDependentOperations` via `json_each`, `saveIdMapping`, `resolveServerId`.

## 0.3.0-dev.1

- Initial `DriftSyncStorage` (shared and separate database modes), passing the
  full storage contract suite.
- Independent, versioned `syncflow_*` schema with indexed eligibility, entity
  and lease queries.
- Transactional outbox through Drift's zone-based transactions.
- `SyncFlowDatabase` for dedicated metadata databases.
