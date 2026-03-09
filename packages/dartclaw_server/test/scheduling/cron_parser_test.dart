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

  group('CronExpression.describe', () {
    test('every minute', () {
      expect(CronExpression.parse('* * * * *').describe(), 'Every minute');
    });

    test('every N minutes', () {
      expect(CronExpression.parse('*/15 * * * *').describe(), 'Every 15 minutes');
      expect(CronExpression.parse('*/5 * * * *').describe(), 'Every 5 minutes');
    });

    test('every hour', () {
      expect(CronExpression.parse('0 * * * *').describe(), 'Every hour');
    });

    test('every N hours', () {
      expect(CronExpression.parse('0 */6 * * *').describe(), 'Every 6 hours');
      expect(CronExpression.parse('0 */2 * * *').describe(), 'Every 2 hours');
    });

    test('daily at specific time', () {
      expect(CronExpression.parse('0 7 * * *').describe(), 'Daily at 7:00 AM');
      expect(CronExpression.parse('30 18 * * *').describe(), 'Daily at 6:30 PM');
      expect(CronExpression.parse('0 0 * * *').describe(), 'Daily at 12:00 AM');
      expect(CronExpression.parse('0 12 * * *').describe(), 'Daily at 12:00 PM');
    });

    test('weekly on specific day', () {
      expect(CronExpression.parse('0 9 * * 1').describe(), 'Weekly on Mon at 9:00 AM');
      expect(CronExpression.parse('0 3 * * 0').describe(), 'Weekly on Sun at 3:00 AM');
      expect(CronExpression.parse('30 17 * * 5').describe(), 'Weekly on Fri at 5:30 PM');
    });

    test('monthly on specific date', () {
      expect(CronExpression.parse('0 9 1 * *').describe(), 'Monthly on the 1st at 9:00 AM');
      expect(CronExpression.parse('0 9 2 * *').describe(), 'Monthly on the 2nd at 9:00 AM');
      expect(CronExpression.parse('0 9 3 * *').describe(), 'Monthly on the 3rd at 9:00 AM');
      expect(CronExpression.parse('0 9 15 * *').describe(), 'Monthly on the 15th at 9:00 AM');
      expect(CronExpression.parse('0 9 11 * *').describe(), 'Monthly on the 11th at 9:00 AM');
    });

    test('complex expression falls back to raw string', () {
      expect(CronExpression.parse('0 9 1-15 * 1-5').describe(), '0 9 1-15 * 1-5');
      expect(CronExpression.parse('0,30 9 * * 1-5').describe(), '0,30 9 * * 1-5');
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
