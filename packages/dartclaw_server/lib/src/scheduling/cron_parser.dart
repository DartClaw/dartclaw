/// Lightweight 5-field cron expression parser.
///
/// Fields: minute(0-59) hour(0-23) dom(1-31) month(1-12) dow(0-6, 0=Sunday)
/// Supports: `*`, ranges (`1-5`), lists (`1,3,5`), steps (`*/5`, `1-10/2`).
class CronExpression {
  final Set<int> minutes;
  final Set<int> hours;
  final Set<int> daysOfMonth;
  final Set<int> months;
  final Set<int> daysOfWeek;

  CronExpression._({
    required this.minutes,
    required this.hours,
    required this.daysOfMonth,
    required this.months,
    required this.daysOfWeek,
  });

  /// Parses a 5-field cron expression string.
  factory CronExpression.parse(String expression) {
    final parts = expression.trim().split(RegExp(r'\s+'));
    if (parts.length != 5) {
      throw FormatException('Cron expression must have 5 fields, got ${parts.length}: "$expression"');
    }
    return CronExpression._(
      minutes: _parseField(parts[0], 0, 59, 'minute'),
      hours: _parseField(parts[1], 0, 23, 'hour'),
      daysOfMonth: _parseField(parts[2], 1, 31, 'day-of-month'),
      months: _parseField(parts[3], 1, 12, 'month'),
      daysOfWeek: _parseField(parts[4], 0, 6, 'day-of-week'),
    );
  }

  /// Whether [dt] matches this expression.
  bool matches(DateTime dt) {
    return minutes.contains(dt.minute) &&
        hours.contains(dt.hour) &&
        daysOfMonth.contains(dt.day) &&
        months.contains(dt.month) &&
        daysOfWeek.contains(dt.weekday % 7); // Dart weekday: 1=Mon..7=Sun; cron: 0=Sun
  }

  /// Calculates the next DateTime matching this expression after [from].
  ///
  /// Searches minute by minute up to 2 years. Throws [StateError] if no
  /// match found (e.g. impossible expression like Feb 30).
  DateTime nextFrom(DateTime from) {
    var candidate = DateTime(from.year, from.month, from.day, from.hour, from.minute).add(const Duration(minutes: 1));
    final limit = from.add(const Duration(days: 730));

    while (candidate.isBefore(limit)) {
      if (matches(candidate)) return candidate;

      // Skip ahead intelligently
      if (!months.contains(candidate.month)) {
        // Jump to next valid month
        candidate = DateTime(candidate.year, candidate.month + 1);
        continue;
      }
      if (!daysOfMonth.contains(candidate.day) || !daysOfWeek.contains(candidate.weekday % 7)) {
        candidate = DateTime(candidate.year, candidate.month, candidate.day + 1);
        continue;
      }
      if (!hours.contains(candidate.hour)) {
        candidate = DateTime(candidate.year, candidate.month, candidate.day, candidate.hour + 1);
        continue;
      }
      candidate = candidate.add(const Duration(minutes: 1));
    }

    throw StateError('No matching time found within 2 years for cron expression');
  }

  static Set<int> _parseField(String field, int min, int max, String name) {
    final result = <int>{};
    for (final part in field.split(',')) {
      final trimmed = part.trim();
      if (trimmed.contains('/')) {
        // Step: */5 or 1-10/2
        final stepParts = trimmed.split('/');
        if (stepParts.length != 2) throw FormatException('Invalid step in $name: "$trimmed"');
        final step = int.tryParse(stepParts[1]);
        if (step == null || step < 1) throw FormatException('Invalid step value in $name: "$trimmed"');
        final range = _parseRange(stepParts[0], min, max, name);
        for (var i = range.first; i <= range.last; i += step) {
          result.add(i);
        }
      } else if (trimmed == '*') {
        for (var i = min; i <= max; i++) {
          result.add(i);
        }
      } else if (trimmed.contains('-')) {
        final range = _parseRange(trimmed, min, max, name);
        for (var i = range.first; i <= range.last; i++) {
          result.add(i);
        }
      } else {
        final value = int.tryParse(trimmed);
        if (value == null || value < min || value > max) {
          throw FormatException('Invalid value in $name: "$trimmed" (must be $min-$max)');
        }
        result.add(value);
      }
    }
    if (result.isEmpty) throw FormatException('Empty field for $name');
    return result;
  }

  static ({int first, int last}) _parseRange(String range, int min, int max, String name) {
    if (range == '*') return (first: min, last: max);
    final parts = range.split('-');
    if (parts.length == 1) {
      final val = int.tryParse(parts[0]);
      if (val == null || val < min || val > max) {
        throw FormatException('Invalid range start in $name: "$range"');
      }
      return (first: val, last: val);
    }
    if (parts.length != 2) throw FormatException('Invalid range in $name: "$range"');
    final first = int.tryParse(parts[0]);
    final last = int.tryParse(parts[1]);
    if (first == null || last == null || first < min || last > max || first > last) {
      throw FormatException('Invalid range in $name: "$range" (must be $min-$max)');
    }
    return (first: first, last: last);
  }
}
