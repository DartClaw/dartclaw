/// Parses a YAML duration value into a [Duration].
///
/// Accepts:
/// - [Duration] (pass-through)
/// - [int] (treated as seconds)
/// - [String] with optional suffix: `'30s'`, `'5m'`, `'1h'`, or bare `'30'`
///   (seconds)
///
/// Returns `null` for unrecognized or empty input.
Duration? tryParseDuration(Object? value) {
  if (value is Duration) return value;
  if (value is int) return Duration(seconds: value);
  if (value is! String) return null;
  final s = value.trim().toLowerCase();
  if (s.isEmpty) return null;
  if (s.endsWith('h')) {
    final hours = int.tryParse(s.substring(0, s.length - 1));
    return hours == null ? null : Duration(hours: hours);
  }
  if (s.endsWith('m')) {
    final minutes = int.tryParse(s.substring(0, s.length - 1));
    return minutes == null ? null : Duration(minutes: minutes);
  }
  if (s.endsWith('s')) {
    final seconds = int.tryParse(s.substring(0, s.length - 1));
    return seconds == null ? null : Duration(seconds: seconds);
  }
  final seconds = int.tryParse(s);
  return seconds == null ? null : Duration(seconds: seconds);
}
