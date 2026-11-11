import '../models/sync_error.dart';
import '../models/sync_response.dart';

/// The classified result of one delivery attempt.
///
/// Produced by a `SyncResponseClassifier`; consumed by the engine to decide the
/// operation's next state.
sealed class DeliveryOutcome {
  const DeliveryOutcome();
}

/// The server accepted the operation.
final class DeliverySucceeded extends DeliveryOutcome {
  /// Creates a successful outcome.
  const DeliverySucceeded(this.response);

  /// The server's response.
  final SyncResponse response;
}

/// A transient failure: the operation should be attempted again later.
final class DeliveryRetryable extends DeliveryOutcome {
  /// Creates a retryable outcome.
  const DeliveryRetryable(this.error, {this.retryAfter});

  /// Description of the failure.
  final SyncError error;

  /// Server-requested delay before retrying, if any.
  final Duration? retryAfter;
}

/// Credentials are missing or expired. Delivery for the account pauses until
/// the application restores authentication.
final class DeliveryUnauthenticated extends DeliveryOutcome {
  /// Creates an authentication-required outcome.
  const DeliveryUnauthenticated(this.error);

  /// Description of the failure.
  final SyncError error;
}

/// A permanent failure: retrying the same request will not succeed.
final class DeliveryRejected extends DeliveryOutcome {
  /// Creates a rejected outcome.
  const DeliveryRejected(this.error);

  /// Description of the failure.
  final SyncError error;
}

/// The mutation was based on an outdated version and needs conflict
/// resolution.
final class DeliveryConflicted extends DeliveryOutcome {
  /// Creates a conflict outcome.
  const DeliveryConflicted(this.error, this.response);

  /// Description of the conflict.
  final SyncError error;

  /// The server's response, which may describe the current remote state.
  final SyncResponse response;
}
