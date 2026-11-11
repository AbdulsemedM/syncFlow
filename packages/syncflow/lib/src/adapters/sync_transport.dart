import '../models/exceptions.dart';
import '../models/sync_request.dart';
import '../models/sync_response.dart';

/// Sends requests to a remote backend.
///
/// ## Contract
///
/// * Every HTTP response, including 4xx and 5xx, is returned as a
///   [SyncResponse]. Classification is done by the engine, not the transport.
/// * Failures without an HTTP status (connection errors, timeouts,
///   cancellation) are thrown as a [SyncTransportException].
/// * The request's idempotency key is sent unchanged on every attempt.
/// * Credentials are selected for the request's account. A request is never
///   sent with another account's credentials.
/// * Authorization headers and payloads are never logged.
abstract interface class SyncTransport {
  /// Sends [request] and returns the normalized response.
  Future<SyncResponse> send(SyncRequest request);

  /// Releases resources held by the transport.
  Future<void> close();
}
