/// Formats [value] (a [DateTime], an ISO-8601 [String], or null) as
/// `yyyy-MM-dd HH:mm:ss` (or `yyyy-MM-dd HH:mm` when [seconds] is false).
///
/// - Strings are parsed with [DateTime.tryParse]; a [DateTime] is used directly.
/// - Returns [emptyPlaceholder] when [value] is null or an empty string.
/// - Returns the original string verbatim when a non-empty string fails to parse.
///
/// The parsed instant is rendered with its own time-zone fields (no conversion);
/// callers wanting local time must pass an already-local value.
String formatLocalDateTime(Object? value, {bool seconds = true, String emptyPlaceholder = '—'}) {
  final DateTime parsed;
  if (value is DateTime) {
    parsed = value;
  } else {
    final raw = value?.toString();
    if (raw == null || raw.isEmpty) {
      return emptyPlaceholder;
    }
    final tryParsed = DateTime.tryParse(raw);
    if (tryParsed == null) {
      return raw;
    }
    parsed = tryParsed;
  }

  final date =
      '${parsed.year.toString().padLeft(4, '0')}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')}';
  final time = '${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}';
  if (!seconds) {
    return '$date $time';
  }
  return '$date $time:${parsed.second.toString().padLeft(2, '0')}';
}

final _isoInstant = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})(?:$|[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,6}))?)?(Z|[+-]\d{2}:\d{2})$)',
);

/// Parses an ISO-8601 date or timestamp into a UTC instant, or `null` when
/// [value] is not one.
///
/// Accepts `yyyy-MM-dd` (that day's UTC midnight) and a date followed by
/// `HH:mm[:ss[.ffffff]]` with a mandatory `Z` or `±HH:mm` offset. A
/// calendar-invalid date, an out-of-range time field and an offsetless
/// timestamp read as `null`, so each caller maps it to its own error contract.
DateTime? tryParseIsoInstant(String value) {
  final trimmed = value.trim();
  final match = _isoInstant.firstMatch(trimmed);
  if (match == null) return null;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  // A rolled-over date is a rejected date: DateTime.utc normalizes 2026-02-30
  // to 2026-03-02, which is the value a quarantine contract must never see.
  final date = DateTime.utc(year, month, day);
  if (date.year != year || date.month != month || date.day != day) return null;
  if (match.group(4) == null) return date;
  final offset = match.group(8)!;
  if (int.parse(match.group(4)!) > 23 || int.parse(match.group(5)!) > 59 || int.parse(match.group(6) ?? '0') > 59) {
    return null;
  }
  if (offset != 'Z' && (int.parse(offset.substring(1, 3)) > 23 || int.parse(offset.substring(4, 6)) > 59)) return null;
  return DateTime.parse(trimmed).toUtc();
}
