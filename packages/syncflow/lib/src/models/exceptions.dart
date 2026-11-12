import '../queue/operation_status.dart';
import 'sync_error.dart';

/// Base type for every exception thrown by SyncFlow's public API.
///
/// Adapters must translate database- or HTTP-library-specific exceptions into
/// one of these types (or a [SyncError]) instead of leaking them to callers.
abstract class SyncFlowException implements Exception {
  /// Creates an exception with a human-readable, non-sensitive [message].
  const SyncFlowException(this.message);

  /// Safe, human-readable description. Never contains payload data or tokens.
  final String message;

  /// Name used as a prefix by [toString].
  String get name;

  @override
  String toString() => '$name: $message';
}

/// Thrown when a lifecycle change violates the operation state machine.
final class InvalidStateTransitionException extends SyncFlowException {
  /// Creates an exception for the rejected [from] → [to] transition.
  InvalidStateTransitionException({
    required this.operationId,
    required this.from,
    required this.to,
  }) : super(
          'Operation "$operationId" cannot move from ${from.name} to ${to.name}.',
        );

  /// The operation whose transition was rejected.
  final String operationId;

  /// The current status.
  final SyncOperationStatus from;

  /// The requested status.
  final SyncOperationStatus to;

  @override
  String get name => 'InvalidStateTransitionException';
}

/// Thrown when an operation that must exist is not present in storage.
final class OperationNotFoundException extends SyncFlowException {
  /// Creates an exception for the missing [operationId].
  OperationNotFoundException(this.operationId)
      : super('Operation "$operationId" does not exist.');

  /// The identifier that was not found.
  final String operationId;

  @override
  String get name => 'OperationNotFoundException';
}

/// Thrown when inserting an operation whose identifier already exists.
final class DuplicateOperationException extends SyncFlowException {
  /// Creates an exception for the duplicated [operationId].
  DuplicateOperationException(this.operationId)
      : super('Operation "$operationId" already exists.');

  /// The identifier that already exists.
  final String operationId;

  @override
  String get name => 'DuplicateOperationException';
}

/// Thrown when an update is based on an outdated copy of an operation.
///
/// Storage implementations use the operation's revision for optimistic
/// concurrency: a write succeeds only if the stored revision still equals the
/// revision the writer read. This prevents, for example, a worker whose lease
/// expired from overwriting state produced by lease recovery.
final class StaleOperationException extends SyncFlowException {
  /// Creates an exception describing the revision mismatch.
  StaleOperationException({
    required this.operationId,
    required this.expectedRevision,
    required this.actualRevision,
  }) : super(
          'Operation "$operationId" was modified concurrently '
          '(expected revision $expectedRevision, found $actualRevision).',
        );

  /// The operation that was modified concurrently.
  final String operationId;

  /// The revision the writer based its update on.
  final int expectedRevision;

  /// The revision currently stored.
  final int actualRevision;

  @override
  String get name => 'StaleOperationException';
}

/// Thrown when an operation declares a dependency that cannot be satisfied.
final class InvalidDependencyException extends SyncFlowException {
  /// Creates an exception for [dependencyId] with an explanatory [reason].
  InvalidDependencyException({
    required this.dependencyId,
    required String reason,
  }) : super('Invalid dependency "$dependencyId": $reason');

  /// The dependency that could not be accepted.
  final String dependencyId;

  @override
  String get name => 'InvalidDependencyException';
}

/// Thrown when an operation refers to an entity that was never registered.
final class UnknownEntityException extends SyncFlowException {
  /// Creates an exception for [entityName].
  UnknownEntityException(this.entityName)
      : super('Entity "$entityName" is not registered.');

  /// The unregistered entity name.
  final String entityName;

  @override
  String get name => 'UnknownEntityException';
}

/// Thrown when an entity's endpoint does not support an operation type, for
/// example a delete on an entity configured without a delete path.
final class UnsupportedOperationTypeException extends SyncFlowException {
  /// Creates an exception for [operationType] on [entityName].
  UnsupportedOperationTypeException({
    required this.entityName,
    required this.operationType,
  }) : super('Entity "$entityName" has no endpoint for $operationType.');

  /// The entity whose endpoint is missing.
  final String entityName;

  /// The unsupported operation type name.
  final String operationType;

  @override
  String get name => 'UnsupportedOperationTypeException';
}

/// Thrown when the storage backend fails (I/O errors, constraint violations,
/// unsupported schema versions, ...).
final class SyncStorageException extends SyncFlowException {
  /// Creates a storage failure.
  const SyncStorageException(super.message, {this.cause});

  /// The underlying backend error, for internal diagnostics only.
  final Object? cause;

  @override
  String get name => 'SyncStorageException';
}

/// Thrown by a transport when no HTTP response could be obtained.
///
/// Transports return a response for every HTTP status code, including 4xx and
/// 5xx. This exception is reserved for failures where no status exists, such as
/// connection errors, timeouts and cancellation.
final class SyncTransportException extends SyncFlowException {
  /// Creates a transport failure of the given [category].
  const SyncTransportException(
    super.message, {
    required this.category,
    this.cause,
  });

  /// Classification used by retry and error handling.
  final SyncErrorCategory category;

  /// The underlying error, for internal diagnostics only. Never persisted.
  final Object? cause;

  @override
  String get name => 'SyncTransportException';
}
