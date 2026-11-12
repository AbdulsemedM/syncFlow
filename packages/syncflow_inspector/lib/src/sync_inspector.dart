import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:syncflow/syncflow.dart';

import 'inspector_event.dart';
import 'inspector_models.dart';
import 'redactor.dart';

/// Developer diagnostics for a [SyncEngine].
///
/// The inspector reads the queue through [SyncStorage], records engine events
/// in a bounded timeline, and offers developer actions (retry, cancel,
/// conflict resolution, pause and resume). Actions go through the same
/// `OperationQueue` and engine APIs as application code, so they validate the
/// operation's current state and never bypass consistency rules.
///
/// Everything is scoped to the engine's active account.
///
/// ## Production
///
/// The inspector is disabled in release builds unless `enabled` is set
/// explicitly. A disabled inspector records nothing, `showSyncInspector` does
/// nothing, and every query or action throws a [StateError].
///
/// ## Sensitive data
///
/// Payloads and remote conflict states are passed through [redactor] before
/// they are displayed or exported. Idempotency keys are masked unless
/// [exposeIdempotencyKeys] is set. Redaction is best effort: treat exports as
/// sensitive artifacts.
class SyncInspector extends ChangeNotifier {
  /// Creates an inspector for [engine] over the engine's [storage].
  ///
  /// [queue] performs retries and cancellations; by default a queue over
  /// [storage] is created.
  SyncInspector({
    required this.engine,
    required this.storage,
    OperationQueue? queue,
    bool? enabled,
    this.redactor = const SyncRedactor(),
    this.exposeIdempotencyKeys = false,
    this.maxTimelineEvents = 200,
    Clock clock = const SystemClock(),
  })  : isEnabled = enabled ?? !kReleaseMode,
        _clock = clock,
        _queue = queue ?? OperationQueue(storage: storage, clock: clock) {
    if (maxTimelineEvents < 1) {
      throw ArgumentError.value(
        maxTimelineEvents,
        'maxTimelineEvents',
        'must be positive',
      );
    }
  }

  /// The inspected engine.
  final SyncEngine engine;

  /// The engine's storage.
  final SyncStorage storage;

  /// Whether the inspector is active. Defaults to `false` in release builds.
  final bool isEnabled;

  /// Redacts payloads and remote states before display or export.
  final SyncRedactor redactor;

  /// Whether idempotency keys are shown in full instead of masked.
  final bool exposeIdempotencyKeys;

  /// Number of timeline entries kept in memory; older entries are dropped.
  final int maxTimelineEvents;

  final Clock _clock;
  final OperationQueue _queue;
  final ListQueue<InspectorEvent> _timeline = ListQueue();
  StreamSubscription<SyncEvent>? _subscription;
  SyncRunResult? _lastRunResult;
  DateTime? _lastSuccessfulSyncAt;
  DateTime? _startedAt;
  bool _disposed = false;

  /// Timeline entries recorded since [start], newest first.
  List<InspectorEvent> get timeline =>
      List.unmodifiable(_timeline.toList().reversed);

  /// When [start] was called, or `null`.
  DateTime? get startedAt => _startedAt;

  /// Starts recording engine events. Does nothing when disabled or already
  /// started.
  ///
  /// The timeline only covers events from this point on: events are
  /// notifications and are not replayed. Start the inspector right after
  /// creating the engine to capture the whole session.
  void start() {
    _ensureNotDisposed();
    if (!isEnabled || _subscription != null) return;
    _startedAt = _clock.now();
    _subscription = engine.events.listen(_record);
  }

  // --- queries ---------------------------------------------------------------

  /// Loads the dashboard figures for the active account.
  Future<InspectorSnapshot> loadSnapshot() async {
    _ensureUsable();
    final accountId = engine.activeAccountId;
    return InspectorSnapshot(
      takenAt: _clock.now(),
      accountId: accountId,
      isSyncing: engine.isSyncing,
      isPaused: engine.isPaused,
      authenticationRequired:
          accountId != null && engine.isAuthenticationRequired(accountId),
      counts: accountId == null
          ? const {}
          : await storage.countOperations(accountId: accountId),
      conflicts: accountId == null
          ? const []
          : await storage.listConflicts(accountId: accountId),
      lastRunResult: _lastRunResult,
      lastSuccessfulSyncAt: _lastSuccessfulSyncAt,
    );
  }

  /// Lists operations of the active account, newest first.
  Future<List<SyncOperation>> listOperations({
    Set<SyncOperationStatus>? statuses,
    int limit = 50,
    int offset = 0,
  }) async {
    _ensureUsable();
    final accountId = engine.activeAccountId;
    if (accountId == null) return const [];
    return storage.listOperations(
      accountId: accountId,
      statuses: statuses,
      limit: limit,
      offset: offset,
    );
  }

  /// Loads everything known about [operationId], or `null` if it does not
  /// exist or belongs to another account.
  Future<OperationDetails?> loadOperation(String operationId) async {
    _ensureUsable();
    final operation = await _getScoped(operationId);
    if (operation == null) return null;

    final dependencies = <DependencyInfo>[
      for (final id in operation.dependencies)
        DependencyInfo(
            id: id, status: (await storage.getOperation(id))?.status),
    ];
    final conflict = operation.status == SyncOperationStatus.conflict
        ? await storage.getConflict(operation.id)
        : null;
    final serverId = operation.operationType == SyncOperationType.create &&
            operation.status == SyncOperationStatus.acknowledged
        ? await storage.resolveServerId(
            accountId: operation.accountId,
            entityName: operation.entityName,
            localId: operation.entityId,
          )
        : null;

    return OperationDetails(
      operation: operation,
      payload: redactor.redactMap(operation.payload),
      idempotencyKey: displayIdempotencyKey(operation.idempotencyKey),
      dependencies: dependencies,
      dependents: [
        for (final dependent
            in await storage.findDependentOperations(operation.id))
          if (dependent.accountId == operation.accountId) dependent,
      ],
      conflict: conflict,
      remoteData: switch (conflict?.remoteData) {
        final Map<String, Object?> data => redactor.redactMap(data),
        null => null,
      },
      serverId: serverId,
      history: [
        for (final event in timeline)
          if (event.operationId == operation.id) event,
      ],
    );
  }

  /// The idempotency key as it may be displayed.
  String displayIdempotencyKey(String key) =>
      exposeIdempotencyKeys ? key : SyncRedactor.maskIdentifier(key);

  // --- actions ---------------------------------------------------------------

  /// Re-queues a rejected operation (and the operations rejected because of
  /// it). See `OperationQueue.retry`.
  Future<List<SyncOperation>> retry(String operationId) async {
    await _requireScoped(operationId);
    final requeued = await _queue.retry(operationId);
    _recordAction('Retried', operationId, extra: requeued.length - 1);
    return requeued;
  }

  /// Cancels an operation that is not in flight or terminal. See
  /// `OperationQueue.cancel`.
  Future<SyncOperation> cancel(String operationId) async {
    await _requireScoped(operationId);
    final cancelled = await _queue.cancel(operationId);
    _recordAction('Cancelled', operationId);
    return cancelled;
  }

  /// Settles a conflict. See `SyncEngine.resolveConflict`.
  Future<SyncOperation> resolveConflict(
    String operationId,
    ConflictResolution resolution,
  ) async {
    await _requireScoped(operationId);
    final resolved = await engine.resolveConflict(operationId, resolution);
    _recordAction('Resolved conflict of', operationId);
    return resolved;
  }

  /// Pauses the engine. In-flight deliveries finish normally.
  void pause() {
    _ensureUsable();
    engine.pause();
    _recordAction('Paused synchronization', null);
  }

  /// Resumes the engine. Does not start a run by itself.
  void resume() {
    _ensureUsable();
    engine.resume();
    _recordAction('Resumed synchronization', null);
  }

  /// Runs a synchronization now.
  Future<SyncRunResult> syncNow() {
    _ensureUsable();
    return engine.syncNow();
  }

  // --- export ----------------------------------------------------------------

  /// Builds a diagnostic report as indented JSON.
  ///
  /// Contains the dashboard figures, up to [maxOperations] of the newest
  /// operations (with redacted payloads, or none without [includePayloads]),
  /// unresolved conflicts and the timeline. The account ID is replaced by a
  /// placeholder unless [includeAccountId] is set.
  ///
  /// The report is a sensitive artifact even after redaction: share it only
  /// through channels approved for user data.
  Future<String> exportReport({
    int maxOperations = 500,
    bool includePayloads = true,
    bool includeAccountId = false,
  }) async {
    _ensureUsable();
    final snapshot = await loadSnapshot();
    final operations = await listOperations(limit: maxOperations);
    final report = <String, Object?>{
      'format': 'syncflow-diagnostics',
      'formatVersion': 1,
      'notice': 'Sensitive diagnostic data. Payloads are redacted on a best '
          'effort basis; share only through channels approved for user data.',
      'generatedAt': snapshot.takenAt.toIso8601String(),
      'inspectorStartedAt': _startedAt?.toIso8601String(),
      'account': snapshot.accountId == null
          ? null
          : includeAccountId
              ? snapshot.accountId
              : redactor.replacement,
      'engine': {
        'isSyncing': snapshot.isSyncing,
        'isPaused': snapshot.isPaused,
        'authenticationRequired': snapshot.authenticationRequired,
        'lastSuccessfulSyncAt':
            snapshot.lastSuccessfulSyncAt?.toIso8601String(),
        'lastRun': _runJson(snapshot.lastRunResult),
      },
      'counts': {
        for (final MapEntry(:key, :value) in snapshot.counts.entries)
          key.name: value,
      },
      'operations': [
        for (final operation in operations)
          _operationJson(operation, includePayloads: includePayloads),
      ],
      'operationsTruncated': operations.length >= maxOperations,
      'conflicts': [
        for (final conflict in snapshot.conflicts)
          {
            'operationId': conflict.operationId,
            'entityName': conflict.entityName,
            'entityId': conflict.entityId,
            'remoteVersion': conflict.remoteVersion,
            'detectedAt': conflict.detectedAt.toIso8601String(),
            if (includePayloads)
              'remoteData': switch (conflict.remoteData) {
                final Map<String, Object?> data => redactor.redactMap(data),
                null => null,
              },
          },
      ],
      'timeline': [for (final event in timeline) event.toJson()],
    };
    return const JsonEncoder.withIndent('  ').convert(report);
  }

  Map<String, Object?> _operationJson(
    SyncOperation operation, {
    required bool includePayloads,
  }) =>
      {
        'id': operation.id,
        'entityName': operation.entityName,
        'entityId': operation.entityId,
        'operationType': operation.operationType.name,
        'status': operation.status.name,
        'idempotencyKey': displayIdempotencyKey(operation.idempotencyKey),
        'baseVersion': operation.baseVersion,
        'dependencies': operation.dependencies,
        'attempts': operation.attempts,
        'createdAt': operation.createdAt.toIso8601String(),
        'updatedAt': operation.updatedAt.toIso8601String(),
        'lastAttemptAt': operation.lastAttemptAt?.toIso8601String(),
        'nextAttemptAt': operation.nextAttemptAt?.toIso8601String(),
        'lastError': operation.lastError?.toJson(),
        'schemaVersion': operation.schemaVersion,
        if (includePayloads) 'payload': redactor.redactMap(operation.payload),
      };

  static Map<String, Object?>? _runJson(SyncRunResult? result) => result == null
      ? null
      : {
          'stopReason': result.stopReason.name,
          'startedAt': result.startedAt.toIso8601String(),
          'finishedAt': result.finishedAt.toIso8601String(),
          'acknowledged': result.acknowledged,
          'retryScheduled': result.retryScheduled,
          'rejected': result.rejected,
          'conflicts': result.conflicts,
          'leaseLost': result.leaseLost,
          'blocked': result.blocked,
          'conflictsResolved': result.conflictsResolved,
          'pulledChanges': result.pulledChanges,
          'pullFailures': result.pullFailures,
        };

  // --- internals -------------------------------------------------------------

  void _record(SyncEvent event) {
    if (event is SyncRunCompleted) {
      _lastRunResult = event.result;
      if (event.result.isComplete) _lastSuccessfulSyncAt = event.at;
    }
    _append(InspectorEvent.fromSyncEvent(event));
  }

  void _recordAction(String verb, String? operationId, {int extra = 0}) {
    _append(InspectorEvent(
      kind: InspectorEventKind.developerAction,
      at: _clock.now(),
      summary: operationId == null
          ? verb
          : '$verb operation $operationId'
              '${extra > 0 ? ' and $extra dependent${extra == 1 ? '' : 's'}' : ''}',
      operationId: operationId,
    ));
  }

  void _append(InspectorEvent event) {
    if (_disposed || !isEnabled) return;
    _timeline.addLast(event);
    while (_timeline.length > maxTimelineEvents) {
      _timeline.removeFirst();
    }
    notifyListeners();
  }

  Future<SyncOperation?> _getScoped(String operationId) async {
    final accountId = engine.activeAccountId;
    if (accountId == null) return null;
    final operation = await storage.getOperation(operationId);
    return operation?.accountId == accountId ? operation : null;
  }

  Future<void> _requireScoped(String operationId) async {
    _ensureUsable();
    if (await _getScoped(operationId) == null) {
      throw OperationNotFoundException(operationId);
    }
  }

  void _ensureUsable() {
    _ensureNotDisposed();
    if (!isEnabled) {
      throw StateError(
        'SyncInspector is disabled. Pass enabled: true to use it in release '
        'builds.',
      );
    }
  }

  void _ensureNotDisposed() {
    if (_disposed) throw StateError('SyncInspector has been disposed.');
  }

  /// Stops recording. Does not close the engine or the storage.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // Not awaited: a broadcast subscription's cancel() returns a root-zone
    // future; see the syncflow_flutter README.
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
