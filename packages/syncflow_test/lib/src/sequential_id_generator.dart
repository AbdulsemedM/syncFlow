import 'package:syncflow/syncflow.dart';

/// An [IdGenerator] producing predictable IDs: `id-1`, `id-2`, ...
final class SequentialIdGenerator implements IdGenerator {
  /// Creates a generator whose IDs start with [prefix].
  SequentialIdGenerator({this.prefix = 'id'});

  /// Prefix of every generated identifier.
  final String prefix;

  int _counter = 0;

  @override
  String next() => '$prefix-${++_counter}';
}
