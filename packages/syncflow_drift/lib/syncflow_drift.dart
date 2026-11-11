/// Drift (SQLite) storage adapter for SyncFlow.
///
/// Use `DriftSyncStorage(appDatabase)` to share your application's database
/// and get an atomic transactional outbox, or `DriftSyncStorage.separate` for
/// a dedicated metadata database.
library;

export 'src/drift_sync_storage.dart';
export 'src/sync_flow_database.dart';
