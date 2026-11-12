/// Lifecycle state of a `SyncOperation`.
///
/// Allowed transitions (anything else is rejected):
///
/// ```text
/// pending ─────────► leased, cancelled,
///                    rejected (a prerequisite was rejected)
/// leased ──────────► sending, pending (lease released or expired)
/// sending ─────────► acknowledged, retryScheduled, conflict, rejected,
///                    pending (crash recovery of an expired lease)
/// retryScheduled ──► pending, leased (claiming a due retry), cancelled,
///                    rejected (a prerequisite was rejected)
/// conflict ────────► pending (after resolution), cancelled
/// rejected ────────► pending (after correction), cancelled
/// acknowledged ────► (terminal)
/// cancelled ───────► (terminal)
/// ```
enum SyncOperationStatus {
  /// Waiting to be claimed by a worker.
  pending,

  /// Claimed by a worker holding a time-limited lease; not yet transmitted.
  leased,

  /// Being transmitted. The server may already have processed it.
  sending,

  /// A retryable failure occurred; claimable again at `nextAttemptAt`.
  retryScheduled,

  /// The server reported a concurrency conflict that needs resolution.
  conflict,

  /// The server permanently rejected the operation.
  rejected,

  /// The server acknowledged the operation. Terminal.
  acknowledged,

  /// The operation was explicitly discarded. Terminal.
  cancelled;

  /// Whether no further transitions are possible.
  bool get isTerminal => allowedTransitions.isEmpty;

  /// Whether a worker may claim an operation in this state (subject to
  /// `nextAttemptAt`).
  bool get isClaimable => this == pending || this == retryScheduled;

  /// Whether the operation is held by a worker. In-flight operations always
  /// carry a lease owner and expiry.
  bool get isInFlight => this == leased || this == sending;

  /// Whether the operation is blocked until the application intervenes.
  bool get needsAttention => this == conflict || this == rejected;

  /// States reachable from this state in one step.
  Set<SyncOperationStatus> get allowedTransitions => _allowedTransitions[this]!;

  /// Whether moving from this state to [next] is permitted.
  bool canTransitionTo(SyncOperationStatus next) =>
      allowedTransitions.contains(next);
}

const Map<SyncOperationStatus, Set<SyncOperationStatus>> _allowedTransitions = {
  SyncOperationStatus.pending: {
    SyncOperationStatus.leased,
    SyncOperationStatus.cancelled,
    SyncOperationStatus.rejected,
  },
  SyncOperationStatus.leased: {
    SyncOperationStatus.sending,
    SyncOperationStatus.pending,
  },
  SyncOperationStatus.sending: {
    SyncOperationStatus.acknowledged,
    SyncOperationStatus.retryScheduled,
    SyncOperationStatus.conflict,
    SyncOperationStatus.rejected,
    SyncOperationStatus.pending,
  },
  SyncOperationStatus.retryScheduled: {
    SyncOperationStatus.pending,
    SyncOperationStatus.leased,
    SyncOperationStatus.cancelled,
    SyncOperationStatus.rejected,
  },
  SyncOperationStatus.conflict: {
    SyncOperationStatus.pending,
    SyncOperationStatus.cancelled,
  },
  SyncOperationStatus.rejected: {
    SyncOperationStatus.pending,
    SyncOperationStatus.cancelled,
  },
  SyncOperationStatus.acknowledged: {},
  SyncOperationStatus.cancelled: {},
};
