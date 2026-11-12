import 'package:flutter/material.dart';
import 'package:syncflow/syncflow.dart';

import '../inspector_event.dart';

/// Formats [time] in local time as `yyyy-MM-dd HH:mm:ss`.
String formatTime(DateTime? time) {
  if (time == null) return '—';
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

/// Human-readable status label.
String statusLabel(SyncOperationStatus status) => switch (status) {
      SyncOperationStatus.pending => 'Pending',
      SyncOperationStatus.leased => 'Leased',
      SyncOperationStatus.sending => 'Sending',
      SyncOperationStatus.retryScheduled => 'Retry scheduled',
      SyncOperationStatus.conflict => 'Conflict',
      SyncOperationStatus.rejected => 'Rejected',
      SyncOperationStatus.acknowledged => 'Acknowledged',
      SyncOperationStatus.cancelled => 'Cancelled',
    };

/// Color associated with [status].
Color statusColor(SyncOperationStatus status, ColorScheme colors) =>
    switch (status) {
      SyncOperationStatus.pending ||
      SyncOperationStatus.leased ||
      SyncOperationStatus.sending =>
        colors.primary,
      SyncOperationStatus.retryScheduled => Colors.orange.shade700,
      SyncOperationStatus.conflict ||
      SyncOperationStatus.rejected =>
        colors.error,
      SyncOperationStatus.acknowledged => Colors.green.shade700,
      SyncOperationStatus.cancelled => colors.outline,
    };

/// Icon for a timeline entry.
IconData eventIcon(InspectorEventKind kind) => switch (kind) {
      InspectorEventKind.runStarted => Icons.play_arrow,
      InspectorEventKind.runCompleted => Icons.flag_outlined,
      InspectorEventKind.leasesRecovered => Icons.restore,
      InspectorEventKind.acknowledged => Icons.check_circle_outline,
      InspectorEventKind.idAssigned => Icons.badge_outlined,
      InspectorEventKind.retryScheduled => Icons.schedule,
      InspectorEventKind.rejected => Icons.block,
      InspectorEventKind.conflicted ||
      InspectorEventKind.conflictDetected =>
        Icons.call_split,
      InspectorEventKind.conflictResolved => Icons.merge_type,
      InspectorEventKind.leaseLost => Icons.link_off,
      InspectorEventKind.authenticationRequired => Icons.lock_outline,
      InspectorEventKind.remoteChangesApplied => Icons.cloud_download_outlined,
      InspectorEventKind.fullResyncStarted => Icons.sync_problem,
      InspectorEventKind.pullFailed => Icons.cloud_off,
      InspectorEventKind.developerAction => Icons.build_outlined,
    };

/// A small colored label showing an operation status.
class StatusChip extends StatelessWidget {
  /// Creates the chip.
  const StatusChip(this.status, {super.key});

  /// Displayed status.
  final SyncOperationStatus status;

  @override
  Widget build(BuildContext context) {
    final color = statusColor(status, Theme.of(context).colorScheme);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        statusLabel(status),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

/// Shows [error] in a snack bar, using the exception's own message.
void showActionError(BuildContext context, Object error) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(content: Text('Action failed: $error')),
  );
}
