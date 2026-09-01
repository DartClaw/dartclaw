import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_runtime/dartclaw_runtime.dart';
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
    test('advances monotonically through a real DST fallback', () async {
      final repoRoot = _findRepoRoot();
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'packages/dartclaw_runtime/test/scheduling/fixtures/cron_parser_dst_fallback.dart'],
        environment: {...Platform.environment, 'TZ': 'America/New_York'},
        workingDirectory: repoRoot,
      );

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final occurrences = (jsonDecode(result.stdout as String) as List).cast<Map<String, dynamic>>();
      expect(occurrences.take(3), [
        {'local': '2026-11-01T01:59:30.000', 'utc': '2026-11-01T05:59:30.000Z'},
        {'local': '2026-11-01T01:00:00.000', 'utc': '2026-11-01T06:00:00.000Z'},
        {'local': '2026-11-01T01:01:00.000', 'utc': '2026-11-01T06:01:00.000Z'},
      ]);
      final instants = occurrences.map((occurrence) => DateTime.parse(occurrence['utc']! as String)).toList();
      expect(instants.toSet(), hasLength(instants.length), reason: 'a cron instant must be returned at most once');
      for (var i = 1; i < instants.length; i++) {
        expect(instants[i].isAfter(instants[i - 1]), isTrue, reason: '${instants[i]} must follow ${instants[i - 1]}');
      }
      expect(occurrences.last, {'local': '2026-11-01T02:00:00.000', 'utc': '2026-11-01T07:00:00.000Z'});
    });

    test('calculates next occurrence for simple cron', () {
      final cron = CronExpression.parse('0 18 * * *');
      final from = DateTime(2026, 2, 25, 10, 0);
      final next = cron.nextFrom(from);
      expect(next, DateTime(2026, 2, 25, 18, 0));
    });

    test('preserves UTC reference semantics while skipping ahead', () {
      final next = CronExpression.parse('0 18 * * *').nextFrom(DateTime.utc(2026, 2, 25, 10));

      expect(next, DateTime.utc(2026, 2, 25, 18));
      expect(next.isUtc, isTrue);
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
    test('maps Sunday (0) and Monday (1) correctly in cron notation', () {
      // 2026-03-01 is a Sunday
      expect(CronExpression.parse('* * * * 0').matches(DateTime(2026, 3, 1, 12, 0)), isTrue);
      // 2026-02-23 is a Monday
      expect(CronExpression.parse('* * * * 1').matches(DateTime(2026, 2, 23, 12, 0)), isTrue);
    });
  });
}

String _findRepoRoot() {
  var directory = Directory.current;
  while (true) {
    if (Directory('${directory.path}/packages/dartclaw_runtime').existsSync()) return directory.path;
    final parent = directory.parent;
    if (parent.path == directory.path) throw StateError('Could not locate the DartClaw repository root');
    directory = parent;
  }
}
