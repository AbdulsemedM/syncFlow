import 'package:syncflow/syncflow.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 6, 1, 12);
  const classifier = HttpResponseClassifier();

  DeliveryOutcome classify(int status,
          {Map<String, String> headers = const {}}) =>
      classifier.classifyResponse(
        SyncResponse(statusCode: status, headers: headers),
        operationId: 'op-1',
        now: now,
      );

  SyncError? errorOf(DeliveryOutcome outcome) => switch (outcome) {
        DeliverySucceeded() => null,
        DeliveryRetryable(:final error) => error,
        DeliveryUnauthenticated(:final error) => error,
        DeliveryRejected(:final error) => error,
        DeliveryConflicted(:final error) => error,
      };

  group('HttpResponseClassifier.classifyResponse', () {
    final expectations = <int, (Type, SyncErrorCategory?)>{
      200: (DeliverySucceeded, null),
      201: (DeliverySucceeded, null),
      204: (DeliverySucceeded, null),
      400: (DeliveryRejected, SyncErrorCategory.validation),
      401: (DeliveryUnauthenticated, SyncErrorCategory.authentication),
      403: (DeliveryRejected, SyncErrorCategory.authorization),
      404: (DeliveryRejected, SyncErrorCategory.protocol),
      408: (DeliveryRetryable, SyncErrorCategory.timeout),
      409: (DeliveryConflicted, SyncErrorCategory.conflict),
      412: (DeliveryConflicted, SyncErrorCategory.conflict),
      422: (DeliveryRejected, SyncErrorCategory.validation),
      429: (DeliveryRetryable, SyncErrorCategory.server),
      500: (DeliveryRetryable, SyncErrorCategory.server),
      502: (DeliveryRetryable, SyncErrorCategory.server),
      503: (DeliveryRetryable, SyncErrorCategory.server),
      302: (DeliveryRetryable, SyncErrorCategory.protocol),
      102: (DeliveryRetryable, SyncErrorCategory.protocol),
    };

    for (final MapEntry(key: status, value: (type, category))
        in expectations.entries) {
      test('$status -> $type', () {
        final outcome = classify(status);
        expect(outcome.runtimeType, type);
        final error = errorOf(outcome);
        expect(error?.category, category);
        if (error != null) {
          expect(error.httpStatus, status);
          expect(error.operationId, 'op-1');
          expect(error.occurredAt, now);
          expect(
            error.isRetryable,
            outcome is DeliveryRetryable || outcome is DeliveryUnauthenticated,
          );
        }
      });
    }

    test('parses Retry-After for 429 and 503', () {
      final rateLimited = classify(429, headers: {'Retry-After': '30'});
      final unavailable = classify(
        503,
        headers: {'retry-after': 'Mon, 01 Jun 2026 12:02:00 GMT'},
      );

      expect(
        (rateLimited as DeliveryRetryable).retryAfter,
        const Duration(seconds: 30),
      );
      expect(
        (unavailable as DeliveryRetryable).retryAfter,
        const Duration(minutes: 2),
      );
      expect((classify(503) as DeliveryRetryable).retryAfter, isNull);
    });

    test('reads the server request id from the configured header', () {
      final outcome = classify(500, headers: {'X-Request-Id': 'req-77'});
      expect(errorOf(outcome)!.serverRequestId, 'req-77');
    });

    test('never includes the response body in error messages', () {
      final outcome = classifier.classifyResponse(
        SyncResponse(statusCode: 422, body: {'email': 'secret@example.com'}),
        operationId: 'op-1',
        now: now,
      );
      expect(errorOf(outcome)!.message, isNot(contains('secret')));
    });
  });

  group('HttpResponseClassifier.classifyTransportException', () {
    DeliveryOutcome classifyFailure(SyncErrorCategory category) =>
        classifier.classifyTransportException(
          SyncTransportException('failed', category: category),
          operationId: 'op-1',
          now: now,
        );

    test('network, timeout, server and unknown failures are retryable', () {
      for (final category in [
        SyncErrorCategory.network,
        SyncErrorCategory.timeout,
        SyncErrorCategory.server,
        SyncErrorCategory.unknown,
      ]) {
        final outcome = classifyFailure(category);
        expect(outcome, isA<DeliveryRetryable>(), reason: category.name);
        expect(errorOf(outcome)!.category, category);
      }
    });

    test('authentication failures pause the account', () {
      expect(
        classifyFailure(SyncErrorCategory.authentication),
        isA<DeliveryUnauthenticated>(),
      );
    });

    test('other failures are rejected', () {
      expect(
        classifyFailure(SyncErrorCategory.serialization),
        isA<DeliveryRejected>(),
      );
    });
  });

  group('parseRetryAfter', () {
    test('parses delta seconds', () {
      expect(parseRetryAfter('120', now: now), const Duration(seconds: 120));
      expect(parseRetryAfter(' 5 ', now: now), const Duration(seconds: 5));
      expect(parseRetryAfter('0', now: now), Duration.zero);
    });

    test('parses HTTP dates relative to now', () {
      expect(
        parseRetryAfter('Mon, 01 Jun 2026 12:00:45 GMT', now: now),
        const Duration(seconds: 45),
      );
      expect(
        parseRetryAfter('Mon, 01 Jun 2026 11:00:00 GMT', now: now),
        Duration.zero,
        reason: 'dates in the past mean "retry now"',
      );
    });

    test('returns null for absent or invalid values', () {
      for (final value in [
        null,
        '',
        '-1',
        '1.5',
        'soon',
        'Mon, 31 Feb 2026 12:00:00 GMT',
        'Mon, 01 Foo 2026 12:00:00 GMT',
        '2026-06-01T12:00:00Z',
      ]) {
        expect(parseRetryAfter(value, now: now), isNull, reason: '$value');
      }
    });

    test('parseHttpDate handles the RFC example', () {
      expect(
        parseHttpDate('Sun, 06 Nov 1994 08:49:37 GMT'),
        DateTime.utc(1994, 11, 6, 8, 49, 37),
      );
    });
  });
}
