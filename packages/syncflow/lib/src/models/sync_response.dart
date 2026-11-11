/// A transport-independent, normalized response.
final class SyncResponse {
  /// Creates a response. Header names are normalized to lower case.
  SyncResponse({
    required this.statusCode,
    Map<String, String> headers = const {},
    this.body,
    this.serverRequestId,
    this.serverVersion,
  }) : headers = Map.unmodifiable({
          for (final entry in headers.entries)
            entry.key.toLowerCase(): entry.value,
        });

  /// HTTP status code.
  final int statusCode;

  /// Response headers with lower-case names.
  final Map<String, String> headers;

  /// Decoded response body.
  final Object? body;

  /// Server-provided request identifier, if any.
  final String? serverRequestId;

  /// Concurrency version reported by the server (revision, ETag, ...), if any.
  final String? serverVersion;

  /// Whether [statusCode] is in the 2xx range.
  bool get isSuccessful => statusCode >= 200 && statusCode < 300;

  /// Returns the header named [name], case-insensitively.
  String? header(String name) => headers[name.toLowerCase()];

  @override
  String toString() => 'SyncResponse($statusCode)';
}
