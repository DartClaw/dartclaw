import 'dart:convert';

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

/// Formats a [DateTime] as a relative time string (e.g., "3d ago", "just now").
String formatRelativeTime(DateTime dateTime) {
  final diff = DateTime.now().difference(dateTime);
  if (diff.inDays > 0) return '${diff.inDays}d ago';
  if (diff.inHours > 0) return '${diff.inHours}h ago';
  if (diff.inMinutes > 0) return '${diff.inMinutes}m ago';
  return 'just now';
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

/// Truncates [s] to [maxLength], appending [suffix] if truncated.
String truncate(String s, int maxLength, {String suffix = '\u2026'}) {
  if (s.length <= maxLength) return s;
  return '${s.substring(0, maxLength - suffix.length)}$suffix';
}

/// Escapes HTML special characters in [s].
String escapeHtml(String s) => const HtmlEscape().convert(s);
