import 'package:syncflow/syncflow.dart';

/// A [Clock] that only moves when told to.
final class FakeClock implements Clock {
  /// Creates a clock frozen at [initial] (default: 2026-01-01T00:00:00Z).
  FakeClock([DateTime? initial])
      : _now = (initial ?? DateTime.utc(2026)).toUtc();

  DateTime _now;

  @override
  DateTime now() => _now;

  /// Moves the clock forward by [duration].
  void advance(Duration duration) {
    if (duration.isNegative) {
      throw ArgumentError.value(duration, 'duration', 'must not be negative');
    }
    _now = _now.add(duration);
  }

  /// Sets the clock to [time]. Moving backwards is allowed, to simulate
  /// device clock changes.
  void setTo(DateTime time) => _now = time.toUtc();
}
