import 'dart:math';

import '../models/sync_error.dart';

/// Decides whether and when a failed delivery is attempted again.
abstract interface class RetryPolicy {
  /// Returns the delay before the next attempt, or `null` to stop retrying.
  ///
  /// [attempts] is the number of delivery attempts made so far (at least 1).
  /// [retryAfter] is the server-requested delay, if the response carried one.
  Duration? delayFor({
    required int attempts,
    required SyncError error,
    Duration? retryAfter,
  });
}

/// Exponential backoff with random jitter.
///
/// The base delay for attempt `n` is
/// `min(maxDelay, baseDelay * 2^(n - 1))`. Jitter then shortens it by a random
/// fraction of up to [jitter], so the final delay lies in
/// `[delay * (1 - jitter), delay]`. Spreading retries this way prevents many
/// clients from retrying in lockstep after an outage.
///
/// A server-provided `Retry-After` replaces the computed delay (without
/// jitter), capped at [maxRetryAfter].
final class ExponentialBackoffRetryPolicy implements RetryPolicy {
  /// Creates a policy. [maxAttempts] of `null` retries indefinitely, which
  /// suits offline-first apps whose devices can be offline for days.
  ExponentialBackoffRetryPolicy({
    this.baseDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(minutes: 5),
    this.jitter = 0.5,
    this.maxAttempts,
    this.maxRetryAfter = const Duration(hours: 1),
    Random? random,
  }) : _random = random ?? Random() {
    if (baseDelay <= Duration.zero) {
      throw ArgumentError.value(baseDelay, 'baseDelay', 'must be positive');
    }
    if (maxDelay < baseDelay) {
      throw ArgumentError.value(maxDelay, 'maxDelay', 'must be >= baseDelay');
    }
    if (jitter < 0 || jitter > 1) {
      throw ArgumentError.value(jitter, 'jitter', 'must be within [0, 1]');
    }
    if (maxAttempts case final max? when max < 1) {
      throw ArgumentError.value(max, 'maxAttempts', 'must be positive');
    }
    if (maxRetryAfter.isNegative) {
      throw ArgumentError.value(
        maxRetryAfter,
        'maxRetryAfter',
        'must not be negative',
      );
    }
  }

  /// Delay after the first failed attempt, before jitter.
  final Duration baseDelay;

  /// Upper bound for the computed delay, before jitter.
  final Duration maxDelay;

  /// Maximum fraction (0–1) by which a delay is randomly shortened.
  final double jitter;

  /// Total delivery attempts allowed, or `null` for no limit.
  final int? maxAttempts;

  /// Upper bound applied to server-provided `Retry-After` values.
  final Duration maxRetryAfter;

  final Random _random;

  @override
  Duration? delayFor({
    required int attempts,
    required SyncError error,
    Duration? retryAfter,
  }) {
    if (attempts < 1) {
      throw ArgumentError.value(attempts, 'attempts', 'must be positive');
    }
    if (maxAttempts case final max? when attempts >= max) return null;

    if (retryAfter != null) {
      if (retryAfter.isNegative) return Duration.zero;
      return retryAfter > maxRetryAfter ? maxRetryAfter : retryAfter;
    }

    final backoff = backoffFor(attempts);
    final factor = 1 - jitter * _random.nextDouble();
    return Duration(microseconds: (backoff.inMicroseconds * factor).round());
  }

  /// The capped exponential delay for [attempts], before jitter.
  Duration backoffFor(int attempts) {
    final exponent = min(attempts - 1, 62);
    final micros = baseDelay.inMicroseconds * pow(2, exponent).toDouble();
    final capped = min(micros, maxDelay.inMicroseconds.toDouble());
    return Duration(microseconds: capped.round());
  }
}
