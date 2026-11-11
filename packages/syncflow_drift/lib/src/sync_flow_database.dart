import 'package:drift/drift.dart';

/// A minimal Drift database for storing SyncFlow metadata separately from the
/// application's data.
///
/// Prefer passing your application's own database to `DriftSyncStorage`:
/// only a shared database can commit a local write and its operation
/// atomically. Use this class when that is not possible, and accept that a
/// crash between the two writes can lose or orphan one of them.
class SyncFlowDatabase extends GeneratedDatabase {
  /// Opens a SyncFlow-only database on [executor], for example
  /// `NativeDatabase.createInBackground(file)`.
  SyncFlowDatabase(super.executor);

  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];

  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];

  // SyncFlow manages its own tables and version; Drift's version is unused.
  @override
  int get schemaVersion => 1;
}
