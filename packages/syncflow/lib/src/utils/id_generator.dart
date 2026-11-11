import 'dart:math';

/// Generates unique identifiers for operations and idempotency keys.
abstract interface class IdGenerator {
  /// Returns a new identifier, unique for the lifetime of the data set.
  String next();
}

/// Generates random (version 4) UUIDs using a cryptographically secure source.
final class UuidV4Generator implements IdGenerator {
  /// Creates a generator.
  const UuidV4Generator();

  static final Random _random = Random.secure();

  @override
  String next() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
