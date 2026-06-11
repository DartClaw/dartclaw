import 'package:dartclaw_core/dartclaw_core.dart' show formatLocalDateTime;
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
}
