import '../adapters/sync_storage.dart';
import '../models/exceptions.dart';
import '../utils/clock.dart';
import '../utils/id_generator.dart';
import 'operation.dart';
import 'operation_status.dart';
import 'sync_mutation.dart';

/// Records mutations as durable operations and exposes queue queries.
///
/// The queue does not deliver anything; execution is the engine's job. It
/// guarantees that every enqueued operation is valid, persisted, and carries a
/// stable ID and idempotency key.
final class OperationQueue {
  /// Creates a queue over [storage].
  OperationQueue({
    required SyncStorage storage,
    Clock clock = const SystemClock(),
    IdGenerator idGenerator = const UuidV4Generator(),
  })  : _storage = storage,
        _clock = clock,
        _ids = idGenerator;

  final SyncStorage _storage;
  final Clock _clock;
  final IdGenerator _ids;

  /// Durably records [mutation] for [accountId] and returns the new operation.
  ///
  /// Every dependency must already exist and belong to the same account, so
  /// the dependency graph is acyclic by construction. Throws an
  /// [InvalidDependencyException] otherwise.
  ///
  /// This method only writes the operation. It does not make the application's
  /// own local write atomic with the outbox insertion; that requires a
  /// transaction-aware storage adapter.
  Future<SyncOperation> enqueue(
    SyncMutation mutation, {
    required String accountId,
  }) async {
    for (final dependencyId in mutation.dependencies) {
      final dependency = await _storage.getOperation(dependencyId);
      if (dependency == null) {
        throw InvalidDependencyException(
          dependencyId: dependencyId,
          reason: 'no such operation',
        );
      }
      if (dependency.accountId != accountId) {
        throw InvalidDependencyException(
          dependencyId: dependencyId,
          reason: 'belongs to a different account',
        );
      }
    }

    final operation = SyncOperation(
      id: _ids.next(),
      accountId: accountId,
      entityName: mutation.entity,
      entityId: mutation.id,
      operationType: mutation.type,
      payload: mutation.data,
      idempotencyKey: mutation.idempotencyKey ?? _ids.next(),
      baseVersion: mutation.baseVersion,
      dependencies: mutation.dependencies,
      schemaVersion: mutation.schemaVersion,
      createdAt: _clock.now(),
    );
    await _storage.insertOperation(operation);
    return operation;
  }

  /// Returns the operation with [operationId], or `null`.
  Future<SyncOperation?> get(String operationId) =>
      _storage.getOperation(operationId);

  /// Returns up to [limit] operations of [accountId] that are claimable now,
  /// in creation order.
  Future<List<SyncOperation>> eligible({
    required String accountId,
    int limit = 50,
  }) {
    if (limit < 1) {
      throw ArgumentError.value(limit, 'limit', 'must be positive');
    }
    return _storage.getEligibleOperations(
      accountId: accountId,
      now: _clock.now(),
      limit: limit,
    );
  }

  /// Cancels the operation with [operationId] and returns the stored result.
  ///
  /// Only operations that are not in flight or terminal can be cancelled.
  /// Throws an [OperationNotFoundException], an
  /// [InvalidStateTransitionException], or a [StaleOperationException] if a
  /// worker changed the operation concurrently.
  Future<SyncOperation> cancel(String operationId) async {
    final operation = await _storage.getOperation(operationId);
    if (operation == null) throw OperationNotFoundException(operationId);
    return _storage.updateOperation(
      operation.transitionTo(SyncOperationStatus.cancelled, at: _clock.now()),
    );
  }
}
