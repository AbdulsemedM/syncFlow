import '../engine/sync_run_result.dart';
import '../models/sync_response.dart';
import '../queue/operation.dart';

/// Something observable happened in the engine.
///
/// Operation events are emitted only **after** the corresponding state has
/// been durably stored. Events are notifications, not the source of truth: the
/// stored operation is authoritative, and events missed while nobody listens
/// are not replayed.
sealed class SyncEvent {
  const SyncEvent({required this.at});

  /// When the event occurred (UTC).
  final DateTime at;
}

/// A synchronization run started for [accountId].
final class SyncRunStarted extends SyncEvent {
  /// Creates the event.
  const SyncRunStarted({required this.accountId, required super.at});

  /// Account being synchronized.
  final String accountId;
}

/// A synchronization run finished.
final class SyncRunCompleted extends SyncEvent {
  /// Creates the event.
  const SyncRunCompleted({required this.result, required super.at});

  /// Summary of the run.
  final SyncRunResult result;
}

/// Expired leases were returned to the queue (crash recovery).
final class LeasesRecovered extends SyncEvent {
  /// Creates the event.
  const LeasesRecovered({required this.count, required super.at});

  /// Number of recovered operations.
  final int count;
}

/// The server acknowledged an operation.
final class OperationAcknowledged extends SyncEvent {
  /// Creates the event.
  const OperationAcknowledged({
    required this.operation,
    required this.response,
    required super.at,
  });

  /// The stored, acknowledged operation.
  final SyncOperation operation;

  /// The server's response.
  final SyncResponse response;
}

/// An operation failed transiently and is scheduled for another attempt at
/// its `nextAttemptAt`.
final class OperationRetryScheduled extends SyncEvent {
  /// Creates the event.
  const OperationRetryScheduled({required this.operation, required super.at});

  /// The stored operation, including `lastError` and `nextAttemptAt`.
  final SyncOperation operation;
}

/// An operation was permanently rejected and needs application attention.
final class OperationRejected extends SyncEvent {
  /// Creates the event.
  const OperationRejected({required this.operation, required super.at});

  /// The stored operation, including `lastError`.
  final SyncOperation operation;
}

/// An operation hit a version conflict.
final class OperationConflicted extends SyncEvent {
  /// Creates the event.
  const OperationConflicted({
    required this.operation,
    required this.response,
    required super.at,
  });

  /// The stored operation.
  final SyncOperation operation;

  /// The server's response, which may describe the remote state.
  final SyncResponse response;
}

/// The engine lost an operation's lease before recording the result, so the
/// result was discarded. The operation is delivered again later with the same
/// idempotency key.
final class OperationLeaseLost extends SyncEvent {
  /// Creates the event.
  const OperationLeaseLost({required this.operationId, required super.at});

  /// The affected operation.
  final String operationId;
}

/// The server requires re-authentication. Synchronization for [accountId] is
/// paused until `SyncEngine.resumeAuthentication` is called.
final class AuthenticationRequired extends SyncEvent {
  /// Creates the event.
  const AuthenticationRequired({
    required this.accountId,
    required this.operation,
    required super.at,
  });

  /// Account whose credentials must be restored.
  final String accountId;

  /// The operation that triggered the pause, returned to `pending`.
  final SyncOperation operation;
}
