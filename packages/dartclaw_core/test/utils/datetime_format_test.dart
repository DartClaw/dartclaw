import 'package:dartclaw_core/dartclaw_core.dart' show formatLocalDateTime, tryParseIsoInstant;
import 'package:test/test.dart';

void main() {
  group('formatLocalDateTime', () {
    test('formats a DateTime with seconds by default', () {
      final dt = DateTime(2024, 3, 7, 9, 4, 5);
      expect(formatLocalDateTime(dt), '2024-03-07 09:04:05');
    });

    test('formats a DateTime without seconds when seconds: false', () {
      final dt = DateTime(2024, 3, 7, 9, 4, 5);
      expect(formatLocalDateTime(dt, seconds: false), '2024-03-07 09:04');
    });

    test('parses an ISO-8601 string and renders its own fields (no tz conversion)', () {
      expect(formatLocalDateTime('2024-12-31T23:08:09'), '2024-12-31 23:08:09');
    });

    test('renders a UTC ISO string without shifting the clock', () {
      // Z suffix is preserved as the same wall-clock fields, not converted to local.
      expect(formatLocalDateTime('2024-06-01T12:00:00Z'), '2024-06-01 12:00:00');
    });

    test('zero-pads month, day, hour, minute, and second to two digits', () {
      final dt = DateTime(2024, 1, 2, 3, 4, 5);
      expect(formatLocalDateTime(dt), '2024-01-02 03:04:05');
    });

    test('returns the default placeholder for null', () {
      expect(formatLocalDateTime(null), '—');
    });

    test('returns the default placeholder for an empty string', () {
      expect(formatLocalDateTime(''), '—');
    });

    test('honors a custom emptyPlaceholder', () {
      expect(formatLocalDateTime(null, emptyPlaceholder: 'N/A'), 'N/A');
    });

    test('returns an unparseable non-empty string verbatim', () {
      expect(formatLocalDateTime('not-a-date'), 'not-a-date');
    });
  });

  group('tryParseIsoInstant', () {
    test('reads a bare date as that day in UTC', () {
      expect(tryParseIsoInstant('2026-08-19'), DateTime.utc(2026, 8, 19));
    });

    test('reads offset-bearing timestamps as the same instant regardless of spelling', () {
      expect(tryParseIsoInstant('2026-08-19T10:00:00Z'), DateTime.utc(2026, 8, 19, 10));
      expect(tryParseIsoInstant('2026-08-19 10:00:00+02:00'), DateTime.utc(2026, 8, 19, 8));
    });

    test('rejects a calendar-invalid date rather than rolling it forward', () {
      // DateTime.utc(2026, 2, 30) silently becomes 2026-03-02; the caller's
      // quarantine contract depends on that being a rejection, not a value.
      expect(tryParseIsoInstant('2026-02-30'), isNull);
      expect(tryParseIsoInstant('2026-13-01'), isNull);
    });

    test('rejects out-of-range time fields and an invalid offset', () {
      expect(tryParseIsoInstant('2026-08-19T25:00:00Z'), isNull);
      expect(tryParseIsoInstant('2026-08-19T10:61:00Z'), isNull);
      expect(tryParseIsoInstant('2026-08-19T10:00:00+25:00'), isNull);
    });

    test('rejects a timestamp that names no offset', () {
      expect(tryParseIsoInstant('2026-08-19T10:00:00'), isNull);
    });

    test('rejects text that is not a date at all', () {
      expect(tryParseIsoInstant('yesterday'), isNull);
      expect(tryParseIsoInstant(''), isNull);
    });
  });
}
