import '../utils/json.dart';

/// Classification of a synchronization failure.
///
/// The category drives default handling (retry, pause, reject, conflict
/// resolution). Backends differ, so mapping from transport results to
/// categories must remain configurable in transport adapters.
enum SyncErrorCategory {
  /// The connection failed before a response was received.
  network,

  /// The request or connection timed out.
  timeout,

  /// The credentials are missing or expired (typically HTTP 401).
  authentication,

  /// The caller is not permitted to perform the operation (typically 403).
  authorization,

  /// The server rejected the payload as invalid (typically 422).
  validation,

  /// The mutation was based on an outdated version.
  conflict,

  /// The server failed to process the request (typically 5xx).
  server,

  /// Local persistence failed.
  storage,

  /// A payload could not be encoded or decoded.
  serialization,

  /// A prerequisite operation failed or is missing.
  dependency,

  /// The server response did not follow the expected protocol.
  protocol,

  /// The failure could not be classified.
  unknown,
}

/// A sanitized, persistable description of a failure.
///
/// Instances are stored on operations as `lastError`, so [message] must never
/// contain access tokens, raw response bodies or personal data.
final class SyncError {
  /// Creates an error record.
  SyncError({
    required this.category,
    required this.message,
    required this.isRetryable,
    required DateTime occurredAt,
    this.httpStatus,
    this.serverRequestId,
    this.operationId,
  }) : occurredAt = occurredAt.toUtc();

  /// Decodes an error produced by [toJson].
  ///
  /// Throws a [FormatException] if [json] is malformed.
  factory SyncError.fromJson(Map<String, Object?> json) {
    return SyncError(
      category: readEnum(json, 'category', SyncErrorCategory.values),
      message: readField<String>(json, 'message'),
      isRetryable: readField<bool>(json, 'isRetryable'),
      occurredAt: readDateTime(json, 'occurredAt'),
      httpStatus: readField<int?>(json, 'httpStatus'),
      serverRequestId: readField<String?>(json, 'serverRequestId'),
      operationId: readField<String?>(json, 'operationId'),
    );
  }

  /// Failure classification.
  final SyncErrorCategory category;

  /// Safe, sanitized description of the failure.
  final String message;

  /// Whether the failure is expected to be transient.
  final bool isRetryable;

  /// HTTP status code, when the failure came from an HTTP response.
  final int? httpStatus;

  /// Server-provided request identifier, useful for backend log correlation.
  final String? serverRequestId;

  /// Operation that failed, if any.
  final String? operationId;

  /// When the failure occurred (UTC).
  final DateTime occurredAt;

  /// Encodes this error as a JSON-compatible map.
  Map<String, Object?> toJson() => {
        'category': category.name,
        'message': message,
        'isRetryable': isRetryable,
        'httpStatus': httpStatus,
        'serverRequestId': serverRequestId,
        'operationId': operationId,
        'occurredAt': occurredAt.toIso8601String(),
      };

  @override
  String toString() => 'SyncError(${category.name}'
      '${httpStatus == null ? '' : ', HTTP $httpStatus'}: $message)';
}
