/// Parses a human-readable duration string into a [Duration].
///
/// Supports: `30s`, `5m`, `1h`, `1h30m`, `2h15m30s`, `90m`.
/// Throws [FormatException] on invalid input or zero duration.
Duration parseDuration(String input) {
  final s = input.trim();
  if (s.isEmpty) {
    throw FormatException('Duration string must not be empty.');
  }
  final pattern = RegExp(r'^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$');
  final match = pattern.firstMatch(s);
  if (match == null) {
    throw FormatException(
      'Invalid duration format: "$input". '
      'Expected format like "30s", "5m", "1h", "1h30m", "2h15m30s".',
    );
  }
  final hours = int.tryParse(match.group(1) ?? '') ?? 0;
  final minutes = int.tryParse(match.group(2) ?? '') ?? 0;
  final seconds = int.tryParse(match.group(3) ?? '') ?? 0;
  if (hours == 0 && minutes == 0 && seconds == 0) {
    throw FormatException('Duration must be non-zero: "$input".');
  }
  return Duration(hours: hours, minutes: minutes, seconds: seconds);
}
