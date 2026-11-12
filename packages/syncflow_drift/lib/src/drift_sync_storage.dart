import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:syncflow/syncflow.dart';

import 'schema.dart';
import 'sync_flow_database.dart';

/// A [SyncStorage] backed by a Drift (SQLite) database.
///
/// ## Shared database (recommended)
///
/// Pass your application's own Drift database. SyncFlow adds its own
/// `syncflow_*` tables with its own schema version. Your schema, migrations and
/// `schemaVersion` are not touched, and no code generation is needed.
///
/// Because Drift transactions are zone-based, every storage call made inside
/// `database.transaction` joins that transaction. That gives you a
/// transactional outbox:
///
/// ```dart
/// await database.transaction(() async {
///   await database.into(database.customers).insert(customer);
///   await queue.enqueue(SyncMutation.create(...), accountId: accountId);
/// });
/// ```
///
/// Either both rows are committed or neither is.
///
/// ## Separate database
///
/// [DriftSyncStorage.separate] stores metadata in a database of its own. This
/// is simpler to wire up but cannot be atomic with your data: a crash between
/// your write and `enqueue` can lose or orphan one of them.
final class DriftSyncStorage implements SyncStorage {
  /// Stores SyncFlow metadata in [database], typically the application's own
  /// database.
  ///
  /// [close] closes [database] only if [closeDatabase] is `true`.
  DriftSyncStorage(GeneratedDatabase database, {this.closeDatabase = false})
      : _db = database;

  /// Stores SyncFlow metadata in a dedicated database opened on [executor]
  /// (for example `NativeDatabase.createInBackground(file)`), which [close]
  /// closes.
  factory DriftSyncStorage.separate(QueryExecutor executor) =>
      DriftSyncStorage(SyncFlowDatabase(executor), closeDatabase: true);

  final GeneratedDatabase _db;

  /// Whether [close] also closes the underlying database.
  final bool closeDatabase;

  bool _initialized = false;
  bool _closed = false;

  /// The schema version this adapter creates and understands.
  static int get schemaVersion => latestSchemaVersion;

  @override
  Future<void> initialize() async {
    if (_closed) throw StateError('DriftSyncStorage has been closed.');
    if (_initialized) return;
    try {
      await _db.transaction(_migrate);
    } on SyncFlowException {
      rethrow;
    } on Exception catch (error) {
      throw SyncStorageException(
        'Failed to initialize the SyncFlow schema.',
        cause: error,
      );
    }
    _initialized = true;
  }

  Future<void> _migrate() async {
    await _db.customStatement(createMetadataTable);
    final row = await _db.customSelect(
      'SELECT value FROM $metadataTable WHERE key = ?',
      variables: [Variable<String>(schemaVersionKey)],
    ).getSingleOrNull();

    final current = row == null ? 0 : int.tryParse(row.read<String>('value'));
    if (current == null) {
      throw const SyncStorageException(
        'The stored SyncFlow schema version is unreadable.',
      );
    }
    if (current > latestSchemaVersion) {
      throw SyncStorageException(
        'The database was written by a newer SyncFlow version (schema '
        '$current; this version supports up to $latestSchemaVersion). '
        'Pending operations are preserved; upgrade the app to read them.',
      );
    }
    if (current == latestSchemaVersion) return;

    for (var version = current; version < latestSchemaVersion; version++) {
      for (final statement in migrations[version]) {
        await _db.customStatement(statement);
      }
    }
    await _db.customStatement(
      'INSERT INTO $metadataTable (key, value) VALUES (?, ?) '
      'ON CONFLICT (key) DO UPDATE SET value = excluded.value',
      [schemaVersionKey, '$latestSchemaVersion'],
    );
  }

  @override
  Future<T> runInTransaction<T>(Future<T> Function() action) {
    _ensureOpen();
    return _db.transaction(action);
  }

  @override
  Future<void> insertOperation(SyncOperation operation) =>
      insertOperations([operation]);

  @override
  Future<void> insertOperations(List<SyncOperation> operations) =>
      _run(() => _db.transaction(() async {
            final seen = <String>{};
            for (final operation in operations) {
              if (!seen.add(operation.id) ||
                  await _revisionOf(operation.id) != null) {
                throw DuplicateOperationException(operation.id);
              }
            }
            for (final operation in operations) {
              final values = _columnValues(operation);
              await _db.customInsert(
                'INSERT INTO $operationsTable (${values.keys.join(', ')}) '
                'VALUES (${List.filled(values.length, '?').join(', ')})',
                variables: values.values.toList(),
              );
            }
          }));

  @override
  Future<SyncOperation?> getOperation(String operationId) =>
      _run(() => _get(operationId));

  @override
  Future<List<SyncOperation>> getEligibleOperations({
    required String accountId,
    required DateTime now,
    required int limit,
  }) =>
      _run(() async {
        if (limit < 1) {
          throw ArgumentError.value(limit, 'limit', 'must be positive');
        }
        final rows = await _db.customSelect(
          eligibleOperationsQuery,
          variables: [
            Variable<String>(accountId),
            Variable<String>(SyncOperationStatus.pending.name),
            Variable<String>(SyncOperationStatus.retryScheduled.name),
            Variable<int>(_micros(now)),
            Variable<int>(limit),
          ],
        ).get();
        return [for (final row in rows) _decode(row)];
      });

  /// The eligibility query, exposed so tests can verify its query plan.
  static const eligibleOperationsQuery = 'SELECT * FROM $operationsTable '
      'WHERE account_id = ? AND status IN (?, ?) '
      'AND (next_attempt_at IS NULL OR next_attempt_at <= ?) '
      'ORDER BY created_at, seq LIMIT ?';

  @override
  Future<SyncOperation?> findLatestActiveOperation({
    required String accountId,
    required String entityName,
    required String entityId,
  }) =>
      _run(() async {
        final row = await _db.customSelect(
          'SELECT * FROM $operationsTable '
          'WHERE account_id = ? AND entity_name = ? AND entity_id = ? '
          'AND status NOT IN (?, ?) '
          'ORDER BY created_at DESC, seq DESC LIMIT 1',
          variables: [
            Variable<String>(accountId),
            Variable<String>(entityName),
            Variable<String>(entityId),
            Variable<String>(SyncOperationStatus.acknowledged.name),
            Variable<String>(SyncOperationStatus.cancelled.name),
          ],
        ).getSingleOrNull();
        return row == null ? null : _decode(row);
      });

  @override
  Future<Map<SyncOperationStatus, int>> countOperations({
    required String accountId,
  }) =>
      _run(() async {
        final rows = await _db.customSelect(
          'SELECT status, COUNT(*) AS n FROM $operationsTable '
          'WHERE account_id = ? GROUP BY status',
          variables: [Variable<String>(accountId)],
        ).get();
        return {
          for (final row in rows)
            SyncOperationStatus.values.byName(row.read<String>('status')):
                row.read<int>('n'),
        };
      });

  @override
  Future<List<SyncOperation>> listOperations({
    required String accountId,
    required int limit,
    int offset = 0,
    Set<SyncOperationStatus>? statuses,
  }) =>
      _run(() async {
        if (limit < 1) {
          throw ArgumentError.value(limit, 'limit', 'must be positive');
        }
        if (offset < 0) {
          throw ArgumentError.value(offset, 'offset', 'must not be negative');
        }
        if (statuses != null && statuses.isEmpty) return const [];
        final statusFilter = statuses == null
            ? ''
            : 'AND status IN (${List.filled(statuses.length, '?').join(', ')}) ';
        final rows = await _db.customSelect(
          'SELECT * FROM $operationsTable WHERE account_id = ? '
          '$statusFilter'
          'ORDER BY created_at DESC, seq DESC LIMIT ? OFFSET ?',
          variables: [
            Variable<String>(accountId),
            for (final status in statuses ?? const <SyncOperationStatus>{})
              Variable<String>(status.name),
            Variable<int>(limit),
            Variable<int>(offset),
          ],
        ).get();
        return [for (final row in rows) _decode(row)];
      });

  @override
  Future<List<SyncOperation>> findDependentOperations(String operationId) =>
      _run(() async {
        // json_each matches whole array elements, so "op-1" never matches
        // "op-10".
        final rows = await _db.customSelect(
          'SELECT * FROM $operationsTable WHERE EXISTS ('
          'SELECT 1 FROM json_each($operationsTable.dependencies) '
          'WHERE json_each.value = ?) '
          'ORDER BY created_at, seq',
          variables: [Variable<String>(operationId)],
        ).get();
        return [for (final row in rows) _decode(row)];
      });

  @override
  Future<void> saveIdMapping(SyncIdMapping mapping) => _run(() async {
        await _db.customInsert(
          'INSERT INTO $idMappingsTable '
          '(account_id, entity_name, local_id, server_id, created_at) '
          'VALUES (?, ?, ?, ?, ?) '
          'ON CONFLICT (account_id, entity_name, local_id) DO UPDATE SET '
          'server_id = excluded.server_id, created_at = excluded.created_at',
          variables: [
            Variable<String>(mapping.accountId),
            Variable<String>(mapping.entityName),
            Variable<String>(mapping.localId),
            Variable<String>(mapping.serverId),
            Variable<int>(_micros(mapping.createdAt)),
          ],
        );
      });

  @override
  Future<String?> resolveServerId({
    required String accountId,
    required String entityName,
    required String localId,
  }) =>
      _run(() async {
        final row = await _db.customSelect(
          'SELECT server_id FROM $idMappingsTable '
          'WHERE account_id = ? AND entity_name = ? AND local_id = ?',
          variables: [
            Variable<String>(accountId),
            Variable<String>(entityName),
            Variable<String>(localId),
          ],
        ).getSingleOrNull();
        return row?.read<String>('server_id');
      });

  @override
  Future<void> saveConflict(SyncConflict conflict) => _run(() async {
        final data = conflict.remoteData;
        await _db.customInsert(
          'INSERT INTO $conflictsTable (operation_id, account_id, entity_name, '
          'entity_id, remote_data, remote_version, detected_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?) '
          'ON CONFLICT (operation_id) DO UPDATE SET '
          'account_id = excluded.account_id, '
          'entity_name = excluded.entity_name, '
          'entity_id = excluded.entity_id, '
          'remote_data = excluded.remote_data, '
          'remote_version = excluded.remote_version, '
          'detected_at = excluded.detected_at',
          variables: [
            Variable<String>(conflict.operationId),
            Variable<String>(conflict.accountId),
            Variable<String>(conflict.entityName),
            Variable<String>(conflict.entityId),
            Variable<String>(data == null ? null : jsonEncode(data)),
            Variable<String>(conflict.remoteVersion),
            Variable<int>(_micros(conflict.detectedAt)),
          ],
        );
      });

  @override
  Future<SyncConflict?> getConflict(String operationId) => _run(() async {
        final row = await _db.customSelect(
          'SELECT * FROM $conflictsTable WHERE operation_id = ?',
          variables: [Variable<String>(operationId)],
        ).getSingleOrNull();
        return row == null ? null : _decodeConflict(row);
      });

  @override
  Future<List<SyncConflict>> listConflicts({required String accountId}) =>
      _run(() async {
        final rows = await _db.customSelect(
          'SELECT * FROM $conflictsTable WHERE account_id = ? '
          'ORDER BY detected_at, operation_id',
          variables: [Variable<String>(accountId)],
        ).get();
        return [for (final row in rows) _decodeConflict(row)];
      });

  @override
  Future<void> deleteConflict(String operationId) => _run(() async {
        await _db.customUpdate(
          'DELETE FROM $conflictsTable WHERE operation_id = ?',
          variables: [Variable<String>(operationId)],
          updateKind: UpdateKind.delete,
        );
      });

  static SyncConflict _decodeConflict(QueryRow row) {
    final rawData = row.readNullable<String>('remote_data');
    final data = rawData == null ? null : jsonDecode(rawData);
    if (data is! Map<String, Object?>?) {
      throw FormatException(
        'Corrupt SyncFlow conflict "${row.read<String>('operation_id')}": '
        'remote_data is not a JSON object.',
      );
    }
    return SyncConflict(
      operationId: row.read<String>('operation_id'),
      accountId: row.read<String>('account_id'),
      entityName: row.read<String>('entity_name'),
      entityId: row.read<String>('entity_id'),
      remoteData: data,
      remoteVersion: row.readNullable<String>('remote_version'),
      detectedAt: _fromMicros(row.read<int>('detected_at')),
    );
  }

  @override
  Future<SyncOperation> updateOperation(SyncOperation operation) =>
      _run(() async {
        final stored = await _compareAndSet(
          operation,
          expectedRevision: operation.revision,
        );
        if (stored != null) return stored;
        final actual = await _revisionOf(operation.id);
        if (actual == null) throw OperationNotFoundException(operation.id);
        throw StaleOperationException(
          operationId: operation.id,
          expectedRevision: operation.revision,
          actualRevision: actual,
        );
      });

  @override
  Future<void> deleteOperation(String operationId) => _run(() async {
        await _db.customUpdate(
          'DELETE FROM $operationsTable WHERE id = ?',
          variables: [Variable<String>(operationId)],
          updateKind: UpdateKind.delete,
        );
      });

  @override
  Future<SyncOperation?> acquireLease({
    required String operationId,
    required String workerId,
    required DateTime now,
    required DateTime expiresAt,
  }) =>
      _run(() async {
        final current = await _get(operationId);
        if (current == null || !current.isDueAt(now)) return null;
        return _compareAndSet(
          current.transitionTo(
            SyncOperationStatus.leased,
            at: now,
            leaseOwner: workerId,
            leaseExpiresAt: expiresAt,
          ),
          expectedRevision: current.revision,
        );
      });

  @override
  Future<bool> releaseLease({
    required String operationId,
    required String workerId,
    required DateTime now,
  }) =>
      _run(() async {
        final current = await _get(operationId);
        if (current == null ||
            current.status != SyncOperationStatus.leased ||
            current.leaseOwner != workerId) {
          return false;
        }
        final released = await _compareAndSet(
          current.transitionTo(SyncOperationStatus.pending, at: now),
          expectedRevision: current.revision,
        );
        return released != null;
      });

  @override
  Future<int> recoverExpiredLeases(DateTime now) =>
      _run(() => _db.transaction(() async {
            final rows = await _db.customSelect(
              'SELECT * FROM $operationsTable '
              'WHERE status IN (?, ?) AND lease_expires_at <= ?',
              variables: [
                Variable<String>(SyncOperationStatus.leased.name),
                Variable<String>(SyncOperationStatus.sending.name),
                Variable<int>(_micros(now)),
              ],
            ).get();
            var recovered = 0;
            for (final row in rows) {
              final operation = _decode(row);
              final pending = await _compareAndSet(
                operation.transitionTo(SyncOperationStatus.pending, at: now),
                expectedRevision: operation.revision,
              );
              if (pending != null) recovered++;
            }
            return recovered;
          }));

  @override
  Future<void> saveCheckpoint(SyncCheckpoint checkpoint) => _run(() async {
        await _db.customInsert(
          'INSERT INTO $checkpointsTable '
          '(account_id, entity_name, cursor, updated_at) VALUES (?, ?, ?, ?) '
          'ON CONFLICT (account_id, entity_name) DO UPDATE SET '
          'cursor = excluded.cursor, updated_at = excluded.updated_at',
          variables: [
            Variable<String>(checkpoint.accountId),
            Variable<String>(checkpoint.entityName),
            Variable<String>(checkpoint.cursor),
            Variable<int>(_micros(checkpoint.updatedAt)),
          ],
        );
      });

  @override
  Future<SyncCheckpoint?> getCheckpoint({
    required String accountId,
    required String entityName,
  }) =>
      _run(() async {
        final row = await _db.customSelect(
          'SELECT cursor, updated_at FROM $checkpointsTable '
          'WHERE account_id = ? AND entity_name = ?',
          variables: [
            Variable<String>(accountId),
            Variable<String>(entityName),
          ],
        ).getSingleOrNull();
        if (row == null) return null;
        return SyncCheckpoint(
          accountId: accountId,
          entityName: entityName,
          cursor: row.read<String>('cursor'),
          updatedAt: _fromMicros(row.read<int>('updated_at')),
        );
      });

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (closeDatabase) await _db.close();
  }

  // ---------------------------------------------------------------------------

  // Runs a storage call, translating backend failures. SyncFlow exceptions,
  // corrupt-record FormatExceptions and Errors pass through unchanged.
  Future<T> _run<T>(Future<T> Function() body) async {
    _ensureOpen();
    try {
      return await body();
    } on SyncFlowException {
      rethrow;
    } on FormatException {
      rethrow;
    } on Exception catch (error) {
      throw SyncStorageException('A SyncFlow storage call failed.',
          cause: error);
    }
  }

  void _ensureOpen() {
    if (_closed) throw StateError('DriftSyncStorage has been closed.');
    if (!_initialized) {
      throw StateError('DriftSyncStorage.initialize() was not called.');
    }
  }

  Future<SyncOperation?> _get(String operationId) async {
    final row = await _db.customSelect(
      'SELECT * FROM $operationsTable WHERE id = ?',
      variables: [Variable<String>(operationId)],
    ).getSingleOrNull();
    return row == null ? null : _decode(row);
  }

  Future<int?> _revisionOf(String operationId) async {
    final row = await _db.customSelect(
      'SELECT revision FROM $operationsTable WHERE id = ?',
      variables: [Variable<String>(operationId)],
    ).getSingleOrNull();
    return row?.read<int>('revision');
  }

  // Writes [next] only if the stored revision is still [expectedRevision].
  // Returns the stored operation, or null if another writer got there first.
  Future<SyncOperation?> _compareAndSet(
    SyncOperation next, {
    required int expectedRevision,
  }) async {
    final stored = next.copyWith(revision: expectedRevision + 1);
    final values = _columnValues(stored)..remove('id');
    final changed = await _db.customUpdate(
      'UPDATE $operationsTable SET '
      '${values.keys.map((column) => '$column = ?').join(', ')} '
      'WHERE id = ? AND revision = ?',
      variables: [
        ...values.values,
        Variable<String>(next.id),
        Variable<int>(expectedRevision),
      ],
      updateKind: UpdateKind.update,
    );
    return changed == 1 ? stored : null;
  }

  static Map<String, Variable<Object>> _columnValues(SyncOperation op) => {
        'id': Variable<String>(op.id),
        'account_id': Variable<String>(op.accountId),
        'entity_name': Variable<String>(op.entityName),
        'entity_id': Variable<String>(op.entityId),
        'operation_type': Variable<String>(op.operationType.name),
        'status': Variable<String>(op.status.name),
        'payload': Variable<String>(jsonEncode(op.payload)),
        'idempotency_key': Variable<String>(op.idempotencyKey),
        'base_version': Variable<String>(op.baseVersion),
        'dependencies': Variable<String>(jsonEncode(op.dependencies)),
        'attempts': Variable<int>(op.attempts),
        'created_at': Variable<int>(_micros(op.createdAt)),
        'updated_at': Variable<int>(_micros(op.updatedAt)),
        'last_attempt_at': Variable<int>(_microsOrNull(op.lastAttemptAt)),
        'next_attempt_at': Variable<int>(_microsOrNull(op.nextAttemptAt)),
        'lease_owner': Variable<String>(op.leaseOwner),
        'lease_expires_at': Variable<int>(_microsOrNull(op.leaseExpiresAt)),
        'last_error': Variable<String>(
          op.lastError == null ? null : jsonEncode(op.lastError!.toJson()),
        ),
        'schema_version': Variable<int>(op.schemaVersion),
        'revision': Variable<int>(op.revision),
      };

  // Decodes a row through SyncOperation.fromJson so every invariant is
  // re-validated. Corrupt rows raise a FormatException naming the operation;
  // they are never skipped silently.
  static SyncOperation _decode(QueryRow row) {
    final data = row.data;
    try {
      return SyncOperation.fromJson({
        'id': data['id'],
        'accountId': data['account_id'],
        'entityName': data['entity_name'],
        'entityId': data['entity_id'],
        'operationType': data['operation_type'],
        'status': data['status'],
        'payload': _json(data['payload'], 'payload'),
        'idempotencyKey': data['idempotency_key'],
        'baseVersion': data['base_version'],
        'dependencies': _json(data['dependencies'], 'dependencies'),
        'attempts': data['attempts'],
        'createdAt': _iso(data['created_at'], 'created_at'),
        'updatedAt': _iso(data['updated_at'], 'updated_at'),
        'lastAttemptAt': _iso(data['last_attempt_at'], 'last_attempt_at'),
        'nextAttemptAt': _iso(data['next_attempt_at'], 'next_attempt_at'),
        'leaseOwner': data['lease_owner'],
        'leaseExpiresAt': _iso(data['lease_expires_at'], 'lease_expires_at'),
        'lastError': data['last_error'] == null
            ? null
            : _json(data['last_error'], 'last_error'),
        'schemaVersion': data['schema_version'],
        'revision': data['revision'],
      });
    } on FormatException catch (error) {
      throw FormatException(
        'Corrupt SyncFlow operation "${data['id']}": ${error.message}',
      );
    } on ArgumentError catch (error) {
      throw FormatException(
        'Corrupt SyncFlow operation "${data['id']}": ${error.message}',
      );
    }
  }

  static Object? _json(Object? value, String column) {
    if (value is! String) {
      throw FormatException('Column "$column" is not JSON text.');
    }
    return jsonDecode(value);
  }

  static String? _iso(Object? value, String column) => switch (value) {
        null => null,
        final int micros => _fromMicros(micros).toIso8601String(),
        _ => throw FormatException('Column "$column" is not a timestamp.'),
      };

  static int _micros(DateTime time) => time.toUtc().microsecondsSinceEpoch;

  static int? _microsOrNull(DateTime? time) =>
      time == null ? null : _micros(time);

  static DateTime _fromMicros(int micros) =>
      DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);
}
