/// Source of the current time. Injected so behavior is deterministic in tests.
abstract interface class Clock {
  /// The current time, in UTC.
  DateTime now();
}

/// A [Clock] backed by the system clock.
final class SystemClock implements Clock {
  /// Creates a system clock.
  const SystemClock();

  @override
  DateTime now() => DateTime.now().toUtc();
}
