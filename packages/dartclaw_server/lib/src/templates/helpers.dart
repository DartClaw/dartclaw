import 'dart:convert';

const _escape = HtmlEscape();

/// HTML-escapes [input], converting `&`, `<`, `>`, `"`, `'`, and `/`
/// to their entity equivalents.
String htmlEscape(String input) => _escape.convert(input);

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
