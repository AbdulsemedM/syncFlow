import 'dart:math';

import 'package:syncflow/syncflow.dart';
import 'package:test/test.dart';

/// A [Random] whose [nextDouble] always returns [value].
final class _FixedRandom implements Random {
  _FixedRandom(this.value);

  final double value;

  @override
  double nextDouble() => value;

  @override
  bool nextBool() => throw UnimplementedError();

  @override
  int nextInt(int max) => throw UnimplementedError();
}

void main() {
  final error = SyncError(
    category: SyncErrorCategory.server,
    message: 'HTTP 503',
    isRetryable: true,
    occurredAt: DateTime.utc(2026),
  );

  group('ExponentialBackoffRetryPolicy', () {
    test('doubles the delay per attempt up to maxDelay', () {
      final policy = ExponentialBackoffRetryPolicy(
        baseDelay: const Duration(seconds: 1),
        maxDelay: const Duration(seconds: 30),
      );

      expect(
        [for (var n = 1; n <= 7; n++) policy.backoffFor(n).inSeconds],
        [1, 2, 4, 8, 16, 30, 30],
      );
    });

    test('does not overflow for very large attempt counts', () {
      final policy = ExponentialBackoffRetryPolicy();
      expect(policy.backoffFor(1000), policy.maxDelay);
      expect(policy.backoffFor(1 << 40), policy.maxDelay);
    });

    test('zero jitter returns the exact backoff', () {
      final policy = ExponentialBackoffRetryPolicy(jitter: 0);
      expect(
        policy.delayFor(attempts: 3, error: error),
        const Duration(seconds: 4),
      );
    });

    test('jitter shortens the delay by at most the jitter fraction', () {
      ExponentialBackoffRetryPolicy policy(double random) =>
          ExponentialBackoffRetryPolicy(
            jitter: 0.5,
            random: _FixedRandom(random),
          );

      expect(
        policy(0).delayFor(attempts: 3, error: error),
        const Duration(seconds: 4),
      );
      expect(
        policy(0.5).delayFor(attempts: 3, error: error),
        const Duration(seconds: 3),
      );
      expect(
        policy(0.999999).delayFor(attempts: 3, error: error)!.inMilliseconds,
        closeTo(2000, 1),
      );
    });

    test('jittered delays stay within bounds', () {
      final policy = ExponentialBackoffRetryPolicy(
        jitter: 0.3,
        random: Random(42),
      );
      final full = policy.backoffFor(4);
      final lower = full * 0.7;

      for (var i = 0; i < 1000; i++) {
        final delay = policy.delayFor(attempts: 4, error: error)!;
        expect(delay, greaterThanOrEqualTo(lower));
        expect(delay, lessThanOrEqualTo(full));
      }
    });

    test('honors Retry-After exactly, capped at maxRetryAfter', () {
      final policy = ExponentialBackoffRetryPolicy(
        maxRetryAfter: const Duration(minutes: 10),
        random: _FixedRandom(0.9),
      );

      expect(
        policy.delayFor(
          attempts: 1,
          error: error,
          retryAfter: const Duration(seconds: 90),
        ),
        const Duration(seconds: 90),
      );
      expect(
        policy.delayFor(
          attempts: 1,
          error: error,
          retryAfter: const Duration(hours: 5),
        ),
        const Duration(minutes: 10),
      );
      expect(
        policy.delayFor(
          attempts: 1,
          error: error,
          retryAfter: const Duration(seconds: -5),
        ),
        Duration.zero,
      );
    });

    test('stops after maxAttempts, even with Retry-After', () {
      final policy = ExponentialBackoffRetryPolicy(maxAttempts: 3);

      expect(policy.delayFor(attempts: 2, error: error), isNotNull);
      expect(policy.delayFor(attempts: 3, error: error), isNull);
      expect(
        policy.delayFor(
          attempts: 3,
          error: error,
          retryAfter: const Duration(seconds: 1),
        ),
        isNull,
      );
    });

    test('retries indefinitely by default', () {
      final policy = ExponentialBackoffRetryPolicy();
      expect(policy.delayFor(attempts: 10000, error: error), isNotNull);
    });

    test('rejects invalid configuration', () {
      expect(
        () => ExponentialBackoffRetryPolicy(baseDelay: Duration.zero),
        throwsArgumentError,
      );
      expect(
        () => ExponentialBackoffRetryPolicy(
          baseDelay: const Duration(seconds: 10),
          maxDelay: const Duration(seconds: 1),
        ),
        throwsArgumentError,
      );
      expect(
        () => ExponentialBackoffRetryPolicy(jitter: 1.5),
        throwsArgumentError,
      );
      expect(
        () => ExponentialBackoffRetryPolicy(maxAttempts: 0),
        throwsArgumentError,
      );
      expect(
        () =>
            ExponentialBackoffRetryPolicy().delayFor(attempts: 0, error: error),
        throwsArgumentError,
      );
    });
  });
}
