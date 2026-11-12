import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:syncflow/syncflow.dart';

import '../inspector_models.dart';
import '../sync_inspector.dart';
import 'formatting.dart';
import 'operation_detail_page.dart';
import 'reloading.dart';

/// Opens the inspector page for [inspector].
///
/// Does nothing when the inspector is disabled (by default in release
/// builds), so a debug button can stay in place safely.
Future<void> showSyncInspector(
  BuildContext context,
  SyncInspector inspector, {
  ValueChanged<String>? onExport,
}) async {
  if (!inspector.isEnabled) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SyncInspectorPage(
        inspector: inspector,
        onExport: onExport,
      ),
    ),
  );
}

/// The inspector's main page: overview, operations and event timeline.
class SyncInspectorPage extends StatelessWidget {
  /// Creates the page.
  const SyncInspectorPage({
    required this.inspector,
    this.onExport,
    super.key,
  });

  /// Data source and actions.
  final SyncInspector inspector;

  /// Receives the exported diagnostic report. By default the report is shown
  /// in a dialog with a copy button.
  final ValueChanged<String>? onExport;

  @override
  Widget build(BuildContext context) {
    if (!inspector.isEnabled) {
      return Scaffold(
        appBar: AppBar(title: const Text('Sync inspector')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'The sync inspector is disabled in this build.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Sync inspector'),
          actions: [
            ListenableBuilder(
              listenable: inspector,
              builder: (context, _) => inspector.engine.isPaused
                  ? IconButton(
                      tooltip: 'Resume synchronization',
                      icon: const Icon(Icons.play_arrow),
                      onPressed: inspector.resume,
                    )
                  : IconButton(
                      tooltip: 'Pause synchronization',
                      icon: const Icon(Icons.pause),
                      onPressed: inspector.pause,
                    ),
            ),
            IconButton(
              tooltip: 'Sync now',
              icon: const Icon(Icons.sync),
              onPressed: () => _syncNow(context),
            ),
            IconButton(
              tooltip: 'Export diagnostics',
              icon: const Icon(Icons.ios_share),
              onPressed: () => _export(context),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Overview'),
              Tab(text: 'Operations'),
              Tab(text: 'Timeline'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _OverviewTab(inspector: inspector),
            _OperationsTab(inspector: inspector),
            _TimelineTab(inspector: inspector),
          ],
        ),
      ),
    );
  }

  Future<void> _syncNow(BuildContext context) async {
    try {
      await inspector.syncNow();
    } on Object catch (error) {
      if (context.mounted) showActionError(context, error);
    }
  }

  Future<void> _export(BuildContext context) async {
    final String report;
    try {
      report = await inspector.exportReport();
    } on Object catch (error) {
      if (context.mounted) showActionError(context, error);
      return;
    }
    if (onExport case final onExport?) {
      onExport(report);
      return;
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Diagnostic report'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Payloads are redacted, but the report may still contain '
                'personal data. Share it only through approved channels.',
              ),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: SelectableText(
                    report,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: report)),
            child: const Text('Copy'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

void _openOperation(
  BuildContext context,
  SyncInspector inspector,
  String operationId,
) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => OperationDetailPage(
        inspector: inspector,
        operationId: operationId,
      ),
    ),
  );
}

Widget _errorView(Object error) => Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text('Could not load: $error', textAlign: TextAlign.center),
      ),
    );

// --- overview ----------------------------------------------------------------

class _OverviewTab extends StatefulWidget {
  const _OverviewTab({required this.inspector});

  final SyncInspector inspector;

  @override
  State<_OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends State<_OverviewTab>
    with InspectorReloading<_OverviewTab> {
  InspectorSnapshot? _snapshot;

  @override
  SyncInspector get inspector => widget.inspector;

  @override
  Future<void> load() async {
    final snapshot = await inspector.loadSnapshot();
    if (mounted) setState(() => _snapshot = snapshot);
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    if (loadError case final error?) return _errorView(error);
    if (snapshot == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final theme = Theme.of(context);
    final lastRun = snapshot.lastRunResult;
    return RefreshIndicator(
      onRefresh: reload,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            snapshot.accountId == null
                ? 'No active account'
                : 'Account: ${snapshot.accountId}',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Chip(label: Text(snapshot.isSyncing ? 'Syncing' : 'Idle')),
              if (snapshot.isPaused) const Chip(label: Text('Paused')),
              if (snapshot.authenticationRequired)
                Chip(
                  label: const Text('Authentication required'),
                  side: BorderSide(color: theme.colorScheme.error),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _StatTile(label: 'Pending', value: snapshot.pending),
              _StatTile(label: 'Completed', value: snapshot.completed),
              _StatTile(
                label: 'Rejected',
                value: snapshot.rejected,
                highlight: snapshot.rejected > 0,
              ),
              _StatTile(
                label: 'Conflicts',
                value: snapshot.inConflict,
                highlight: snapshot.inConflict > 0,
              ),
              _StatTile(label: 'Cancelled', value: snapshot.cancelled),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'Last successful sync: '
            '${formatTime(snapshot.lastSuccessfulSyncAt)}',
          ),
          if (lastRun != null)
            Text(
              'Last run: ${lastRun.stopReason.name}, '
              '${lastRun.acknowledged} acknowledged, '
              '${lastRun.retryScheduled} retrying, ${lastRun.failed} failed',
            ),
          if (inspector.startedAt case final startedAt?)
            Text(
              'Observing since ${formatTime(startedAt)}',
              style: theme.textTheme.bodySmall,
            ),
          if (snapshot.conflicts.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('Unresolved conflicts', style: theme.textTheme.titleMedium),
            for (final conflict in snapshot.conflicts)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.call_split),
                title: Text('${conflict.entityName}/${conflict.entityId}'),
                subtitle: Text('Detected ${formatTime(conflict.detectedAt)}'),
                onTap: () =>
                    _openOperation(context, inspector, conflict.operationId),
              ),
          ],
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  final String label;
  final int value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = highlight ? theme.colorScheme.error : null;
    return SizedBox(
      width: 104,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$value',
                style: theme.textTheme.headlineSmall?.copyWith(color: color),
              ),
              Text(label, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

// --- operations --------------------------------------------------------------

enum _Filter {
  all('All', null),
  pending('Pending', {
    SyncOperationStatus.pending,
    SyncOperationStatus.leased,
    SyncOperationStatus.sending,
    SyncOperationStatus.retryScheduled,
  }),
  failed('Failed', {
    SyncOperationStatus.rejected,
    SyncOperationStatus.conflict,
  }),
  completed('Completed', {SyncOperationStatus.acknowledged}),
  cancelled('Cancelled', {SyncOperationStatus.cancelled});

  const _Filter(this.label, this.statuses);

  final String label;
  final Set<SyncOperationStatus>? statuses;
}

class _OperationsTab extends StatefulWidget {
  const _OperationsTab({required this.inspector});

  final SyncInspector inspector;

  @override
  State<_OperationsTab> createState() => _OperationsTabState();
}

class _OperationsTabState extends State<_OperationsTab>
    with InspectorReloading<_OperationsTab> {
  static const _pageSize = 50;

  _Filter _filter = _Filter.all;
  int _limit = _pageSize;
  List<SyncOperation>? _operations;

  @override
  SyncInspector get inspector => widget.inspector;

  @override
  Future<void> load() async {
    final operations = await inspector.listOperations(
      statuses: _filter.statuses,
      limit: _limit,
    );
    if (mounted) setState(() => _operations = operations);
  }

  void _select(_Filter filter) {
    setState(() {
      _filter = filter;
      _limit = _pageSize;
      _operations = null;
    });
    reload();
  }

  @override
  Widget build(BuildContext context) {
    final operations = _operations;
    return Column(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              for (final filter in _Filter.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(filter.label),
                    selected: _filter == filter,
                    onSelected: (_) => _select(filter),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: switch ((loadError, operations)) {
            (final Object error, _) => _errorView(error),
            (_, null) => const Center(child: CircularProgressIndicator()),
            (_, final List<SyncOperation> list) when list.isEmpty =>
              const Center(child: Text('No operations')),
            (_, final List<SyncOperation> list) => ListView.builder(
                itemCount: list.length + (list.length >= _limit ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index == list.length) {
                    return TextButton(
                      onPressed: () {
                        setState(() => _limit += _pageSize);
                        reload();
                      },
                      child: const Text('Load more'),
                    );
                  }
                  return _OperationTile(
                    operation: list[index],
                    onTap: () =>
                        _openOperation(context, inspector, list[index].id),
                  );
                },
              ),
          },
        ),
      ],
    );
  }
}

class _OperationTile extends StatelessWidget {
  const _OperationTile({required this.operation, required this.onTap});

  final SyncOperation operation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final error = operation.lastError;
    return ListTile(
      title: Text(
        '${operation.operationType.name} '
        '${operation.entityName}/${operation.entityId}',
      ),
      subtitle: Text(
        [
          formatTime(operation.createdAt),
          if (operation.attempts > 0)
            '${operation.attempts} attempt${operation.attempts == 1 ? '' : 's'}',
          if (error != null)
            '${error.category.name}'
                '${error.httpStatus == null ? '' : ' ${error.httpStatus}'}',
        ].join(' · '),
      ),
      trailing: StatusChip(operation.status),
      onTap: onTap,
    );
  }
}

// --- timeline ----------------------------------------------------------------

class _TimelineTab extends StatelessWidget {
  const _TimelineTab({required this.inspector});

  final SyncInspector inspector;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: inspector,
        builder: (context, _) {
          final events = inspector.timeline;
          if (events.isEmpty) {
            return const Center(child: Text('No events recorded yet'));
          }
          return ListView.builder(
            itemCount: events.length,
            itemBuilder: (context, index) {
              final event = events[index];
              final operationId = event.operationId;
              return ListTile(
                dense: true,
                leading: Icon(eventIcon(event.kind)),
                title: Text(event.summary),
                subtitle: Text(
                  [
                    formatTime(event.at),
                    if (event.httpStatus != null) 'HTTP ${event.httpStatus}',
                    if (event.serverRequestId != null)
                      'request ${event.serverRequestId}',
                  ].join(' · '),
                ),
                onTap: operationId == null
                    ? null
                    : () => _openOperation(context, inspector, operationId),
              );
            },
          );
        },
      );
}
