import '../models/exceptions.dart';
import '../models/sync_checkpoint.dart';
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
