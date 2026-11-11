import 'dart:async';
import 'dart:convert';

import 'package:syncflow/syncflow.dart';

/// A [SyncStorage] that keeps everything in memory.
///
/// Intended for tests and prototypes: nothing survives the process. Stored
/// operations are round-tripped through JSON, which both deep-copies them and
/// fails fast on payloads a real database could not persist.
///
/// Every call is serialized through a lock, and [runInTransaction] holds the
/// lock for the whole transaction (calls made inside it re-enter through a
/// zone marker). This mirrors how a database serializes writers.
final class InMemorySyncStorage implements SyncStorage {
  final Map<String, _StoredOperation> _operations = {};
  final Map<(String, String), SyncCheckpoint> _checkpoints = {};
  int _nextSequence = 0;
  bool _initialized = false;
  bool _closed = false;

  final Object _transactionZoneKey = Object();
  Future<void> _lock = Future.value();

  /// Number of stored operations, regardless of state or account.
  int get length => _operations.length;

  /// Snapshot of every stored operation, in insertion order.
  List<SyncOperation> get allOperations => [
        for (final stored in _operations.values) _decode(stored.json),
      ];

  @override
  Future<void> initialize() async {
    if (_closed) throw StateError('InMemorySyncStorage has been closed.');
    _initialized = true;
  }

  @override
  Future<T> runInTransaction<T>(Future<T> Function() action) {
    if (_inTransaction) return _savepoint(action);
    return _exclusive(
      () => runZoned(
        () => _savepoint(action),
        zoneValues: {_transactionZoneKey: true},
      ),
    );
  }

  @override
  Future<void> insertOperation(SyncOperation operation) => _guard(() async {
        if (_operations.containsKey(operation.id)) {
          throw DuplicateOperationException(operation.id);
        }
        _put(operation);
      });

  @override
  Future<void> insertOperations(List<SyncOperation> operations) =>
      _guard(() async {
        final seen = <String>{};
        for (final operation in operations) {
          if (_operations.containsKey(operation.id) ||
              !seen.add(operation.id)) {
            throw DuplicateOperationException(operation.id);
          }
        }
        // Encode everything before mutating so a serialization failure leaves
        // the store untouched.
        final encoded = [
          for (final operation in operations) _encode(operation)
        ];
        for (var i = 0; i < operations.length; i++) {
          _operations[operations[i].id] =
              _StoredOperation(encoded[i], _nextSequence++);
        }
      });

  @override
  Future<SyncOperation?> getOperation(String operationId) => _guard(() async {
        final stored = _operations[operationId];
        return stored == null ? null : _decode(stored.json);
      });

  @override
  Future<List<SyncOperation>> getEligibleOperations({
    required String accountId,
    required DateTime now,
    required int limit,
  }) =>
      _guard(() async {
        if (limit < 1) {
          throw ArgumentError.value(limit, 'limit', 'must be positive');
        }
        final candidates = <(SyncOperation, int)>[
          for (final stored in _operations.values)
            if (_decode(stored.json) case final operation
                when operation.accountId == accountId && operation.isDueAt(now))
              (operation, stored.sequence),
        ]..sort((a, b) {
            final byCreation = a.$1.createdAt.compareTo(b.$1.createdAt);
            return byCreation != 0 ? byCreation : a.$2.compareTo(b.$2);
          });
        return [for (final (operation, _) in candidates.take(limit)) operation];
      });

  @override
  Future<SyncOperation?> findLatestActiveOperation({
    required String accountId,
    required String entityName,
    required String entityId,
  }) =>
      _guard(() async {
        (SyncOperation, int)? latest;
        for (final stored in _operations.values) {
          final operation = _decode(stored.json);
          if (operation.accountId != accountId ||
              operation.entityName != entityName ||
              operation.entityId != entityId ||
              operation.status.isTerminal) {
            continue;
          }
          if (latest == null) {
            latest = (operation, stored.sequence);
            continue;
          }
          final (current, sequence) = latest;
          final byCreation = operation.createdAt.compareTo(current.createdAt);
          if (byCreation > 0 ||
              (byCreation == 0 && stored.sequence > sequence)) {
            latest = (operation, stored.sequence);
          }
        }
        return latest?.$1;
      });

  @override
  Future<SyncOperation> updateOperation(SyncOperation operation) =>
      _guard(() async {
        final current = _current(operation.id);
        if (current.revision != operation.revision) {
          throw StaleOperationException(
            operationId: operation.id,
            expectedRevision: operation.revision,
            actualRevision: current.revision,
          );
        }
        return _put(operation.copyWith(revision: operation.revision + 1));
      });

  @override
  Future<void> deleteOperation(String operationId) => _guard(() async {
        _operations.remove(operationId);
      });

  @override
  Future<SyncOperation?> acquireLease({
    required String operationId,
    required String workerId,
    required DateTime now,
    required DateTime expiresAt,
  }) =>
      _guard(() async {
        final stored = _operations[operationId];
        if (stored == null) return null;
        final operation = _decode(stored.json);
        if (!operation.isDueAt(now)) return null;
        final leased = operation.transitionTo(
          SyncOperationStatus.leased,
          at: now,
          leaseOwner: workerId,
          leaseExpiresAt: expiresAt,
        );
        return _put(leased.copyWith(revision: operation.revision + 1));
      });

  @override
  Future<bool> releaseLease({
    required String operationId,
    required String workerId,
    required DateTime now,
  }) =>
      _guard(() async {
        final stored = _operations[operationId];
        if (stored == null) return false;
        final operation = _decode(stored.json);
        if (operation.status != SyncOperationStatus.leased ||
            operation.leaseOwner != workerId) {
          return false;
        }
        final released = operation.transitionTo(
          SyncOperationStatus.pending,
          at: now,
        );
        _put(released.copyWith(revision: operation.revision + 1));
        return true;
      });

  @override
  Future<int> recoverExpiredLeases(DateTime now) => _guard(() async {
        var recovered = 0;
        for (final stored in _operations.values.toList()) {
          final operation = _decode(stored.json);
          final expiresAt = operation.leaseExpiresAt;
          if (!operation.status.isInFlight ||
              expiresAt == null ||
              expiresAt.isAfter(now)) {
            continue;
          }
          final pending = operation.transitionTo(
            SyncOperationStatus.pending,
            at: now,
          );
          _put(pending.copyWith(revision: operation.revision + 1));
          recovered++;
        }
        return recovered;
      });

  @override
  Future<void> saveCheckpoint(SyncCheckpoint checkpoint) => _guard(() async {
        _checkpoints[(checkpoint.accountId, checkpoint.entityName)] =
            checkpoint;
      });

  @override
  Future<SyncCheckpoint?> getCheckpoint({
    required String accountId,
    required String entityName,
  }) =>
      _guard(() async => _checkpoints[(accountId, entityName)]);

  @override
  Future<void> close() async {
    _closed = true;
  }

  bool get _inTransaction => Zone.current[_transactionZoneKey] == true;

  // Runs [body] under the lock, or directly when already inside this
  // storage's transaction.
  Future<T> _guard<T>(Future<T> Function() body) {
    _ensureOpen();
    return _inTransaction ? body() : _exclusive(body);
  }

  Future<T> _exclusive<T>(Future<T> Function() body) {
    final result = _lock.then((_) => body());
    _lock = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  // Snapshot-based savepoint: restores the state if [action] fails.
  Future<T> _savepoint<T>(Future<T> Function() action) async {
    _ensureOpen();
    final operations = Map.of(_operations);
    final checkpoints = Map.of(_checkpoints);
    final nextSequence = _nextSequence;
    try {
      return await action();
    } catch (_) {
      _operations
        ..clear()
        ..addAll(operations);
      _checkpoints
        ..clear()
        ..addAll(checkpoints);
      _nextSequence = nextSequence;
      rethrow;
    }
  }

  void _ensureOpen() {
    if (_closed) throw StateError('InMemorySyncStorage has been closed.');
    if (!_initialized) {
      throw StateError('InMemorySyncStorage.initialize() was not called.');
    }
  }

  SyncOperation _current(String operationId) {
    final stored = _operations[operationId];
    if (stored == null) throw OperationNotFoundException(operationId);
    return _decode(stored.json);
  }

  // Replaces or inserts, preserving the original insertion sequence.
  SyncOperation _put(SyncOperation operation) {
    final json = _encode(operation);
    final sequence = _operations[operation.id]?.sequence ?? _nextSequence++;
    _operations[operation.id] = _StoredOperation(json, sequence);
    return _decode(json);
  }

  static String _encode(SyncOperation operation) =>
      jsonEncode(operation.toJson());

  static SyncOperation _decode(String json) =>
      SyncOperation.fromJson(jsonDecode(json) as Map<String, Object?>);
}

final class _StoredOperation {
  _StoredOperation(this.json, this.sequence);

  final String json;
  final int sequence;
}
