import 'package:flutter/foundation.dart';
import 'package:syncflow/syncflow.dart';

/// Why a synchronization run was requested.
enum SyncTrigger {
  /// The controller was started.
  startup,

  /// The app returned to the foreground.
  resumed,

  /// The device regained network connectivity.
  connectivityRestored,

  /// The periodic foreground timer fired.
  periodic,

  /// A scheduled retry became due.
  retryDue,

  /// The application asked explicitly, for example pull-to-refresh.
  manual,
}

/// A snapshot of synchronization state for the UI.
@immutable
final class SyncStatus {
  /// Creates a status.
  const SyncStatus({
    this.isSyncing = false,
    this.isOnline,
    this.lastTrigger,
    this.lastResult,
    this.lastCompletedAt,
    this.lastError,
    this.operationCounts = const {},
  });

  /// Whether a run is in progress.
  final bool isSyncing;

  /// Last connectivity hint, or `null` without a connectivity source.
  final bool? isOnline;

  /// What started the most recent run.
  final SyncTrigger? lastTrigger;

  /// Result of the most recent run.
  final SyncRunResult? lastResult;

  /// When a run last completed without interruption.
  final DateTime? lastCompletedAt;

  /// The error thrown by the most recent run, if it failed unexpectedly (for
  /// example a storage failure). Cleared by the next successful run.
  final Object? lastError;

  /// Operations of the active account per status, as of the last refresh.
  final Map<SyncOperationStatus, int> operationCounts;

  /// Operations still to be delivered (pending, in flight or awaiting retry).
  int get pendingOperations =>
      _count(SyncOperationStatus.pending) +
      _count(SyncOperationStatus.leased) +
      _count(SyncOperationStatus.sending) +
      _count(SyncOperationStatus.retryScheduled);

  /// Operations that need attention (rejected or in conflict).
  int get failedOperations =>
      _count(SyncOperationStatus.rejected) +
      _count(SyncOperationStatus.conflict);

  /// Whether the last run stopped because credentials must be restored.
  bool get authenticationRequired =>
      lastResult?.stopReason == SyncRunStopReason.authenticationRequired;

  int _count(SyncOperationStatus status) => operationCounts[status] ?? 0;

  /// Returns a copy with the given fields replaced. [clearLastError] resets
  /// [lastError] to `null`.
  SyncStatus copyWith({
    bool? isSyncing,
    bool? isOnline,
    SyncTrigger? lastTrigger,
    SyncRunResult? lastResult,
    DateTime? lastCompletedAt,
    Object? lastError,
    bool clearLastError = false,
    Map<SyncOperationStatus, int>? operationCounts,
  }) =>
      SyncStatus(
        isSyncing: isSyncing ?? this.isSyncing,
        isOnline: isOnline ?? this.isOnline,
        lastTrigger: lastTrigger ?? this.lastTrigger,
        lastResult: lastResult ?? this.lastResult,
        lastCompletedAt: lastCompletedAt ?? this.lastCompletedAt,
        lastError: clearLastError ? null : (lastError ?? this.lastError),
        operationCounts: operationCounts ?? this.operationCounts,
      );

  @override
  String toString() => 'SyncStatus(syncing: $isSyncing, online: $isOnline, '
      'pending: $pendingOperations, failed: $failedOperations)';
}
