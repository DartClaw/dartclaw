import 'package:dartclaw_core/dartclaw_core.dart' show humanizeDuration, humanizeDurationMs, humanizeSpan;
import 'package:test/test.dart';

void main() {
  group('humanizeDuration', () {
    test('renders sub-minute durations as seconds', () {
      expect(humanizeDuration(const Duration(seconds: 5)), '5s');
    });

    test('renders zero as 0s', () {
      expect(humanizeDuration(Duration.zero), '0s');
    });

    test('clamps negative durations to 0s', () {
      expect(humanizeDuration(const Duration(seconds: -5)), '0s');
    });

    test('renders minutes with a non-zero second remainder', () {
      expect(humanizeDuration(const Duration(minutes: 2, seconds: 3)), '2m 3s');
    });

    test('drops a zero second remainder by default', () {
      expect(humanizeDuration(const Duration(minutes: 5)), '5m');
    });

    test('keeps a zero second remainder when dropZeroRemainder is false', () {
      expect(humanizeDuration(const Duration(minutes: 5), dropZeroRemainder: false), '5m 0s');
    });

    test('keeps seconds for a non-zero remainder when dropZeroRemainder is false', () {
      expect(humanizeDuration(const Duration(minutes: 5, seconds: 7), dropZeroRemainder: false), '5m 7s');
    });

    test('ignores hours tier when hours is false', () {
      expect(humanizeDuration(const Duration(hours: 1, minutes: 30)), '90m');
    });

    test('renders hours and minute remainder when hours is true', () {
      expect(humanizeDuration(const Duration(hours: 2, minutes: 5), hours: true), '2h 5m');
    });

    test('hours mode drops seconds at the minutes tier regardless of dropZeroRemainder', () {
      expect(humanizeDuration(const Duration(minutes: 3, seconds: 40), hours: true, dropZeroRemainder: false), '3m');
    });

    test('hours mode renders sub-minute spans as seconds', () {
      expect(humanizeDuration(const Duration(seconds: 42), hours: true), '42s');
    });
  });

  group('humanizeDurationMs', () {
    test('builds a Duration from milliseconds', () {
      expect(humanizeDurationMs(65000), '1m 5s');
    });

    test('renders null as 0s', () {
      expect(humanizeDurationMs(null), '0s');
    });

    test('renders non-positive ms as 0s', () {
      expect(humanizeDurationMs(0), '0s');
      expect(humanizeDurationMs(-1000), '0s');
    });

    test('respects dropZeroRemainder: false', () {
      expect(humanizeDurationMs(300000, dropZeroRemainder: false), '5m 0s');
    });

    test('accepts a double ms value', () {
      expect(humanizeDurationMs(1500.0), '1s');
    });
  });

  group('humanizeSpan', () {
    test('humanizes the span between two timestamps', () {
      final start = DateTime(2024, 1, 1, 10, 0, 0);
      final end = DateTime(2024, 1, 1, 10, 2, 30);
      expect(humanizeSpan(start, end), '2m 30s');
    });

    test('renders an hours-tier span when hours is true', () {
      final start = DateTime(2024, 1, 1, 10, 0, 0);
      final end = DateTime(2024, 1, 1, 12, 15, 0);
      expect(humanizeSpan(start, end, true), '2h 15m');
    });

    test('renders a negative span as 0s', () {
      final start = DateTime(2024, 1, 1, 10, 0, 5);
      final end = DateTime(2024, 1, 1, 10, 0, 0);
      expect(humanizeSpan(start, end), '0s');
    });

    test('defaults end to now when omitted (non-negative result)', () {
      final start = DateTime.now().subtract(const Duration(seconds: 1));
      // Allow for execution time; result is at least 1s and sub-minute.
      expect(humanizeSpan(start), endsWith('s'));
    });
  });
}
