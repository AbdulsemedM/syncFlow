import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// A request as seen by the fake server.
final class RecordedRequest {
  RecordedRequest(this.options, this.body);

  final RequestOptions options;
  final String? body;

  String get method => options.method;
  Uri get uri => options.uri;

  /// Header value by case-insensitive name.
  String? header(String name) {
    for (final MapEntry(:key, :value) in options.headers.entries) {
      if (key.toLowerCase() == name.toLowerCase()) return '$value';
    }
    return null;
  }
}

typedef FakeHandler = Future<ResponseBody> Function(
  RecordedRequest request,
  Future<void>? cancelFuture,
);

/// A scriptable [HttpClientAdapter]: no sockets, full control over responses
/// and failures.
final class FakeAdapter implements HttpClientAdapter {
  FakeAdapter([FakeHandler? handler]) : handler = handler ?? ok();

  FakeHandler handler;
  final List<RecordedRequest> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = requestStream == null
        ? null
        : utf8.decode(await requestStream.expand((chunk) => chunk).toList());
    final request = RecordedRequest(options, body);
    requests.add(request);
    return handler(request, cancelFuture);
  }

  @override
  void close({bool force = false}) {}
}

/// Responds with [status], an optional JSON [body] and extra [headers].
FakeHandler ok({
  int status = 200,
  Object? body,
  Map<String, List<String>> headers = const {},
}) =>
    (_, __) async => respond(status: status, body: body, headers: headers);

ResponseBody respond({
  int status = 200,
  Object? body,
  String? rawBody,
  Map<String, List<String>> headers = const {},
}) =>
    ResponseBody.fromString(
      rawBody ?? (body == null ? '' : jsonEncode(body)),
      status,
      headers: {
        if (body != null || rawBody != null)
          Headers.contentTypeHeader: [Headers.jsonContentType],
        ...headers,
      },
    );

/// Fails like Dio does for the given [type].
FakeHandler failWith(DioExceptionType type, {Object? error}) =>
    (request, _) async => throw DioException(
          requestOptions: request.options,
          type: type,
          error: error,
        );
