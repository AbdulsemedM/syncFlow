import 'package:syncflow/syncflow.dart';

import 'inspector_event.dart';

/// Dashboard figures for the active account at one point in time.
final class InspectorSnapshot {
  /// Creates a snapshot.
  const InspectorSnapshot({
    required this.takenAt,
    required this.accountId,
    required this.isSyncing,
    required this.isPaused,
    required this.authenticationRequired,
    required this.counts,
    required this.conflicts,
    this.lastRunResult,
    this.lastSuccessfulSyncAt,
  });

  /// When the snapshot was taken.
  final DateTime takenAt;

  /// The active account, or `null` when nobody is signed in.
  final String? accountId;

  /// Whether a run is in progress.
  final bool isSyncing;

  /// Whether the engine is paused.
  final bool isPaused;

  /// Whether delivery is paused until authentication is restored.
  final bool authenticationRequired;

  /// Operations per status.
  final Map<SyncOperationStatus, int> counts;

  /// Unresolved conflicts, oldest first.
  final List<SyncConflict> conflicts;

  /// The most recent run observed since the inspector started.
  final SyncRunResult? lastRunResult;

  /// When the most recent complete run finished, since the inspector started.
  final DateTime? lastSuccessfulSyncAt;

  int _count(SyncOperationStatus status) => counts[status] ?? 0;

  /// Operations still to be delivered (pending, leased, sending or waiting
  /// for a retry).
  int get pending =>
      _count(SyncOperationStatus.pending) +
      _count(SyncOperationStatus.leased) +
      _count(SyncOperationStatus.sending) +
      _count(SyncOperationStatus.retryScheduled);

  /// Acknowledged operations.
  int get completed => _count(SyncOperationStatus.acknowledged);

  /// Rejected operations.
  int get rejected => _count(SyncOperationStatus.rejected);

  /// Operations in conflict.
  int get inConflict => _count(SyncOperationStatus.conflict);

  /// Cancelled operations.
  int get cancelled => _count(SyncOperationStatus.cancelled);
}

/// A dependency of an operation and its current state.
final class DependencyInfo {
  /// Creates the record.
  const DependencyInfo({required this.id, required this.status});

  /// The dependency's operation ID.
  final String id;

  /// Its current status, or `null` if it no longer exists.
  final SyncOperationStatus? status;

  /// Whether the dependency no longer blocks the operation. Cancelled
  /// dependencies count as satisfied, like in the engine.
  bool get isSatisfied =>
      status == null ||
      status == SyncOperationStatus.acknowledged ||
      status == SyncOperationStatus.cancelled;
}

/// Everything the inspector knows about one operation.
///
/// [payload] and [remoteData] are already redacted; [idempotencyKey] is masked
/// unless the inspector exposes keys. [operation] is the raw stored operation:
/// do not display its payload directly.
final class OperationDetails {
  /// Creates the record.
  const OperationDetails({
    required this.operation,
    required this.payload,
    required this.idempotencyKey,
    required this.dependencies,
    required this.dependents,
    required this.history,
    this.conflict,
    this.remoteData,
    this.serverId,
  });

  /// The stored operation.
  final SyncOperation operation;

  /// The redacted payload.
  final Map<String, Object?> payload;

  /// The idempotency key as it may be displayed.
  final String idempotencyKey;

  /// The operation's dependencies, in declaration order.
  final List<DependencyInfo> dependencies;

  /// Operations that depend on this one.
  final List<SyncOperation> dependents;

  /// Timeline entries about this operation since the inspector started,
  /// newest first.
  final List<InspectorEvent> history;

  /// The unresolved conflict, when the operation is in conflict.
  final SyncConflict? conflict;

  /// The server's state from [conflict], redacted.
  final Map<String, Object?>? remoteData;

  /// The server-assigned ID of an acknowledged create, if one was recorded.
  final String? serverId;

  /// Whether a rejected operation can be re-queued.
  bool get canRetry => operation.status == SyncOperationStatus.rejected;

  /// Whether the operation can be cancelled in its current state.
  bool get canCancel =>
      operation.status.canTransitionTo(SyncOperationStatus.cancelled);

  /// Whether the operation has a conflict to resolve.
  bool get canResolveConflict =>
      operation.status == SyncOperationStatus.conflict;
}
