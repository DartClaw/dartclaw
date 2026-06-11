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
