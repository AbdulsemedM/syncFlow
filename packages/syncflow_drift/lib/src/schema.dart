// SyncFlow's own SQLite schema, managed independently of the application's
// Drift schema. Every object is prefixed with `syncflow_` so it can live in the
// application's database without clashing with its tables.

/// Table holding SyncFlow's schema version and other engine metadata.
const metadataTable = 'syncflow_metadata';

/// Table holding durable operations.
const operationsTable = 'syncflow_operations';

/// Table holding pull cursors per account and entity.
const checkpointsTable = 'syncflow_checkpoints';

/// Table mapping local entity IDs to server-assigned IDs.
const idMappingsTable = 'syncflow_id_mappings';

/// Table holding unresolved conflicts.
const conflictsTable = 'syncflow_conflicts';

/// Metadata key under which the schema version is stored.
const schemaVersionKey = 'schema_version';

/// Statement creating [metadataTable]. Runs before the version is read.
const createMetadataTable = '''
CREATE TABLE IF NOT EXISTS $metadataTable (
  key TEXT NOT NULL PRIMARY KEY,
  value TEXT NOT NULL
)''';

/// Migration steps. `migrations[i]` upgrades schema version `i` to `i + 1`.
///
/// Never edit a released step: append a new one. Steps must preserve every
/// stored operation.
const List<List<String>> migrations = [
  // 0 -> 1: initial schema.
  [
    '''
CREATE TABLE $operationsTable (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT NOT NULL UNIQUE,
  account_id TEXT NOT NULL,
  entity_name TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  operation_type TEXT NOT NULL,
  status TEXT NOT NULL,
  payload TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  base_version TEXT,
  dependencies TEXT NOT NULL,
  attempts INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  last_attempt_at INTEGER,
  next_attempt_at INTEGER,
  lease_owner TEXT,
  lease_expires_at INTEGER,
  last_error TEXT,
  schema_version INTEGER NOT NULL,
  revision INTEGER NOT NULL
)''',
    // Eligibility: account + status, then due time.
    'CREATE INDEX syncflow_operations_eligible '
        'ON $operationsTable (account_id, status, next_attempt_at)',
    // Ordering within an entity (findLatestActiveOperation).
    'CREATE INDEX syncflow_operations_entity '
        'ON $operationsTable (account_id, entity_name, entity_id, created_at)',
    // Lease recovery.
    'CREATE INDEX syncflow_operations_lease '
        'ON $operationsTable (lease_expires_at) '
        'WHERE lease_expires_at IS NOT NULL',
    // Diagnostics and server-side correlation.
    'CREATE INDEX syncflow_operations_idempotency_key '
        'ON $operationsTable (idempotency_key)',
    '''
CREATE TABLE $checkpointsTable (
  account_id TEXT NOT NULL,
  entity_name TEXT NOT NULL,
  cursor TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (account_id, entity_name)
)''',
  ],
  // 1 -> 2: server-assigned ID mappings (temporary-ID rewriting).
  [
    '''
CREATE TABLE $idMappingsTable (
  account_id TEXT NOT NULL,
  entity_name TEXT NOT NULL,
  local_id TEXT NOT NULL,
  server_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (account_id, entity_name, local_id)
)''',
  ],
  // 2 -> 3: persisted conflicts awaiting resolution.
  [
    '''
CREATE TABLE $conflictsTable (
  operation_id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL,
  entity_name TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  remote_data TEXT,
  remote_version TEXT,
  detected_at INTEGER NOT NULL
)''',
    'CREATE INDEX syncflow_conflicts_account '
        'ON $conflictsTable (account_id, detected_at)',
  ],
];

/// The schema version this build of the adapter writes.
int get latestSchemaVersion => migrations.length;
