/// Parses an HTTP `Retry-After` header value relative to [now].
///
/// Supports both forms defined by RFC 9110: a non-negative number of seconds
/// (`120`) and an IMF-fixdate (`Wed, 21 Oct 2026 07:28:00 GMT`). A date in the
/// past yields [Duration.zero]. Returns `null` for absent or unparseable
/// values.
Duration? parseRetryAfter(String? value, {required DateTime now}) {
  if (value == null) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;

  if (RegExp(r'^\d+$').hasMatch(trimmed)) {
    final seconds = int.tryParse(trimmed);
    return seconds == null ? null : Duration(seconds: seconds);
  }

  final date = parseHttpDate(trimmed);
  if (date == null) return null;
  final delay = date.difference(now.toUtc());
  return delay.isNegative ? Duration.zero : delay;
}

const _months = {
  'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6, //
  'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
};

final _imfFixdate = RegExp(
  r'^(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun), (\d{2}) ([A-Z][a-z]{2}) (\d{4}) '
  r'(\d{2}):(\d{2}):(\d{2}) GMT$',
);

/// Parses an RFC 9110 IMF-fixdate such as `Sun, 06 Nov 1994 08:49:37 GMT`.
///
/// Returns `null` if [value] is not a valid IMF-fixdate. Obsolete HTTP date
/// formats are not supported.
DateTime? parseHttpDate(String value) {
  final match = _imfFixdate.firstMatch(value);
  if (match == null) return null;
  final month = _months[match.group(2)];
  if (month == null) return null;

  final day = int.parse(match.group(1)!);
  final year = int.parse(match.group(3)!);
  final hour = int.parse(match.group(4)!);
  final minute = int.parse(match.group(5)!);
  final second = int.parse(match.group(6)!);

  final date = DateTime.utc(year, month, day, hour, minute, second);
  // DateTime normalizes overflow (e.g. 31 Feb); reject such inputs.
  final valid = date.year == year &&
      date.month == month &&
      date.day == day &&
      date.hour == hour &&
      date.minute == minute &&
      date.second == second;
  return valid ? date : null;
}
