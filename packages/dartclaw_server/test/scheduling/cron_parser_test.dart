import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

void main() {
  group('CronExpression.parse', () {
    test('* * * * * matches every minute', () {
      final cron = CronExpression.parse('* * * * *');
      final dt = DateTime(2026, 2, 25, 10, 30);
      expect(cron.matches(dt), isTrue);
    });

    test('0 18 * * * matches 6 PM only', () {
      final cron = CronExpression.parse('0 18 * * *');
      expect(cron.matches(DateTime(2026, 2, 25, 18, 0)), isTrue);
      expect(cron.matches(DateTime(2026, 2, 25, 17, 0)), isFalse);
      expect(cron.matches(DateTime(2026, 2, 25, 18, 1)), isFalse);
    });

    test('*/5 * * * * matches every 5 minutes', () {
      final cron = CronExpression.parse('*/5 * * * *');
      expect(cron.matches(DateTime(2026, 2, 25, 10, 0)), isTrue);
      expect(cron.matches(DateTime(2026, 2, 25, 10, 5)), isTrue);
      expect(cron.matches(DateTime(2026, 2, 25, 10, 10)), isTrue);
      expect(cron.matches(DateTime(2026, 2, 25, 10, 3)), isFalse);
    });

    test('0 0 1 1 * matches Jan 1 midnight', () {
      final cron = CronExpression.parse('0 0 1 1 *');
      expect(cron.matches(DateTime(2026, 1, 1, 0, 0)), isTrue);
      expect(cron.matches(DateTime(2026, 2, 1, 0, 0)), isFalse);
    });

    test('ranges work correctly', () {
      final cron = CronExpression.parse('0 9-17 * * 1-5');
      // Wed at 10 AM
      expect(cron.matches(DateTime(2026, 2, 25, 10, 0)), isTrue);
      // Wed at 8 AM (before range)
      expect(cron.matches(DateTime(2026, 2, 25, 8, 0)), isFalse);
      // Sun at 10 AM (day 0, not in 1-5)
      expect(cron.matches(DateTime(2026, 3, 1, 10, 0)), isFalse); // Mar 1 2026 = Sun → weekday%7 = 0
    });

    test('lists work correctly', () {
      final cron = CronExpression.parse('0,30 * * * *');
      expect(cron.matches(DateTime(2026, 2, 25, 10, 0)), isTrue);
      expect(cron.matches(DateTime(2026, 2, 25, 10, 30)), isTrue);
      expect(cron.matches(DateTime(2026, 2, 25, 10, 15)), isFalse);
    });

    test('invalid expression throws FormatException', () {
      expect(() => CronExpression.parse(''), throwsFormatException);
      expect(() => CronExpression.parse('* *'), throwsFormatException);
      expect(() => CronExpression.parse('60 * * * *'), throwsFormatException);
      expect(() => CronExpression.parse('* 25 * * *'), throwsFormatException);
      expect(() => CronExpression.parse('* * * * 8'), throwsFormatException);
    });
  });

  group('CronExpression.nextFrom', () {
    test('calculates next occurrence for simple cron', () {
      final cron = CronExpression.parse('0 18 * * *');
      final from = DateTime(2026, 2, 25, 10, 0);
      final next = cron.nextFrom(from);
      expect(next, DateTime(2026, 2, 25, 18, 0));
    });

    test('wraps to next day if past time', () {
      final cron = CronExpression.parse('0 9 * * *');
      final from = DateTime(2026, 2, 25, 10, 0);
      final next = cron.nextFrom(from);
      expect(next, DateTime(2026, 2, 26, 9, 0));
    });

    test('handles every-5-minute steps', () {
      final cron = CronExpression.parse('*/5 * * * *');
      final from = DateTime(2026, 2, 25, 10, 7);
      final next = cron.nextFrom(from);
      expect(next, DateTime(2026, 2, 25, 10, 10));
    });

    test('advances from current minute', () {
      final cron = CronExpression.parse('* * * * *');
      final from = DateTime(2026, 2, 25, 10, 30);
      final next = cron.nextFrom(from);
      expect(next, DateTime(2026, 2, 25, 10, 31));
    });
  });

  group('CronExpression.matches weekday mapping', () {
    test('Sunday is 0 in cron notation', () {
      final cron = CronExpression.parse('* * * * 0');
      // Find a Sunday: 2026-03-01 is a Sunday
      expect(cron.matches(DateTime(2026, 3, 1, 12, 0)), isTrue);
    });

    test('Monday is 1 in cron notation', () {
      final cron = CronExpression.parse('* * * * 1');
      // 2026-02-23 is a Monday
      expect(cron.matches(DateTime(2026, 2, 23, 12, 0)), isTrue);
    });
  });
}
