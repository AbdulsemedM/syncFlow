import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:syncflow/syncflow.dart';
import 'package:syncflow_dio/syncflow_dio.dart';
import 'package:test/test.dart';

import 'fake_adapter.dart';

void main() {
  late FakeAdapter adapter;
  late Dio dio;

  setUp(() {
    adapter = FakeAdapter();
    dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
      ..httpClientAdapter = adapter;
  });

  SyncRequest request({
    SyncHttpMethod method = SyncHttpMethod.post,
    String path = '/customers',
    String accountId = 'account-a',
    Map<String, String> headers = const {},
    Map<String, Object?> query = const {},
    Object? body = const {'name': 'Ada'},
    Duration? timeout,
    String? idempotencyKey = 'idem-1',
  }) =>
      SyncRequest(
        method: method,
        path: path,
        accountId: accountId,
        headers: headers,
        queryParameters: query,
        body: body,
        timeout: timeout,
        idempotencyKey: idempotencyKey,
        operationId: 'op-1',
      );

  group('request mapping', () {
    test('sends method, URL, query, JSON body and idempotency key', () async {
      final transport = DioSyncTransport(dio: dio);

      await transport.send(
        request(
          method: SyncHttpMethod.put,
          path: '/customers/c-1',
          query: {'expand': 'address'},
          headers: {'X-Trace': 'abc'},
        ),
      );

      final sent = adapter.requests.single;
      expect(sent.method, 'PUT');
      expect(
        sent.uri.toString(),
        'https://api.example.test/v1/customers/c-1?expand=address',
      );
      expect(jsonDecode(sent.body!), {'name': 'Ada'});
      expect(sent.header('content-type'), startsWith('application/json'));
      expect(sent.header('Idempotency-Key'), 'idem-1');
      expect(sent.header('X-Trace'), 'abc');
    });

    test('the operation idempotency key overrides builder headers', () async {
      final transport = DioSyncTransport(dio: dio);

      for (final name in ['Idempotency-Key', 'idempotency-key']) {
        adapter.requests.clear();
        await transport.send(request(headers: {name: 'from-builder'}));

        final sent = adapter.requests.single;
        expect(sent.header('Idempotency-Key'), 'idem-1', reason: name);
        expect(
          sent.options.headers.keys
              .where((k) => k.toLowerCase() == 'idempotency-key'),
          hasLength(1),
          reason: name,
        );
      }
    });

    test('supports a custom idempotency header and no body', () async {
      final transport =
          DioSyncTransport(dio: dio, idempotencyHeader: 'X-Request-Key');

      await transport.send(
        request(method: SyncHttpMethod.delete, body: null),
      );

      final sent = adapter.requests.single;
      expect(sent.method, 'DELETE');
      expect(sent.body, isNull);
      expect(sent.header('X-Request-Key'), 'idem-1');
      expect(sent.header('Idempotency-Key'), isNull);
    });

    test('applies the request timeout, falling back to the default', () async {
      final transport = DioSyncTransport(
        dio: dio,
        defaultTimeout: const Duration(seconds: 20),
      );

      await transport.send(request(timeout: const Duration(seconds: 5)));
      await transport.send(request());

      expect(adapter.requests[0].options.receiveTimeout,
          const Duration(seconds: 5));
      expect(adapter.requests[0].options.connectTimeout,
          const Duration(seconds: 5));
      expect(adapter.requests[1].options.receiveTimeout,
          const Duration(seconds: 20));
    });
  });

  group('response mapping', () {
    test('returns every status as a response instead of throwing', () async {
      final transport = DioSyncTransport(dio: dio);

      for (final status in [201, 204, 400, 401, 404, 409, 422, 500, 503]) {
        adapter.handler = ok(status: status);
        expect((await transport.send(request())).statusCode, status);
      }
    });

    test('normalizes headers and extracts request id and version', () async {
      adapter.handler = ok(
        body: {'id': 'srv-1'},
        headers: {
          'X-Request-Id': ['req-42'],
          'ETag': ['"v7"'],
          'Retry-After': ['30'],
          'Vary': ['Accept', 'Origin'],
        },
      );
      final transport = DioSyncTransport(dio: dio);

      final response = await transport.send(request());

      expect(response.body, {'id': 'srv-1'});
      expect(response.serverRequestId, 'req-42');
      expect(response.serverVersion, '"v7"');
      expect(response.header('retry-after'), '30');
      expect(response.headers['vary'], 'Accept, Origin');
    });

    test('keeps malformed or non-JSON bodies as text', () async {
      final transport = DioSyncTransport(dio: dio);

      adapter.handler = (_, __) async => respond(status: 502, rawBody: '<html');
      expect((await transport.send(request())).body, '<html');

      adapter.handler = (_, __) async => ResponseBody.fromString(
            'plain text',
            200,
            headers: {
              Headers.contentTypeHeader: ['text/plain'],
            },
          );
      expect((await transport.send(request())).body, 'plain text');

      adapter.handler = ok(status: 204);
      expect((await transport.send(request())).body, isNull);
    });
  });

  group('authentication', () {
    test('sends the token of the request account', () async {
      final transport = DioSyncTransport(
        dio: dio,
        authentication: SyncAuthentication(
          accessToken: (accountId) => 'token-of-$accountId',
        ),
      );

      await transport.send(request(accountId: 'account-a'));
      await transport.send(request(accountId: 'account-b'));

      expect(adapter.requests[0].header('Authorization'),
          'Bearer token-of-account-a');
      expect(adapter.requests[1].header('Authorization'),
          'Bearer token-of-account-b');
    });

    test('the provided token overrides builder headers', () async {
      final transport = DioSyncTransport(
        dio: dio,
        authentication: SyncAuthentication(accessToken: (_) => 'real'),
      );

      for (final name in ['Authorization', 'authorization']) {
        adapter.requests.clear();
        await transport.send(request(headers: {name: 'Bearer stale'}));

        expect(
          adapter.requests.single.header('Authorization'),
          'Bearer real',
          reason: name,
        );
      }
    });

    test('supports custom header names and raw tokens', () async {
      final transport = DioSyncTransport(
        dio: dio,
        authentication: SyncAuthentication(
          accessToken: (_) => 'k-123',
          headerName: 'X-Api-Key',
          scheme: '',
        ),
      );

      await transport.send(request());

      expect(adapter.requests.single.header('X-Api-Key'), 'k-123');
      expect(adapter.requests.single.header('Authorization'), isNull);
    });

    test('missing credentials fail as authentication without sending',
        () async {
      final transport = DioSyncTransport(
        dio: dio,
        authentication: SyncAuthentication(accessToken: (_) => null),
      );

      await expectLater(
        transport.send(request()),
        throwsA(
          isA<SyncTransportException>().having(
            (e) => e.category,
            'category',
            SyncErrorCategory.authentication,
          ),
        ),
      );
      expect(adapter.requests, isEmpty);
    });

    test('a failing token provider fails as authentication', () async {
      final transport = DioSyncTransport(
        dio: dio,
        authentication: SyncAuthentication(
          accessToken: (_) => throw const FormatException('keychain locked'),
        ),
      );

      await expectLater(
        transport.send(request()),
        throwsA(
          isA<SyncTransportException>()
              .having((e) => e.category, 'category',
                  SyncErrorCategory.authentication)
              .having((e) => e.message, 'message', isNot(contains('keychain'))),
        ),
      );
    });

    test('401 refreshes once and retries with the same idempotency key',
        () async {
      var token = 'expired';
      var refreshes = 0;
      final transport = DioSyncTransport(
        dio: dio,
        authentication: SyncAuthentication(
          accessToken: (_) => token,
          refresh: (_) {
            refreshes++;
            token = 'fresh';
            return true;
          },
        ),
      );
      adapter.handler = (request, _) async => respond(
            status:
                request.header('Authorization') == 'Bearer fresh' ? 200 : 401,
          );

      final response = await transport.send(request());

      expect(response.statusCode, 200);
      expect(refreshes, 1);
      expect(adapter.requests.map((r) => r.header('Authorization')),
          ['Bearer expired', 'Bearer fresh']);
      expect(adapter.requests.map((r) => r.header('Idempotency-Key')).toSet(),
          {'idem-1'});
    });

    test('returns the 401 when refresh fails, throws or still gets 401',
        () async {
      for (final refresh in <SyncTokenRefresher>[
        (_) => false,
        (_) => throw const FormatException('refresh endpoint down'),
        (_) => true,
      ]) {
        adapter
          ..requests.clear()
          ..handler = ok(status: 401);
        final transport = DioSyncTransport(
          dio: dio,
          authentication: SyncAuthentication(
            accessToken: (_) => 't',
            refresh: (accountId) => refresh(accountId),
          ),
        );

        final response = await transport.send(request());

        expect(response.statusCode, 401);
        expect(adapter.requests.length, lessThanOrEqualTo(2));
      }
    });

    test('concurrent 401s for one account share a single refresh', () async {
      var token = 'expired';
      var refreshes = 0;
      final gate = Completer<void>();
      final transport = DioSyncTransport(
        dio: dio,
        authentication: SyncAuthentication(
          accessToken: (_) => token,
          refresh: (_) async {
            refreshes++;
            await gate.future;
            token = 'fresh';
            return true;
          },
        ),
      );
      adapter.handler = (request, _) async => respond(
            status:
                request.header('Authorization') == 'Bearer fresh' ? 200 : 401,
          );

      final responses = Future.wait([
        for (var i = 0; i < 3; i++) transport.send(request()),
      ]);
      await pumpEventQueue();
      gate.complete();

      expect((await responses).map((r) => r.statusCode), [200, 200, 200]);
      expect(refreshes, 1);
    });
  });

  group('failures', () {
    Future<SyncTransportException> failure(FakeHandler handler) async {
      adapter.handler = handler;
      final transport = DioSyncTransport(
        dio: dio,
        authentication: SyncAuthentication(accessToken: (_) => 'secret-token'),
      );
      try {
        await transport.send(request());
      } on SyncTransportException catch (error) {
        return error;
      }
      throw StateError('expected a SyncTransportException');
    }

    test('maps Dio failures to retryable categories', () async {
      final expectations = {
        DioExceptionType.connectionTimeout: SyncErrorCategory.timeout,
        DioExceptionType.sendTimeout: SyncErrorCategory.timeout,
        DioExceptionType.receiveTimeout: SyncErrorCategory.timeout,
        DioExceptionType.connectionError: SyncErrorCategory.network,
        DioExceptionType.badCertificate: SyncErrorCategory.network,
        DioExceptionType.cancel: SyncErrorCategory.network,
        DioExceptionType.unknown: SyncErrorCategory.unknown,
      };

      for (final MapEntry(key: type, value: category) in expectations.entries) {
        final error = await failure(failWith(type));
        expect(error.category, category, reason: type.name);
      }
    });

    test('never exposes credentials through the exception', () async {
      final error = await failure(
        failWith(
          DioExceptionType.connectionError,
          error: const FormatException('socket closed'),
        ),
      );

      expect(error.toString(), isNot(contains('secret-token')));
      expect(error.cause, isNot(isA<DioException>()));
      expect(error.cause, isA<FormatException>());
    });
  });

  group('lifecycle', () {
    test('close cancels in-flight requests as retryable failures', () async {
      adapter.handler = (_, __) => Completer<ResponseBody>().future;
      final transport = DioSyncTransport(dio: dio);

      final pending = transport.send(request());
      await pumpEventQueue();
      await transport.close();

      await expectLater(
        pending,
        throwsA(
          isA<SyncTransportException>().having(
            (e) => e.category,
            'category',
            SyncErrorCategory.network,
          ),
        ),
      );
      expect(() => transport.send(request()), throwsStateError);
    });

    test('closes Dio only when it owns it', () async {
      final shared = DioSyncTransport(dio: dio);
      await shared.close();
      await dio.get<void>('/still-open');

      final owned = DioSyncTransport(dio: dio, closeDio: true);
      await owned.close();
      expect(() => dio.get<void>('/closed'), throwsA(isA<Object>()));
    });
  });
}
