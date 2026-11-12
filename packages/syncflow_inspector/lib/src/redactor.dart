/// Removes sensitive values from payloads before they are displayed or
/// exported.
///
/// Keys are compared after normalization: lower case, with `_`, `-`, `.` and
/// spaces removed, so `access_token`, `accessToken` and `Access-Token` are the
/// same key. A key is sensitive when its normalized form is in [keys], or
/// contains one of [keyFragments]. Values under a sensitive key are replaced by
/// [replacement], whatever their type, including nested maps and lists.
///
/// Redaction is best effort: it only knows the keys it is told about. Treat
/// every diagnostic export as sensitive, even after redaction.
final class SyncRedactor {
  /// Creates a redactor.
  ///
  /// With [maskAllValues], every leaf value is replaced by a type placeholder
  /// (`<string>`, `<number>`, ...) and only the payload's shape remains.
  const SyncRedactor({
    this.keys = defaultKeys,
    this.keyFragments = defaultKeyFragments,
    this.maskAllValues = false,
    this.replacement = '[REDACTED]',
  });

  /// Normalized keys that are always sensitive.
  static const Set<String> defaultKeys = {
    'pin',
    'cvv',
    'cvc',
    'ssn',
    'cookie',
    'iban',
    'cardnumber',
    'pan',
  };

  /// Normalized key fragments that make a key sensitive, for example
  /// `password` in `newPassword`.
  static const Set<String> defaultKeyFragments = {
    'password',
    'passcode',
    'secret',
    'token',
    'apikey',
    'authorization',
    'credential',
    'privatekey',
  };

  /// Normalized sensitive keys.
  final Set<String> keys;

  /// Normalized fragments that make a key sensitive.
  final Set<String> keyFragments;

  /// Whether every leaf value is masked, keeping only the structure.
  final bool maskAllValues;

  /// Text that replaces a sensitive value.
  final String replacement;

  /// Returns a redactor that also treats [extraKeys] as sensitive.
  SyncRedactor withKeys(Iterable<String> extraKeys) => SyncRedactor(
        keys: {...keys, for (final key in extraKeys) normalizeKey(key)},
        keyFragments: keyFragments,
        maskAllValues: maskAllValues,
        replacement: replacement,
      );

  /// Normalizes [key] for comparison.
  static String normalizeKey(String key) =>
      key.toLowerCase().replaceAll(RegExp(r'[\s_\-.]'), '');

  /// Whether values stored under [key] are sensitive.
  bool isSensitiveKey(String key) {
    final normalized = normalizeKey(key);
    return keys.contains(normalized) ||
        keyFragments.any((fragment) => normalized.contains(fragment));
  }

  /// Returns a redacted copy of [payload]. The input is not modified.
  Map<String, Object?> redactMap(Map<String, Object?> payload) => {
        for (final MapEntry(:key, :value) in payload.entries)
          key: isSensitiveKey(key) ? replacement : redact(value),
      };

  /// Returns a redacted copy of [value]: maps and lists are redacted
  /// recursively, other values are kept unless [maskAllValues] is set.
  Object? redact(Object? value) => switch (value) {
        final Map<String, Object?> map => redactMap(map),
        final Map<Object?, Object?> map => {
            for (final MapEntry(:key, :value) in map.entries)
              '$key': isSensitiveKey('$key') ? replacement : redact(value),
          },
        final List<Object?> list => [for (final item in list) redact(item)],
        _ when !maskAllValues || value == null => value,
        String() => '<string>',
        num() => '<number>',
        bool() => '<bool>',
        _ => '<value>',
      };

  /// Masks an identifier such as an idempotency key, keeping its last four
  /// characters so it can still be matched against server logs.
  static String maskIdentifier(String value) {
    if (value.length <= 4) return '••••';
    return '••••${value.substring(value.length - 4)}';
  }
}
