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
  ///
  /// When [serializeEntityOperations] is `true` (the default), each new
  /// operation automatically depends on the previous unfinished operation for
  /// the same entity, so an update can never overtake the create before it.
  OperationQueue({
    required SyncStorage storage,
    Clock clock = const SystemClock(),
    IdGenerator idGenerator = const UuidV4Generator(),
    this.serializeEntityOperations = true,
  })  : _storage = storage,
        _clock = clock,
        _ids = idGenerator;

  final SyncStorage _storage;
  final Clock _clock;
  final IdGenerator _ids;

  /// Whether operations on the same entity are delivered strictly in order.
  final bool serializeEntityOperations;

  /// Durably records [mutation] for [accountId] and returns the new operation.
  ///
  /// Every dependency must already exist and belong to the same account, so
  /// the dependency graph is acyclic by construction. Throws an
  /// [InvalidDependencyException] otherwise.
  ///
  /// The lookup of the entity's previous operation and the insertion run in
  /// one storage transaction, so concurrent mutations of one entity always
  /// form a chain.
  ///
  /// **Transactional outbox:** call this inside your database transaction (for
  /// Drift, `database.transaction`) when the storage shares that database. The
  /// local write and the operation are then committed together or not at all.
  /// With a separate storage, a crash between the two writes can lose or
  /// orphan one of them.
  Future<SyncOperation> enqueue(
    SyncMutation mutation, {
    required String accountId,
  }) =>
      _storage.runInTransaction(() => _enqueue(mutation, accountId));

  Future<SyncOperation> _enqueue(
      SyncMutation mutation, String accountId) async {
    final dependencies = [...mutation.dependencies];
    if (serializeEntityOperations) {
      final previous = await _storage.findLatestActiveOperation(
        accountId: accountId,
        entityName: mutation.entity,
        entityId: mutation.id,
      );
      if (previous != null && !dependencies.contains(previous.id)) {
        dependencies.add(previous.id);
      }
    }

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
      dependencies: dependencies,
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
