import 'dart:async';
import 'dart:math';

import '../adapters/sync_storage.dart';
import '../adapters/sync_transport.dart';
import '../conflict/conflict.dart';
import '../conflict/conflict_coordinator.dart';
import '../entities/sync_entity.dart';
import '../events/sync_event.dart';
import '../executor/operation_executor.dart';
import '../executor/response_classifier.dart';
import '../models/exceptions.dart';
import '../models/sync_error.dart';
import '../pull/pull_coordinator.dart';
import '../queue/operation.dart';
import '../queue/operation_status.dart';
import '../scheduler/retry_policy.dart';
import '../utils/clock.dart';
import '../utils/id_generator.dart';
import 'sync_run_result.dart';

/// Tuning parameters for [SyncEngine].
final class SyncEngineConfig {
  /// Creates a configuration.
  const SyncEngineConfig({
    this.maxConcurrentOperations = 3,
    this.leaseDuration = const Duration(minutes: 2),
    this.batchSize = 50,
    this.pullEnabled = true,
    this.maxPullPagesPerEntity = 100,
  });

  /// Maximum number of operations delivered at the same time.
  final int maxConcurrentOperations;

  /// How long a worker may hold an operation before it is considered
  /// abandoned and recovered.
  ///
  /// Must comfortably exceed the transport's request timeout. If a lease
  /// expires mid-request, the operation can be delivered twice; the shared
  /// idempotency key lets the server deduplicate it.
  final Duration leaseDuration;

  /// Number of eligible operations fetched from storage at a time.
  final int batchSize;

  /// Whether [SyncEngine.syncNow] pulls remote changes, after pushing, for
  /// entities with a pull endpoint and an adapter.
  final bool pullEnabled;

  /// Upper bound on pages pulled per entity and run.
  final int maxPullPagesPerEntity;

  void _validate() {
    if (maxConcurrentOperations < 1) {
      throw ArgumentError.value(
        maxConcurrentOperations,
        'maxConcurrentOperations',
        'must be positive',
      );
    }
    if (leaseDuration <= Duration.zero) {
      throw ArgumentError.value(
        leaseDuration,
        'leaseDuration',
        'must be positive',
      );
    }
    if (batchSize < 1) {
      throw ArgumentError.value(batchSize, 'batchSize', 'must be positive');
    }
  }
}

/// Delivers queued operations to the backend.
///
/// The engine is foreground-first: it works when [syncNow] is called (by the
/// application, or later by lifecycle and connectivity triggers). Each run:
///
/// 1. Checks that an account is active and the engine is not paused.
/// 2. Recovers expired leases left by crashed or stalled workers.
/// 3. Repeatedly fetches eligible operations of the active account, holds back
///    those whose dependencies are not acknowledged yet, and delivers the rest
///    with bounded concurrency.
/// 4. Stops when nothing more can be delivered, or early if the account
///    changes, authentication is required, or the engine is paused or closed.
///
/// Each operation is attempted at most once per run, so a run always
/// terminates. Delivery is at-least-once: every attempt carries the
/// operation's stable idempotency key.
///
/// The engine does not own [SyncStorage] or [SyncTransport]: initialize the
/// storage before [initialize], and close both after [close].
final class SyncEngine {
  /// Creates an engine.
  ///
  /// [activeAccount] returns the currently signed-in account, or `null` when
  /// nobody is signed in. Only that account's operations are delivered.
  ///
  /// With [entities], acknowledged creates that receive a server-assigned ID
  /// record an ID mapping (see `RestRequestBuilder`) and emit
  /// [EntityIdAssigned].
  SyncEngine({
    required SyncStorage storage,
    required SyncTransport transport,
    required SyncRequestBuilder requestBuilder,
    required String? Function() activeAccount,
    SyncEntityRegistry? entities,
    SyncEngineConfig config = const SyncEngineConfig(),
    RetryPolicy? retryPolicy,
    SyncResponseClassifier classifier = const HttpResponseClassifier(),
    Clock clock = const SystemClock(),
    IdGenerator idGenerator = const UuidV4Generator(),
  })  : _storage = storage,
        _entities = entities,
        _activeAccount = activeAccount,
        _config = config,
        _clock = clock,
        workerId = 'engine-${idGenerator.next()}' {
    config._validate();
    _executor = OperationExecutor(
      storage: storage,
      transport: transport,
      requestBuilder: requestBuilder,
      retryPolicy: retryPolicy ?? ExponentialBackoffRetryPolicy(),
      classifier: classifier,
      clock: clock,
      workerId: workerId,
      leaseDuration: config.leaseDuration,
      emit: _emit,
      entities: entities,
    );
    _conflicts = ConflictCoordinator(
      storage: storage,
      clock: clock,
      emit: _emit,
      entities: entities,
    );
    _puller = PullCoordinator(
      storage: storage,
      transport: transport,
      classifier: classifier,
      clock: clock,
      emit: _emit,
      maxPagesPerPull: config.maxPullPagesPerEntity,
    );
  }

  final SyncStorage _storage;
  final String? Function() _activeAccount;
  final SyncEngineConfig _config;
  final Clock _clock;
  final SyncEntityRegistry? _entities;
  late final OperationExecutor _executor;
  late final ConflictCoordinator _conflicts;
  late final PullCoordinator _puller;
  final StreamController<SyncEvent> _events =
      StreamController<SyncEvent>.broadcast();
  final Set<String> _authenticationRequired = {};

  /// Lease owner identifier of this engine instance.
  final String workerId;

  bool _initialized = false;
  bool _closed = false;
  bool _paused = false;
  Future<SyncRunResult>? _activeRun;
  Future<SyncRunResult>? _queuedRun;

  /// Engine events. Operation events are emitted after the state is stored.
  Stream<SyncEvent> get events => _events.stream;

  /// The currently signed-in account, as reported by the `activeAccount`
  /// callback, or `null` when nobody is signed in.
  String? get activeAccountId => _activeAccount();

  /// Whether a run is in progress.
  bool get isSyncing => _activeRun != null;

  /// Whether [close] was called.
  bool get isClosed => _closed;

  /// Whether the application paused the engine.
  bool get isPaused => _paused;

  /// Whether delivery for [accountId] is paused until authentication is
  /// restored.
  bool isAuthenticationRequired(String accountId) =>
      _authenticationRequired.contains(accountId);

  /// Recovers operations whose leases expired, for example because the app
  /// was killed mid-delivery. Must be called once before [syncNow].
  ///
  /// Only expired leases are recovered: an unexpired lease may belong to
  /// another live worker (such as a background isolate).
  Future<void> initialize() async {
    _ensureOpen();
    if (_initialized) return;
    await _recoverLeases();
    _initialized = true;
  }

  /// Delivers eligible operations of the active account.
  ///
  /// If a run is already in progress, another run is scheduled to start when
  /// it finishes, and that run's result is returned. Concurrent callers share
  /// the scheduled run.
  Future<SyncRunResult> syncNow() {
    _ensureOpen();
    if (!_initialized) {
      throw StateError('SyncEngine.initialize() must be called first.');
    }
    if (_queuedRun case final queued?) return queued;
    final active = _activeRun;
    if (active == null) return _startRun();
    return _queuedRun = active.then(
      (_) => _startRun(),
      onError: (Object _) => _startRun(),
    );
  }

  /// Stops starting new deliveries. In-flight deliveries finish normally.
  void pause() => _paused = true;

  /// Allows deliveries again. Does not start a run by itself.
  void resume() => _paused = false;

  /// Resumes delivery for [accountId] after the application restored its
  /// credentials. Does not start a run by itself.
  void resumeAuthentication(String accountId) =>
      _authenticationRequired.remove(accountId);

  /// The number of operations of the active account per status, or an empty
  /// map when no account is active.
  Future<Map<SyncOperationStatus, int>> operationCounts() async {
    final accountId = _activeAccount();
    if (accountId == null) return const {};
    return _storage.countOperations(accountId: accountId);
  }

  /// Settles the conflict of [operationId] with [resolution] and returns the
  /// stored operation.
  ///
  /// [UseLocal] and [MergeResolution] re-queue the operation on top of the
  /// server's version; it is sent on the next [syncNow]. [UseRemote] applies
  /// the server's state through the entity adapter, when one is registered,
  /// and cancels the operation. Everything happens in one storage
  /// transaction.
  ///
  /// Throws an [OperationNotFoundException], an
  /// [InvalidStateTransitionException] if the operation is not in conflict, or
  /// an [ArgumentError] for [RequireManualResolution].
  Future<SyncOperation> resolveConflict(
    String operationId,
    ConflictResolution resolution,
  ) {
    _ensureOpen();
    return _conflicts.resolve(operationId, resolution);
  }

  /// Waits for any run to finish and releases the event stream.
  ///
  /// Does not close the storage or the transport.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await (_queuedRun ?? _activeRun);
    } on Object {
      // A failing run has already reported its error to its caller.
    }
    await _events.close();
  }

  Future<SyncRunResult> _startRun() {
    _queuedRun = null;
    late final Future<SyncRunResult> run;
    run = _run().whenComplete(() {
      if (identical(_activeRun, run)) _activeRun = null;
    });
    _activeRun = run;
    return run;
  }

  Future<SyncRunResult> _run() async {
    final startedAt = _clock.now();
    final accountId = _activeAccount();
    final earlyStop = _stopReason(accountId);
    if (earlyStop != null || accountId == null) {
      return SyncRunResult(
        accountId: accountId,
        stopReason: earlyStop ?? SyncRunStopReason.noActiveAccount,
        startedAt: startedAt,
        finishedAt: _clock.now(),
      );
    }

    _emit(SyncRunStarted(accountId: accountId, at: startedAt));
    await _recoverLeases();

    final tally = <ExecutionResult, int>{};
    final stats = _RunStats();
    final processed = <String>{};
    final blocked = <String>{};
    SyncRunStopReason? stop;

    while (stop == null) {
      final eligible = await _storage.getEligibleOperations(
        accountId: accountId,
        now: _clock.now(),
        limit: _config.batchSize + processed.length,
      );
      final ready = <SyncOperation>[];
      var propagated = false;
      for (final operation in eligible) {
        if (processed.contains(operation.id)) continue;
        switch (await _dependencyState(operation)) {
          case _Ready():
            ready.add(operation);
          case _Waiting():
            blocked.add(operation.id);
          case _Failed(:final dependency):
            processed.add(operation.id);
            if (await _rejectForDependency(operation, dependency)) {
              tally.update(
                ExecutionResult.rejected,
                (count) => count + 1,
                ifAbsent: () => 1,
              );
              propagated = true;
            }
        }
        if (ready.length == _config.batchSize) break;
      }
      // Rejections can unblock nothing but may cascade: look again.
      if (ready.isEmpty) {
        if (propagated) continue;
        break;
      }
      stop = await _deliver(ready, accountId, tally, processed, stats);
    }

    // Pull after push, so local changes reach the server before remote state
    // is applied, and only when the push phase was not interrupted.
    if (stop == null && _config.pullEnabled) {
      stop = await _pullAll(accountId, stats);
    }

    blocked.removeAll(processed);
    final result = SyncRunResult(
      accountId: accountId,
      stopReason: stop ?? SyncRunStopReason.completed,
      startedAt: startedAt,
      finishedAt: _clock.now(),
      acknowledged: tally[ExecutionResult.acknowledged] ?? 0,
      retryScheduled: tally[ExecutionResult.retryScheduled] ?? 0,
      rejected: tally[ExecutionResult.rejected] ?? 0,
      conflicts: tally[ExecutionResult.conflict] ?? 0,
      leaseLost: tally[ExecutionResult.leaseLost] ?? 0,
      blocked: blocked.length,
      conflictsResolved: stats.conflictsResolved,
      pulledChanges: stats.pulledChanges,
      pullFailures: stats.pullFailures,
    );
    _emit(SyncRunCompleted(result: result, at: result.finishedAt));
    return result;
  }

  // Delivers [ready] with bounded concurrency. Returns a stop reason if the
  // run must end early.
  Future<SyncRunStopReason?> _deliver(
    List<SyncOperation> ready,
    String accountId,
    Map<ExecutionResult, int> tally,
    Set<String> processed,
    _RunStats stats,
  ) async {
    SyncRunStopReason? stop;
    var next = 0;

    Future<void> worker() async {
      while (stop == null && next < ready.length) {
        final current = _activeAccount();
        stop = current != accountId
            ? SyncRunStopReason.accountChanged
            : _stopReason(current);
        if (stop != null) break;

        final operation = ready[next++];
        processed.add(operation.id);
        final result = await _executor.execute(operation.id);
        tally.update(result, (count) => count + 1, ifAbsent: () => 1);
        if (result == ExecutionResult.conflict &&
            await _conflicts.autoResolve(operation.id)) {
          stats.conflictsResolved++;
        }
        if (result == ExecutionResult.authenticationRequired) {
          _authenticationRequired.add(accountId);
          stop = SyncRunStopReason.authenticationRequired;
        }
      }
    }

    final workers = min(_config.maxConcurrentOperations, ready.length);
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    return stop;
  }

  // Pulls every pull-enabled entity in registration order. A failed entity
  // keeps its checkpoint and does not stop the others, except when
  // authentication is required or the run must stop.
  Future<SyncRunStopReason?> _pullAll(String accountId, _RunStats stats) async {
    final entities = _entities;
    if (entities == null) return null;
    for (final name in entities.names) {
      final entity = entities[name]!;
      if (entity.pull == null || entity.adapter == null) continue;

      final current = _activeAccount();
      final stop = current != accountId
          ? SyncRunStopReason.accountChanged
          : _stopReason(current);
      if (stop != null) return stop;

      final outcome = await _puller.pull(accountId, entity);
      stats.pulledChanges += outcome.applied;
      if (outcome.failed) stats.pullFailures++;
      if (outcome.authenticationRequired) {
        _authenticationRequired.add(accountId);
        return SyncRunStopReason.authenticationRequired;
      }
    }
    return null;
  }

  // A dependency is satisfied once acknowledged, or when it was cancelled
  // (discarded work) or no longer exists (compacted history). A rejected
  // dependency can never be satisfied by waiting, so the dependent fails too.
  // Anything else means waiting.
  Future<_DependencyState> _dependencyState(SyncOperation operation) async {
    var waiting = false;
    for (final dependencyId in operation.dependencies) {
      final dependency = await _storage.getOperation(dependencyId);
      switch (dependency?.status) {
        case null ||
              SyncOperationStatus.acknowledged ||
              SyncOperationStatus.cancelled:
          continue;
        case SyncOperationStatus.rejected:
          return _Failed(dependency!);
        case _:
          waiting = true;
      }
    }
    return waiting ? const _Waiting() : const _Ready();
  }

  // Rejects [operation] because [dependency] was rejected. Returns false if
  // the operation changed concurrently (another worker got there first).
  Future<bool> _rejectForDependency(
    SyncOperation operation,
    SyncOperation dependency,
  ) async {
    final now = _clock.now();
    final SyncOperation stored;
    try {
      stored = await _storage.updateOperation(
        operation.transitionTo(SyncOperationStatus.rejected, at: now).copyWith(
              clearNextAttemptAt: true,
              lastError: SyncError(
                category: SyncErrorCategory.dependency,
                message: 'Prerequisite operation "${dependency.id}" '
                    'was rejected.',
                isRetryable: false,
                operationId: operation.id,
                occurredAt: now,
              ),
            ),
      );
    } on StaleOperationException {
      return false;
    } on OperationNotFoundException {
      return false;
    }
    _emit(OperationRejected(operation: stored, at: now));
    return true;
  }

  SyncRunStopReason? _stopReason(String? accountId) {
    if (_closed) return SyncRunStopReason.closed;
    if (accountId == null) return SyncRunStopReason.noActiveAccount;
    if (_paused) return SyncRunStopReason.paused;
    if (_authenticationRequired.contains(accountId)) {
      return SyncRunStopReason.authenticationRequired;
    }
    return null;
  }

  Future<void> _recoverLeases() async {
    final now = _clock.now();
    final recovered = await _storage.recoverExpiredLeases(now);
    if (recovered > 0) _emit(LeasesRecovered(count: recovered, at: now));
  }

  void _emit(SyncEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void _ensureOpen() {
    if (_closed) throw StateError('SyncEngine has been closed.');
  }
}

sealed class _DependencyState {
  const _DependencyState();
}

final class _Ready extends _DependencyState {
  const _Ready();
}

final class _Waiting extends _DependencyState {
  const _Waiting();
}

final class _Failed extends _DependencyState {
  const _Failed(this.dependency);

  final SyncOperation dependency;
}

final class _RunStats {
  int conflictsResolved = 0;
  int pulledChanges = 0;
  int pullFailures = 0;
}
