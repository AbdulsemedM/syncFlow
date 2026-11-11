import 'dart:async';
import 'dart:math';

import '../adapters/sync_storage.dart';
import '../adapters/sync_transport.dart';
import '../events/sync_event.dart';
import '../executor/operation_executor.dart';
import '../executor/response_classifier.dart';
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
  SyncEngine({
    required SyncStorage storage,
    required SyncTransport transport,
    required SyncRequestBuilder requestBuilder,
    required String? Function() activeAccount,
    SyncEngineConfig config = const SyncEngineConfig(),
    RetryPolicy? retryPolicy,
    SyncResponseClassifier classifier = const HttpResponseClassifier(),
    Clock clock = const SystemClock(),
    IdGenerator idGenerator = const UuidV4Generator(),
  })  : _storage = storage,
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
    );
  }

  final SyncStorage _storage;
  final String? Function() _activeAccount;
  final SyncEngineConfig _config;
  final Clock _clock;
  late final OperationExecutor _executor;
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

  /// Whether a run is in progress.
  bool get isSyncing => _activeRun != null;

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
      for (final operation in eligible) {
        if (processed.contains(operation.id)) continue;
        if (await _dependenciesSatisfied(operation)) {
          ready.add(operation);
          if (ready.length == _config.batchSize) break;
        } else {
          blocked.add(operation.id);
        }
      }
      if (ready.isEmpty) break;
      stop = await _deliver(ready, accountId, tally, processed);
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

  // A dependency is satisfied once acknowledged. A dependency that no longer
  // exists is treated as satisfied (acknowledged history may be compacted).
  Future<bool> _dependenciesSatisfied(SyncOperation operation) async {
    for (final dependencyId in operation.dependencies) {
      final dependency = await _storage.getOperation(dependencyId);
      if (dependency != null &&
          dependency.status != SyncOperationStatus.acknowledged) {
        return false;
      }
    }
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
