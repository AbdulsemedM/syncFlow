// Internal helpers for strict decoding of persisted JSON records.
//
// Every failure is reported as a FormatException naming the offending field, so
// a corrupt record is surfaced explicitly rather than silently discarded.

/// Reads [key] from [json] and checks that it has type [T].
T readField<T>(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is T) return value;
  throw FormatException(
    'Invalid value for "$key": expected $T but found ${value.runtimeType}.',
  );
}

/// Reads a required ISO-8601 timestamp and normalizes it to UTC.
DateTime readDateTime(Map<String, Object?> json, String key) =>
    _parseDateTime(readField<String>(json, key), key);

/// Reads an optional ISO-8601 timestamp and normalizes it to UTC.
DateTime? readOptionalDateTime(Map<String, Object?> json, String key) {
  final value = readField<String?>(json, key);
  return value == null ? null : _parseDateTime(value, key);
}

/// Reads an enum value stored by its `name`.
T readEnum<T extends Enum>(
  Map<String, Object?> json,
  String key,
  List<T> values,
) {
  final name = readField<String>(json, key);
  for (final value in values) {
    if (value.name == name) return value;
  }
  throw FormatException('Unknown value for "$key".', name);
}

/// Reads a JSON object with string keys.
Map<String, Object?> readObject(Map<String, Object?> json, String key) {
  final value = readField<Map<Object?, Object?>>(json, key);
  return _toStringKeyedMap(value, key);
}

/// Reads an optional JSON object with string keys.
Map<String, Object?>? readOptionalObject(
  Map<String, Object?> json,
  String key,
) {
  final value = readField<Map<Object?, Object?>?>(json, key);
  return value == null ? null : _toStringKeyedMap(value, key);
}

/// Reads a list whose elements must all be strings.
List<String> readStringList(Map<String, Object?> json, String key) {
  final value = readField<List<Object?>>(json, key);
  return [
    for (final element in value)
      if (element is String)
        element
      else
        throw FormatException('Invalid element in "$key": expected String.'),
  ];
}

DateTime _parseDateTime(String value, String key) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throw FormatException('Invalid timestamp for "$key".', value);
  }
  return parsed.toUtc();
}

Map<String, Object?> _toStringKeyedMap(Map<Object?, Object?> map, String key) {
  final result = <String, Object?>{};
  for (final MapEntry(key: entryKey, :value) in map.entries) {
    if (entryKey is! String) {
      throw FormatException('Invalid key in "$key": expected String.');
    }
    result[entryKey] = value;
  }
  return result;
}
