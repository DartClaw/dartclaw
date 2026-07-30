import 'dart:convert';

export 'package:dartclaw_core/dartclaw_core.dart' show truncate;

/// Formats [seconds] into a human-readable uptime string like "3d 14h 22m".
String formatUptime(int seconds) {
  final d = seconds ~/ 86400;
  final h = (seconds % 86400) ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (d > 0) return '${d}d ${h}h ${m}m';
  if (h > 0) return '${h}h ${m}m';
  return '${m}m';
}

/// Formats [bytes] into a human-readable size string.
String formatBytes(int bytes) {
  if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '$bytes B';
}

/// Capitalizes the first character of [s].
String titleCase(String s) {
  if (s.isEmpty) return s;
  return s[0].toUpperCase() + s.substring(1);
}

const _shortMonths = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// The one timestamp format in the product.
///
/// Relative ("just now", "3h ago", "12d ago") through 30 elapsed days, then an
/// absolute short date in server-local time: `d MMM` inside the current local
/// calendar year, `d MMM yyyy` outside it. Past a month the elapsed count stops
/// being something a reader can place — "347d ago" is a subtraction problem,
/// not a date.
///
/// Pair every rendering with `title="<ISO>"` (see [isoTitle]) so the exact
/// instant stays available without putting it on screen.
String formatRelativeTime(DateTime dateTime) {
  final local = dateTime.toLocal();
  final now = DateTime.now();
  final diff = now.difference(local);
  if (diff.inDays > 30) {
    final date = '${local.day} ${_shortMonths[local.month - 1]}';
    return local.year == now.year ? date : '$date ${local.year}';
  }
  if (diff.inDays > 0) return '${diff.inDays}d ago';
  if (diff.inHours > 0) return '${diff.inHours}h ago';
  if (diff.inMinutes > 0) return '${diff.inMinutes}m ago';
  return 'just now';
}

/// [formatRelativeTime] over an ISO-8601 string, returning `''` for a null or
/// unparseable input so a template can render the absent treatment instead.
String formatRelativeTimeIso(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  final parsed = DateTime.tryParse(iso);
  return parsed == null ? '' : formatRelativeTime(parsed);
}

/// Time *remaining* until [iso], e.g. `in 4m`.
///
/// The counterpart to [formatRelativeTimeIso], which is past-only: every one of
/// its branches needs a positive elapsed duration, so a future instant would
/// collapse to `just now`. Returns `''` for a null, unparseable or already-past
/// input so a template can omit the slot rather than report a deadline that has
/// gone by as if it were still ahead.
String formatRemainingTimeIso(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return '';
  final remaining = parsed.toLocal().difference(DateTime.now());
  if (remaining.isNegative) return '';
  // Truncated toward zero, so the panel never claims more time than is left: for
  // a deadline, overstating is the harmful direction. Sub-minute remainders get
  // a determinate phrase rather than "in 0m".
  if (remaining.inDays > 0) return 'in ${remaining.inDays}d';
  if (remaining.inHours > 0) return 'in ${remaining.inHours}h';
  if (remaining.inMinutes > 0) return 'in ${remaining.inMinutes}m';
  return 'in under a minute';
}

/// The `title` disclosure paired with a formatted timestamp: the source ISO
/// value, or null when there is nothing to disclose (so `tl:attr` omits it).
String? isoTitle(String? iso) => (iso == null || iso.isEmpty || DateTime.tryParse(iso) == null) ? null : iso;

/// The one absent-value convention: splits a field into "is there a value" and
/// "the value", so a template can render canon's `.value-absent` for the first
/// case and the untouched value for the second.
///
/// Only `null` and `''` are absent. A legitimate `0`, `'0'` or `false` is a
/// value and is preserved unchanged — collapsing those into a dash reports
/// "unknown" for something the system knows exactly.
///
/// Replaces the four ad-hoc stand-ins the product had grown (`—`, `--`, `N/A`,
/// `unknown`), none of which distinguished "no value" from "the value is zero".
({bool isAbsent, Object? value}) absentValue(Object? value) {
  final absent = value == null || (value is String && value.isEmpty);
  return (isAbsent: absent, value: absent ? null : value);
}

/// Formats [n] with thousands separators (e.g., 1234567 -> "1,234,567").
String formatNumber(int n) {
  final s = n.toString();
  final buffer = StringBuffer();
  final offset = s.length % 3;
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (i - offset) % 3 == 0) buffer.write(',');
    buffer.write(s[i]);
  }
  return buffer.toString();
}

/// Escapes HTML special characters in [s].
String escapeHtml(String s) => const HtmlEscape().convert(s);
