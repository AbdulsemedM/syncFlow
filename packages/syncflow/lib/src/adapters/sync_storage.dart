import '../conflict/conflict.dart';
import '../models/exceptions.dart';
import '../models/sync_checkpoint.dart';
import '../models/sync_id_mapping.dart';
import '../queue/operation.dart';
import '../queue/operation_status.dart';

/// Durable storage for SyncFlow's synchronization metadata.
///
/// This is the persistence contract every adapter (in-memory, Drift, ...) must
/// satisfy. The `syncflow_test` package ships a contract test suite that every
/// implementation should run.
///
/// ## Contract
///
/// * **Durability.** Once a write's future completes, the change survives
///   process termination, subject to the guarantees of the backing store.
/// * **Isolation of copies.** Returned operations are snapshots. Mutating the
///   application's own objects never changes stored state.
/// * **Optimistic concurrency.** Every successful write increments the
///   operation's revision. [updateOperation] fails with a
///   [StaleOperationException] if the stored revision differs from the
///   revision of the operation passed in.
/// * **Atomic leases.** [acquireLease] is a single atomic compare-and-set: at
///   most one worker can hold an operation at a time.
/// * **Deterministic ordering.** [getEligibleOperations] returns operations
///   ordered by creation time, with ties broken by insertion order.
/// * **Account isolation.** Queries never return another account's operations.
///
/// Implementations must not depend on SQL-specific behavior leaking into the
/// core and must translate backend errors into [SyncFlowException]s.
abstract interface class SyncStorage {
  /// Prepares the storage (opens connections, runs migrations).
  ///
  /// Must be called once before any other method.
  Future<void> initialize();

  /// Runs [action] as one atomic unit and returns its result.
  ///
  /// Every storage call made while [action] runs (in its zone) belongs to the
  /// transaction. The changes are committed together when [action] completes
  /// and rolled back if it throws; the error is then rethrown. Nested calls
  /// behave like savepoints: a failing nested call rolls back only its own
  /// changes. Calls from outside the transaction are not interleaved with it.
  ///
  /// Adapters that share a database with the application (such as Drift) also
  /// include the application's own writes made inside [action]. That is what
  /// makes the transactional outbox possible: a local business write and its
  /// operation are committed together or not at all.
  Future<T> runInTransaction<T>(Future<T> Function() action);

  /// Persists a new [operation].
  ///
  /// Throws a [DuplicateOperationException] if an operation with the same ID
  /// already exists.
  Future<void> insertOperation(SyncOperation operation);

  /// Persists all [operations] atomically: either every operation is stored or
  /// none is.
  ///
  /// Throws a [DuplicateOperationException] if any ID already exists or
  /// appears twice in [operations].
  Future<void> insertOperations(List<SyncOperation> operations);

  /// Returns the operation with [operationId], or `null` if it does not exist.
  Future<SyncOperation?> getOperation(String operationId);

  /// Returns up to [limit] operations of [accountId] that are claimable at
  /// [now]: status [SyncOperationStatus.pending] or
  /// [SyncOperationStatus.retryScheduled] with no `nextAttemptAt` or one at or
  /// before [now].
  ///
  /// Results are ordered by `createdAt`, then insertion order. Dependencies are
  /// not evaluated here; that is the engine's responsibility.
  Future<List<SyncOperation>> getEligibleOperations({
    required String accountId,
    required DateTime now,
    required int limit,
  });

  /// Returns the most recently created non-terminal operation (any status
  /// except [SyncOperationStatus.acknowledged] and
  /// [SyncOperationStatus.cancelled]) for the given entity, or `null`.
  ///
  /// "Most recent" uses the same ordering as [getEligibleOperations]. Used to
  /// order successive mutations of one entity.
  Future<SyncOperation?> findLatestActiveOperation({
    required String accountId,
    required String entityName,
    required String entityId,
  });

  /// Returns the number of operations of [accountId] per status. Statuses
  /// without operations are omitted.
  Future<Map<SyncOperationStatus, int>> countOperations({
    required String accountId,
  });

  /// Returns operations of [accountId] for inspection, newest first: ordered
  /// by `createdAt` descending, ties broken by reverse insertion order.
  ///
  /// When [statuses] is given, only operations in one of those states are
  /// returned. Skips [offset] matches and returns at most [limit]. Throws an
  /// [ArgumentError] if [limit] is not positive or [offset] is negative.
  Future<List<SyncOperation>> listOperations({
    required String accountId,
    required int limit,
    int offset = 0,
    Set<SyncOperationStatus>? statuses,
  });

  /// Returns every operation that lists [operationId] among its dependencies,
  /// in the same order as [getEligibleOperations].
  Future<List<SyncOperation>> findDependentOperations(String operationId);

  /// Stores [mapping], replacing any mapping for the same account, entity and
  /// local ID.
  Future<void> saveIdMapping(SyncIdMapping mapping);

  /// Returns the server ID recorded for [localId], or `null` if none.
  Future<String?> resolveServerId({
    required String accountId,
    required String entityName,
    required String localId,
  });

  /// Stores [conflict], replacing any conflict for the same operation.
  Future<void> saveConflict(SyncConflict conflict);

  /// Returns the unresolved conflict of [operationId], or `null`.
  Future<SyncConflict?> getConflict(String operationId);

  /// Returns the unresolved conflicts of [accountId], oldest first.
  Future<List<SyncConflict>> listConflicts({required String accountId});

  /// Removes the conflict of [operationId]. Does nothing if it is absent.
  Future<void> deleteConflict(String operationId);

  /// Replaces the stored operation with [operation] and returns the stored
  /// result, whose revision is `operation.revision + 1`.
  ///
  /// Throws an [OperationNotFoundException] if the operation does not exist,
  /// or a [StaleOperationException] if the stored revision is not
  /// `operation.revision`.
  Future<SyncOperation> updateOperation(SyncOperation operation);

  /// Removes the operation with [operationId]. Does nothing if it is absent.
  Future<void> deleteOperation(String operationId);

  /// Atomically claims a due, claimable operation for [workerId].
  ///
  /// On success, the operation moves to [SyncOperationStatus.leased] with the
  /// given lease, and the stored result is returned. Returns `null` if the
  /// operation does not exist, is not claimable, or is not yet due at [now].
  Future<SyncOperation?> acquireLease({
    required String operationId,
    required String workerId,
    required DateTime now,
    required DateTime expiresAt,
  });

  /// Returns a [SyncOperationStatus.leased] operation held by [workerId] to
  /// [SyncOperationStatus.pending] without attempting delivery.
  ///
  /// Returns `false` and changes nothing if the operation is not leased by
  /// [workerId] (including after it moved to [SyncOperationStatus.sending]).
  Future<bool> releaseLease({
    required String operationId,
    required String workerId,
    required DateTime now,
  });

  /// Returns every in-flight operation whose lease expired at or before [now]
  /// to [SyncOperationStatus.pending], clearing the lease while preserving
  /// its ID, idempotency key and attempt count.
  ///
  /// Returns the number of recovered operations.
  Future<int> recoverExpiredLeases(DateTime now);

  /// Stores [checkpoint], replacing any checkpoint for the same account and
  /// entity.
  Future<void> saveCheckpoint(SyncCheckpoint checkpoint);

  /// Returns the checkpoint for [accountId] and [entityName], if any.
  Future<SyncCheckpoint?> getCheckpoint({
    required String accountId,
    required String entityName,
  });

  /// Releases resources. The storage must not be used afterwards.
  Future<void> close();
}
