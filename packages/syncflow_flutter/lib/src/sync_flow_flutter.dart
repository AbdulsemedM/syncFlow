import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:syncflow/syncflow.dart';

import 'connectivity_source.dart';
import 'sync_status.dart';

/// Connects a [SyncEngine] to the Flutter application lifecycle.
///
/// Once [start]ed, it runs `engine.syncNow()` when:
///
/// * the controller starts ([SyncTrigger.startup]);
/// * the app returns to the foreground ([SyncTrigger.resumed]);
/// * connectivity is restored ([SyncTrigger.connectivityRestored]);
/// * a scheduled retry becomes due while in the foreground
///   ([SyncTrigger.retryDue]);
/// * the optional [periodicInterval] elapses in the foreground
///   ([SyncTrigger.periodic]);
/// * [syncNow] is called ([SyncTrigger.manual]).
///
/// Automatic triggers that fire within [debounce] of each other collapse into
/// one run, and are skipped while the connectivity source reports offline.
/// Manual requests always run immediately.
///
/// This is foreground synchronization. Operating systems decide when apps may
/// run in the background; for opportunistic background sync, call
/// `engine.syncNow()` from a background task scheduler of your choice.
///
/// The controller does not own the engine: [dispose] stops all triggers but
/// leaves the engine open.
class SyncFlowFlutter {
  /// Creates a controller for [engine].
  SyncFlowFlutter({
    required this.engine,
    this.connectivity,
    this.syncOnStart = true,
    this.syncOnResume = true,
    this.periodicInterval,
    this.debounce = const Duration(milliseconds: 500),
    this.pauseWhenBackgrounded = false,
    this.skipWhenOffline = true,
    Clock clock = const SystemClock(),
    WidgetsBinding? binding,
  })  : _clock = clock,
        _binding = binding;

  /// The engine driven by this controller.
  final SyncEngine engine;

  /// Optional connectivity hints.
  final ConnectivitySource? connectivity;

  /// Whether [start] triggers a sync.
  final bool syncOnStart;

  /// Whether returning to the foreground triggers a sync.
  final bool syncOnResume;

  /// Interval of periodic syncs while in the foreground, or `null` for none.
  final Duration? periodicInterval;

  /// Window within which automatic triggers are merged into one run.
  final Duration debounce;

  /// Whether to pause the engine while the app is in the background, so no
  /// new deliveries start there. In-flight deliveries finish or are recovered
  /// through lease expiry.
  final bool pauseWhenBackgrounded;

  /// Whether automatic triggers are skipped while the connectivity source
  /// reports offline.
  final bool skipWhenOffline;

  final Clock _clock;
  final WidgetsBinding? _binding;

  final ValueNotifier<SyncStatus> _status = ValueNotifier(const SyncStatus());
  AppLifecycleListener? _lifecycle;
  StreamSubscription<bool>? _connectivitySubscription;
  StreamSubscription<SyncEvent>? _eventSubscription;
  Timer? _debounceTimer;
  Timer? _periodicTimer;
  Timer? _retryTimer;
  SyncTrigger? _pendingTrigger;
  DateTime? _nextRetryAt;
  bool _foreground = true;
  bool _pausedByUs = false;
  bool _started = false;
  bool _disposed = false;
  int _running = 0;

  /// The current synchronization status, for `ValueListenableBuilder`.
  ValueListenable<SyncStatus> get status => _status;

  /// Whether the app is considered in the foreground.
  bool get isInForeground => _foreground;

  /// Starts listening to lifecycle, connectivity and engine events.
  void start() {
    _ensureNotDisposed();
    if (_started) return;
    _started = true;

    _lifecycle = AppLifecycleListener(
      binding: _binding,
      onResume: _handleResume,
      onHide: _handleHide,
    );
    _connectivitySubscription =
        connectivity?.onConnectivityChanged.listen(_handleConnectivity);
    _eventSubscription = engine.events.listen(_handleEvent);
    _startPeriodic();
    unawaited(refreshStatus());
    if (syncOnStart) _schedule(SyncTrigger.startup);
  }

  /// Runs a synchronization now, bypassing debounce and connectivity hints.
  ///
  /// Returns the run result, or `null` if the engine was closed. Unexpected
  /// errors are recorded in [SyncStatus.lastError] and rethrown.
  Future<SyncRunResult?> syncNow() => _run(SyncTrigger.manual);

  /// Reloads the operation counts from storage.
  Future<void> refreshStatus() async {
    if (_disposed) return;
    final counts = await engine.operationCounts();
    if (_disposed) return;
    _status.value = _status.value.copyWith(operationCounts: counts);
  }

  /// Stops all triggers and releases listeners. Does not close the engine.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _debounceTimer?.cancel();
    _periodicTimer?.cancel();
    _retryTimer?.cancel();
    _lifecycle?.dispose();
    // Not awaited: a broadcast subscription's cancel() returns a future bound
    // to the root zone, and awaiting it would move the caller out of its zone
    // (for example flutter_test's fake-async zone, hanging later pumps).
    unawaited(_connectivitySubscription?.cancel());
    unawaited(_eventSubscription?.cancel());
    if (_pausedByUs) engine.resume();
    _status.dispose();
  }

  // --- triggers --------------------------------------------------------------

  void _schedule(SyncTrigger trigger) {
    if (_disposed) return;
    if (skipWhenOffline && _status.value.isOnline == false) return;
    _pendingTrigger ??= trigger;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () {
      final pending = _pendingTrigger ?? trigger;
      _pendingTrigger = null;
      unawaited(_run(pending).catchError((Object _) => null));
    });
  }

  void _handleResume() {
    _foreground = true;
    if (_pausedByUs) {
      engine.resume();
      _pausedByUs = false;
    }
    _startPeriodic();
    _scheduleRetryWakeUp();
    if (syncOnResume) _schedule(SyncTrigger.resumed);
  }

  void _handleHide() {
    _foreground = false;
    _periodicTimer?.cancel();
    _retryTimer?.cancel();
    _debounceTimer?.cancel();
    _pendingTrigger = null;
    if (pauseWhenBackgrounded && !engine.isPaused) {
      engine.pause();
      _pausedByUs = true;
    }
  }

  void _handleConnectivity(bool online) {
    final wasOnline = _status.value.isOnline;
    _status.value = _status.value.copyWith(isOnline: online);
    if (online && wasOnline == false && _foreground) {
      _schedule(SyncTrigger.connectivityRestored);
    }
  }

  void _handleEvent(SyncEvent event) {
    if (event is OperationRetryScheduled) {
      final due = event.operation.nextAttemptAt;
      if (due != null &&
          (_nextRetryAt == null || due.isBefore(_nextRetryAt!))) {
        _nextRetryAt = due;
      }
    }
  }

  void _startPeriodic() {
    final interval = periodicInterval;
    _periodicTimer?.cancel();
    if (interval == null || !_foreground || _disposed) return;
    _periodicTimer = Timer.periodic(
      interval,
      (_) => _schedule(SyncTrigger.periodic),
    );
  }

  // Wakes up when the earliest scheduled retry is due, so retries happen even
  // when nothing else triggers a sync.
  void _scheduleRetryWakeUp() {
    _retryTimer?.cancel();
    final due = _nextRetryAt;
    if (due == null || !_foreground || _disposed) return;
    var delay = due.difference(_clock.now());
    if (delay < const Duration(seconds: 1)) delay = const Duration(seconds: 1);
    _retryTimer = Timer(delay, () {
      _nextRetryAt = null;
      _schedule(SyncTrigger.retryDue);
    });
  }

  // --- runs ------------------------------------------------------------------

  Future<SyncRunResult?> _run(SyncTrigger trigger) async {
    _ensureNotDisposed();
    _running++;
    _status.value =
        _status.value.copyWith(isSyncing: true, lastTrigger: trigger);
    _nextRetryAt = null;
    try {
      final result = await engine.syncNow();
      if (!_disposed) {
        _status.value = _status.value.copyWith(
          lastResult: result,
          lastCompletedAt: result.isComplete ? _clock.now() : null,
          clearLastError: true,
        );
      }
      return result;
    } on StateError catch (error) {
      // A closed engine is a normal shutdown, not a failure.
      if (engine.isClosed) return null;
      if (!_disposed) {
        _status.value = _status.value.copyWith(lastError: error);
      }
      rethrow;
    } catch (error) {
      if (!_disposed) {
        _status.value = _status.value.copyWith(lastError: error);
      }
      rethrow;
    } finally {
      _running--;
      if (!_disposed) {
        _status.value = _status.value.copyWith(isSyncing: _running > 0);
        await refreshStatus();
        _scheduleRetryWakeUp();
      }
    }
  }

  void _ensureNotDisposed() {
    if (_disposed) throw StateError('SyncFlowFlutter has been disposed.');
  }
}
