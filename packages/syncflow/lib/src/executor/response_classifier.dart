import '../models/exceptions.dart';
import '../models/sync_error.dart';
import '../models/sync_response.dart';
import '../utils/retry_after.dart';
import 'delivery_outcome.dart';

/// Maps transport results to [DeliveryOutcome]s.
///
/// Backends differ in how they signal conflicts, validation errors and rate
/// limits, so this is a replaceable component. Error messages produced here
/// are persisted and must never include response bodies, tokens or personal
/// data.
abstract interface class SyncResponseClassifier {
  /// Classifies an HTTP [response] for the operation [operationId].
  DeliveryOutcome classifyResponse(
    SyncResponse response, {
    required String operationId,
    required DateTime now,
  });

  /// Classifies a failure where no HTTP response was obtained.
  DeliveryOutcome classifyTransportException(
    SyncTransportException exception, {
    required String operationId,
    required DateTime now,
  });
}

/// The default classifier, following conventional HTTP semantics.
///
/// | Status            | Outcome                                  |
/// | ----------------- | ---------------------------------------- |
/// | 2xx               | succeeded                                |
/// | 401               | unauthenticated (pause the account)      |
/// | 403               | rejected (authorization)                 |
/// | 408               | retryable (timeout)                      |
/// | 409, 412          | conflicted                               |
/// | 429               | retryable, honoring `Retry-After`        |
/// | 400, 422          | rejected (validation)                    |
/// | other 4xx         | rejected (protocol)                      |
/// | 5xx               | retryable, honoring `Retry-After`        |
/// | anything else     | retryable (protocol)                     |
///
/// Transport failures are retryable for the `network`, `timeout`, `server`
/// and `unknown` categories, pause the account for `authentication`, and are
/// rejected otherwise.
///
/// Extend this class and override its methods to adapt it to a backend.
class HttpResponseClassifier implements SyncResponseClassifier {
  /// Creates a classifier that reads server request IDs from
  /// [requestIdHeader] when the response does not provide one.
  const HttpResponseClassifier({this.requestIdHeader = 'x-request-id'});

  /// Header carrying the server's request identifier.
  final String requestIdHeader;

  @override
  DeliveryOutcome classifyResponse(
    SyncResponse response, {
    required String operationId,
    required DateTime now,
  }) {
    final status = response.statusCode;
    if (response.isSuccessful) return DeliverySucceeded(response);

    SyncError error(
      SyncErrorCategory category,
      String message, {
      required bool retryable,
    }) =>
        SyncError(
          category: category,
          message: 'HTTP $status: $message',
          isRetryable: retryable,
          httpStatus: status,
          serverRequestId:
              response.serverRequestId ?? response.header(requestIdHeader),
          operationId: operationId,
          occurredAt: now,
        );

    Duration? retryAfter() =>
        parseRetryAfter(response.header('retry-after'), now: now);

    return switch (status) {
      401 => DeliveryUnauthenticated(
          error(
            SyncErrorCategory.authentication,
            'authentication required.',
            retryable: true,
          ),
        ),
      403 => DeliveryRejected(
          error(
            SyncErrorCategory.authorization,
            'not permitted.',
            retryable: false,
          ),
        ),
      408 => DeliveryRetryable(
          error(
            SyncErrorCategory.timeout,
            'request timed out.',
            retryable: true,
          ),
        ),
      409 || 412 => DeliveryConflicted(
          error(
            SyncErrorCategory.conflict,
            'version conflict.',
            retryable: false,
          ),
          response,
        ),
      429 => DeliveryRetryable(
          error(SyncErrorCategory.server, 'rate limited.', retryable: true),
          retryAfter: retryAfter(),
        ),
      400 || 422 => DeliveryRejected(
          error(
            SyncErrorCategory.validation,
            'request rejected as invalid.',
            retryable: false,
          ),
        ),
      >= 400 && < 500 => DeliveryRejected(
          error(
            SyncErrorCategory.protocol,
            'request not accepted.',
            retryable: false,
          ),
        ),
      >= 500 && < 600 => DeliveryRetryable(
          error(SyncErrorCategory.server, 'server error.', retryable: true),
          retryAfter: retryAfter(),
        ),
      _ => DeliveryRetryable(
          error(
            SyncErrorCategory.protocol,
            'unexpected response status.',
            retryable: true,
          ),
        ),
    };
  }

  @override
  DeliveryOutcome classifyTransportException(
    SyncTransportException exception, {
    required String operationId,
    required DateTime now,
  }) {
    final category = exception.category;
    final retryable = switch (category) {
      SyncErrorCategory.network ||
      SyncErrorCategory.timeout ||
      SyncErrorCategory.server ||
      SyncErrorCategory.unknown =>
        true,
      _ => false,
    };
    final error = SyncError(
      category: category,
      message: exception.message,
      isRetryable: retryable || category == SyncErrorCategory.authentication,
      operationId: operationId,
      occurredAt: now,
    );
    if (category == SyncErrorCategory.authentication) {
      return DeliveryUnauthenticated(error);
    }
    return retryable ? DeliveryRetryable(error) : DeliveryRejected(error);
  }
}
