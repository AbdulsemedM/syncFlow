/// Why a synchronization run ended.
enum SyncRunStopReason {
  /// Every eligible operation was processed.
  completed,

  /// No account is active, so nothing may be sent.
  noActiveAccount,

  /// The engine was paused by the application.
  paused,

  /// The server requires re-authentication for the active account.
  authenticationRequired,

  /// The active account changed during the run.
  accountChanged,

  /// The engine was closed.
  closed,
}

/// Summary of one synchronization run.
final class SyncRunResult {
  /// Creates a run summary.
  SyncRunResult({
    required this.accountId,
    required this.stopReason,
    required DateTime startedAt,
    required DateTime finishedAt,
    this.acknowledged = 0,
    this.retryScheduled = 0,
    this.rejected = 0,
    this.conflicts = 0,
    this.leaseLost = 0,
    this.blocked = 0,
    this.conflictsResolved = 0,
    this.pulledChanges = 0,
    this.pullFailures = 0,
  })  : startedAt = startedAt.toUtc(),
        finishedAt = finishedAt.toUtc();

  /// Account the run executed for, or `null` if none was active.
  final String? accountId;

  /// Why the run ended.
  final SyncRunStopReason stopReason;

  /// When the run started (UTC).
  final DateTime startedAt;

  /// When the run finished (UTC).
  final DateTime finishedAt;

  /// Operations acknowledged by the server.
  final int acknowledged;

  /// Operations that failed transiently and will be retried.
  final int retryScheduled;

  /// Operations permanently rejected (including exhausted retries).
  final int rejected;

  /// Operations that hit a version conflict.
  final int conflicts;

  /// Operations whose result could not be recorded because the lease was lost.
  /// They are delivered again later with the same idempotency key.
  final int leaseLost;

  /// Eligible operations held back by unfinished dependencies.
  final int blocked;

  /// Conflicts settled automatically by an entity's conflict resolver.
  final int conflictsResolved;

  /// Remote changes applied by pull synchronization.
  final int pulledChanges;

  /// Entities whose pull failed; their checkpoints are unchanged.
  final int pullFailures;

  /// Operations that needed application attention.
  int get failed => rejected + conflicts;

  /// Whether the run processed everything it could.
  bool get isComplete => stopReason == SyncRunStopReason.completed;

  @override
  String toString() => 'SyncRunResult(${stopReason.name}, '
      'acknowledged: $acknowledged, retryScheduled: $retryScheduled, '
      'rejected: $rejected, conflicts: $conflicts, leaseLost: $leaseLost, '
      'blocked: $blocked, conflictsResolved: $conflictsResolved, '
      'pulledChanges: $pulledChanges, pullFailures: $pullFailures)';
}
