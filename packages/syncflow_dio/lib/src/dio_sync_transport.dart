import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:syncflow/syncflow.dart';

import 'sync_authentication.dart';

/// A [SyncTransport] backed by your application's [Dio] instance.
///
/// The transport follows the `SyncTransport` contract:
///
/// * Every HTTP response, including 4xx and 5xx, is returned as a
///   [SyncResponse]. Classification is left to the engine.
/// * Failures without a response (connection errors, timeouts, cancellation)
///   are thrown as [SyncTransportException]s with a safe message. The
///   underlying cause never includes request headers.
/// * The operation's idempotency key is sent in [idempotencyHeader] on every
///   attempt and overrides any value set by a request builder.
/// * With [authentication], credentials are fetched for the request's own
///   account on every attempt. After a 401, the transport can refresh and retry
///   once with the same idempotency key.
///
/// Requests resolve against `dio.options.baseUrl`, and your interceptors run as
/// usual. Make sure none of them logs the `Authorization` header.
final class DioSyncTransport implements SyncTransport {
  /// Creates a transport.
  ///
  /// [close] closes [dio] only when [closeDio] is `true`.
  DioSyncTransport({
    required Dio dio,
    this.authentication,
    this.idempotencyHeader = 'Idempotency-Key',
    this.requestIdHeader = 'x-request-id',
    this.versionHeader = 'etag',
    this.defaultTimeout,
    this.closeDio = false,
  }) : _dio = dio;

  final Dio _dio;

  /// How requests are authenticated, or `null` to send request headers as is.
  final SyncAuthentication? authentication;

  /// Header carrying the operation's idempotency key.
  final String idempotencyHeader;

  /// Response header whose value becomes `SyncResponse.serverRequestId`.
  final String requestIdHeader;

  /// Response header whose value becomes `SyncResponse.serverVersion`.
  final String versionHeader;

  /// Timeout for connecting, sending and receiving when a request does not
  /// specify one. When `null`, the [Dio] options apply.
  final Duration? defaultTimeout;

  /// Whether [close] also closes the [Dio] instance.
  final bool closeDio;

  final Set<CancelToken> _inFlight = {};
  final Map<String, Future<bool>> _refreshing = {};
  bool _closed = false;

  @override
  Future<SyncResponse> send(SyncRequest request) async {
    if (_closed) throw StateError('DioSyncTransport has been closed.');

    final response = await _send(request);
    final refresh = authentication?.refresh;
    if (response.statusCode != 401 || refresh == null) return response;

    final refreshed = await _refresh(request.accountId, refresh);
    return refreshed && !_closed ? _send(request) : response;
  }

  /// Cancels in-flight requests (they fail with a retryable
  /// [SyncTransportException]) and, if [closeDio] is set, closes [Dio].
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final token in _inFlight.toList()) {
      token.cancel('DioSyncTransport closed');
    }
    if (closeDio) _dio.close(force: true);
  }

  Future<SyncResponse> _send(SyncRequest request) async {
    final headers = <String, Object>{...request.headers};

    final auth = authentication;
    if (auth != null) {
      _setHeader(
        headers,
        auth.headerName,
        auth.headerValue(await _token(auth, request.accountId)),
      );
    }
    if (request.idempotencyKey case final key?) {
      _setHeader(headers, idempotencyHeader, key);
    }

    final timeout = request.timeout ?? defaultTimeout;
    final cancelToken = CancelToken();
    _inFlight.add(cancelToken);
    try {
      final response = await _dio.request<String>(
        request.path,
        data: request.body,
        queryParameters: request.queryParameters,
        cancelToken: cancelToken,
        options: Options(
          method: request.method.name.toUpperCase(),
          headers: headers,
          contentType: request.body == null ? null : Headers.jsonContentType,
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
          connectTimeout: timeout,
          sendTimeout: request.body == null ? null : timeout,
          receiveTimeout: timeout,
        ),
      );
      return _toSyncResponse(response);
    } on DioException catch (error) {
      throw _toTransportException(error);
    } finally {
      _inFlight.remove(cancelToken);
    }
  }

  Future<String> _token(SyncAuthentication auth, String accountId) async {
    final String? token;
    try {
      token = await auth.accessToken(accountId);
    } on Exception catch (error) {
      throw SyncTransportException(
        'Could not obtain credentials for the account.',
        category: SyncErrorCategory.authentication,
        cause: error,
      );
    }
    if (token == null || token.isEmpty) {
      throw const SyncTransportException(
        'No credentials are available for the account.',
        category: SyncErrorCategory.authentication,
      );
    }
    return token;
  }

  // Concurrent 401s for one account share a single refresh.
  Future<bool> _refresh(String accountId, SyncTokenRefresher refresh) {
    return _refreshing[accountId] ??= Future(() async {
      try {
        return await refresh(accountId);
      } on Exception {
        return false;
      }
    }).whenComplete(() {
      // A block body: returning the removed future from whenComplete would
      // make this future wait on itself.
      _refreshing.remove(accountId);
    });
  }

  SyncResponse _toSyncResponse(Response<String> response) {
    final headers = <String, String>{
      for (final MapEntry(:key, :value) in response.headers.map.entries)
        key.toLowerCase(): value.join(', '),
    };
    return SyncResponse(
      statusCode: response.statusCode ?? 0,
      headers: headers,
      body: _decodeBody(response.data, headers['content-type']),
      serverRequestId: headers[requestIdHeader.toLowerCase()],
      serverVersion: headers[versionHeader.toLowerCase()],
    );
  }

  // JSON bodies are decoded; anything else (or malformed JSON) is kept as
  // text so the engine still sees the status code.
  static Object? _decodeBody(String? raw, String? contentType) {
    if (raw == null || raw.isEmpty) return null;
    if (contentType == null || !contentType.toLowerCase().contains('json')) {
      return raw;
    }
    try {
      return jsonDecode(raw);
    } on FormatException {
      return raw;
    }
  }

  // Messages are fixed and safe. The cause is the low-level error (such as a
  // SocketException), never the DioException, whose request options carry the
  // request headers, including credentials.
  static SyncTransportException _toTransportException(DioException error) {
    final (message, category) = switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout =>
        ('The request timed out.', SyncErrorCategory.timeout),
      DioExceptionType.connectionError => (
          'Could not connect to the server.',
          SyncErrorCategory.network,
        ),
      DioExceptionType.cancel => (
          'The request was cancelled.',
          SyncErrorCategory.network,
        ),
      DioExceptionType.badCertificate => (
          'The server certificate was rejected.',
          SyncErrorCategory.network,
        ),
      _ => ('The request failed.', SyncErrorCategory.unknown),
    };
    return SyncTransportException(
      message,
      category: category,
      cause: error.error ?? error.type,
    );
  }

  static void _setHeader(
      Map<String, Object> headers, String name, String value) {
    headers.removeWhere((key, _) => key.toLowerCase() == name.toLowerCase());
    headers[name] = value;
  }
}
