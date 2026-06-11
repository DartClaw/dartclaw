/// Renders [d] as a compact human-readable string using a fixed tier ladder:
/// seconds (`Ns`), minutes (`Mm` / `Mm Ss`), and — when [hours] is true — hours
/// (`Hh Mm`). Negative durations are treated as zero.
///
/// Tiers:
/// - **Hours** (`hours: true` and `d >= 1h`): `${h}h ${m}m`, where `m` is the
///   minute remainder. Seconds are never shown at this tier.
/// - **Minutes** (`d >= 1m`): `${m}m ${s}s`. The trailing `${s}s` is omitted
///   when `s == 0` and [dropZeroRemainder] is true, yielding `${m}m`. When
///   [hours] is true the minutes tier always renders `${m}m` (coarse mode),
///   omitting seconds regardless of value or [dropZeroRemainder].
/// - **Seconds** (otherwise): `${s}s`. A zero duration renders `0s`.
String humanizeDuration(Duration d, {bool hours = false, bool dropZeroRemainder = true}) {
  if (d.isNegative) {
    d = Duration.zero;
  }
  if (hours && d.inHours > 0) {
    return '${d.inHours}h ${d.inMinutes % 60}m';
  }
  if (d.inMinutes > 0) {
    final seconds = d.inSeconds % 60;
    if (hours || (dropZeroRemainder && seconds == 0)) {
      return '${d.inMinutes}m';
    }
    return '${d.inMinutes}m ${seconds}s';
  }
  return '${d.inSeconds}s';
}

/// [humanizeDuration] over a millisecond count. A null or non-positive [ms]
/// renders `0s` (matching the seconds tier for a zero duration).
String humanizeDurationMs(num? ms, {bool hours = false, bool dropZeroRemainder = true}) {
  final value = ms?.toInt() ?? 0;
  return humanizeDuration(
    Duration(milliseconds: value),
    hours: hours,
    dropZeroRemainder: dropZeroRemainder,
  );
}

/// [humanizeDuration] over the span from [start] to [end] (defaulting to
/// [DateTime.now] when [end] is null). A negative span renders `0s`.
String humanizeSpan(DateTime start, [DateTime? end, bool hours = false, bool dropZeroRemainder = true]) {
  final span = (end ?? DateTime.now()).difference(start);
  return humanizeDuration(span, hours: hours, dropZeroRemainder: dropZeroRemainder);
}
