@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:syncflow/syncflow.dart';
import 'package:syncflow_dio/syncflow_dio.dart';
import 'package:test/test.dart';

/// Exercises the transport over real sockets against a local HTTP server.
void main() {
  late HttpServer server;
  late List<HttpRequest> received;
  late List<String> bodies;
  late Future<void> Function(HttpRequest request) handler;
  late DioSyncTransport transport;

  setUp(() async {
    received = [];
    bodies = [];
    handler = (request) async {
      request.response.statusCode = 201;
      request.response.headers
        ..contentType = ContentType.json
        ..set('x-request-id', 'req-1');
      request.response.write(jsonEncode({'ok': true}));
    };
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      received.add(request);
      bodies.add(await utf8.decoder.bind(request).join());
      await handler(request);
      await request.response.close();
    });
    transport = DioSyncTransport(
      dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}')),
      authentication: SyncAuthentication(accessToken: (_) => 'secret'),
      closeDio: true,
    );
  });

  tearDown(() async {
    await transport.close();
    await server.close(force: true);
  });

  SyncRequest request({Duration? timeout}) => SyncRequest(
        method: SyncHttpMethod.post,
        path: '/customers',
        accountId: 'account-a',
        body: const {'name': 'Ada'},
        idempotencyKey: 'idem-1',
        timeout: timeout,
      );

  test('sends headers and JSON over the wire', () async {
    final response = await transport.send(request());

    expect(response.statusCode, 201);
    expect(response.body, {'ok': true});
    expect(response.serverRequestId, 'req-1');
    final sent = received.single;
    expect(sent.method, 'POST');
    expect(sent.uri.path, '/customers');
    expect(sent.headers.value('idempotency-key'), 'idem-1');
    expect(sent.headers.value('authorization'), 'Bearer secret');
    expect(jsonDecode(bodies.single), {'name': 'Ada'});
  });

  test('a slow server times out as a retryable timeout', () async {
    handler =
        (request) => Future<void>.delayed(const Duration(milliseconds: 600));

    await expectLater(
      transport.send(request(timeout: const Duration(milliseconds: 150))),
      throwsA(
        isA<SyncTransportException>().having(
          (e) => e.category,
          'category',
          SyncErrorCategory.timeout,
        ),
      ),
    );
  });

  test('an unreachable server fails as a network error', () async {
    final port = server.port;
    await server.close(force: true);
    final unreachable = DioSyncTransport(
      dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:$port')),
      closeDio: true,
    );
    addTearDown(unreachable.close);

    await expectLater(
      unreachable.send(request()),
      throwsA(
        isA<SyncTransportException>().having(
          (e) => e.category,
          'category',
          SyncErrorCategory.network,
        ),
      ),
    );
  });
}
