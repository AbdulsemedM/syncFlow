import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:syncflow/syncflow.dart';

import '../inspector_models.dart';
import '../sync_inspector.dart';
import 'formatting.dart';
import 'reloading.dart';

/// Details of one operation, with the developer actions its state allows.
class OperationDetailPage extends StatefulWidget {
  /// Creates the page.
  const OperationDetailPage({
    required this.inspector,
    required this.operationId,
    super.key,
  });

  /// Data source and actions.
  final SyncInspector inspector;

  /// The displayed operation.
  final String operationId;

  @override
  State<OperationDetailPage> createState() => _OperationDetailPageState();
}

class _OperationDetailPageState extends State<OperationDetailPage>
    with InspectorReloading<OperationDetailPage> {
  OperationDetails? _details;
  bool _loaded = false;
  bool _busy = false;

  @override
  SyncInspector get inspector => widget.inspector;

  @override
  Future<void> load() async {
    final details = await inspector.loadOperation(widget.operationId);
    if (mounted) {
      setState(() {
        _details = details;
        _loaded = true;
      });
    }
  }

  Future<void> _act(Future<Object?> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on Object catch (error) {
      if (mounted) showActionError(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
      await reload();
    }
  }

  Future<void> _confirmCancel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel operation?'),
        content: const Text(
          'The change will never be sent to the server. This cannot be '
          'undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Cancel operation'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await _act(() => inspector.cancel(widget.operationId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final details = _details;
    return Scaffold(
      appBar: AppBar(title: const Text('Operation')),
      body: switch ((loadError, _loaded, details)) {
        (final Object error, _, _) => Center(child: Text('$error')),
        (_, false, _) => const Center(child: CircularProgressIndicator()),
        (_, true, null) => const Center(
            child: Text('This operation no longer exists for this account.'),
          ),
        (_, true, final OperationDetails details) => _buildDetails(details),
      },
    );
  }

  Widget _buildDetails(OperationDetails details) {
    final operation = details.operation;
    final error = operation.lastError;
    final conflict = details.conflict;
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${operation.operationType.name} '
                '${operation.entityName}/${operation.entityId}',
                style: theme.textTheme.titleLarge,
              ),
            ),
            StatusChip(operation.status),
          ],
        ),
        const SizedBox(height: 12),
        _Actions(
          details: details,
          busy: _busy,
          onRetry: () => _act(() => inspector.retry(operation.id)),
          onCancel: _confirmCancel,
          onUseLocal: () => _act(
            () => inspector.resolveConflict(operation.id, const UseLocal()),
          ),
          onUseRemote: () => _act(
            () => inspector.resolveConflict(operation.id, const UseRemote()),
          ),
        ),
        _Section(
          title: 'Operation',
          children: [
            _Field('ID', operation.id),
            _Field('Idempotency key', details.idempotencyKey),
            _Field('Created', formatTime(operation.createdAt)),
            _Field('Updated', formatTime(operation.updatedAt)),
            _Field('Attempts', '${operation.attempts}'),
            _Field('Last attempt', formatTime(operation.lastAttemptAt)),
            _Field('Next attempt', formatTime(operation.nextAttemptAt)),
            if (operation.baseVersion != null)
              _Field('Base version', operation.baseVersion!),
            if (details.serverId != null)
              _Field('Server ID', details.serverId!),
            if (operation.leaseOwner != null)
              _Field(
                'Lease',
                '${operation.leaseOwner} until '
                    '${formatTime(operation.leaseExpiresAt)}',
              ),
          ],
        ),
        if (error != null)
          _Section(
            title: 'Last error',
            children: [
              _Field('Category', error.category.name),
              _Field('Retryable', error.isRetryable ? 'yes' : 'no'),
              if (error.httpStatus != null)
                _Field('HTTP status', '${error.httpStatus}'),
              if (error.serverRequestId != null)
                _Field('Server request', error.serverRequestId!),
              _Field('Occurred', formatTime(error.occurredAt)),
              _Field('Message', error.message),
            ],
          ),
        if (details.dependencies.isNotEmpty || details.dependents.isNotEmpty)
          _Section(
            title: 'Dependencies',
            children: [
              for (final dependency in details.dependencies)
                _Field(
                  'Waits for ${dependency.id}',
                  dependency.status == null
                      ? 'gone (satisfied)'
                      : '${statusLabel(dependency.status!)}'
                          '${dependency.isSatisfied ? ' (satisfied)' : ''}',
                ),
              for (final dependent in details.dependents)
                _Field(
                  'Needed by ${dependent.id}',
                  statusLabel(dependent.status),
                ),
            ],
          ),
        if (conflict != null)
          _Section(
            title: 'Conflict',
            children: [
              _Field('Detected', formatTime(conflict.detectedAt)),
              _Field('Remote version', conflict.remoteVersion ?? 'unknown'),
              const SizedBox(height: 8),
              Text('Server state', style: theme.textTheme.labelLarge),
              _Json(details.remoteData),
            ],
          ),
        _Section(
          title: 'Payload',
          children: [_Json(details.payload)],
        ),
        _Section(
          title: 'History',
          children: [
            if (details.history.isEmpty)
              const Text('No events observed for this operation yet.'),
            for (final event in details.history)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(eventIcon(event.kind)),
                title: Text(event.summary),
                subtitle: Text(
                  [
                    formatTime(event.at),
                    if (event.httpStatus != null) 'HTTP ${event.httpStatus}',
                  ].join(' · '),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.details,
    required this.busy,
    required this.onRetry,
    required this.onCancel,
    required this.onUseLocal,
    required this.onUseRemote,
  });

  final OperationDetails details;
  final bool busy;
  final VoidCallback onRetry;
  final VoidCallback onCancel;
  final VoidCallback onUseLocal;
  final VoidCallback onUseRemote;

  @override
  Widget build(BuildContext context) {
    final buttons = [
      if (details.canRetry)
        FilledButton(
          onPressed: busy ? null : onRetry,
          child: const Text('Retry'),
        ),
      if (details.canResolveConflict) ...[
        FilledButton(
          onPressed: busy ? null : onUseLocal,
          child: const Text('Keep local'),
        ),
        OutlinedButton(
          onPressed: busy ? null : onUseRemote,
          child: const Text('Use remote'),
        ),
      ],
      if (details.canCancel)
        OutlinedButton(
          onPressed: busy ? null : onCancel,
          child: const Text('Cancel'),
        ),
    ];
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 8, runSpacing: 8, children: buttons);
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const Divider(),
            ...children,
          ],
        ),
      );
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 128,
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Expanded(child: SelectableText(value)),
          ],
        ),
      );
}

class _Json extends StatelessWidget {
  const _Json(this.value);

  final Object? value;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(8),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: SelectableText(
          value == null
              ? 'unknown'
              : const JsonEncoder.withIndent('  ').convert(value),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      );
}
