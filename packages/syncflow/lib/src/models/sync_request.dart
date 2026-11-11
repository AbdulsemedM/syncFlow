/// HTTP methods SyncFlow can issue.
enum SyncHttpMethod {
  /// HTTP GET.
  get,

  /// HTTP POST.
  post,

  /// HTTP PUT.
  put,

  /// HTTP PATCH.
  patch,

  /// HTTP DELETE.
  delete,
}

/// A transport-independent description of a remote request.
///
/// Transport adapters translate this into a concrete HTTP call. The core never
/// depends on a specific HTTP client.
final class SyncRequest {
  /// Creates a request.
  SyncRequest({
    required this.method,
    required this.path,
    required this.accountId,
    Map<String, String> headers = const {},
    Map<String, Object?> queryParameters = const {},
    this.body,
    this.timeout,
    this.idempotencyKey,
    this.operationId,
  })  : headers = Map.unmodifiable(headers),
        queryParameters = Map.unmodifiable(queryParameters);

  /// HTTP method.
  final SyncHttpMethod method;

  /// Path relative to the transport's base URL, or an absolute URI.
  final String path;

  /// Account scope the request is executed for.
  ///
  /// Transports use this to select credentials and must never send a request
  /// using another account's credentials.
  final String accountId;

  /// Additional request headers. Must not be logged verbatim.
  final Map<String, String> headers;

  /// Query parameters.
  final Map<String, Object?> queryParameters;

  /// JSON-compatible request body.
  final Object? body;

  /// Per-request timeout. When `null`, the transport's default applies.
  final Duration? timeout;

  /// Stable deduplication key. Identical across every retry of an operation.
  final String? idempotencyKey;

  /// Operation this request delivers, if any.
  final String? operationId;

  /// Returns a copy with the given fields replaced.
  SyncRequest copyWith({
    SyncHttpMethod? method,
    String? path,
    String? accountId,
    Map<String, String>? headers,
    Map<String, Object?>? queryParameters,
    Object? body,
    Duration? timeout,
    String? idempotencyKey,
    String? operationId,
  }) =>
      SyncRequest(
        method: method ?? this.method,
        path: path ?? this.path,
        accountId: accountId ?? this.accountId,
        headers: headers ?? this.headers,
        queryParameters: queryParameters ?? this.queryParameters,
        body: body ?? this.body,
        timeout: timeout ?? this.timeout,
        idempotencyKey: idempotencyKey ?? this.idempotencyKey,
        operationId: operationId ?? this.operationId,
      );

  @override
  String toString() => 'SyncRequest(${method.name.toUpperCase()} $path'
      '${operationId == null ? '' : ', operation: $operationId'})';
}
