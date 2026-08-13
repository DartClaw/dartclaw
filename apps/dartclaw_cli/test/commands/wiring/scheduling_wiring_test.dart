import 'package:dartclaw_cli/src/commands/wiring/scheduling_wiring.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

void main() {
  group('memory journal config validation', () {
    test('disabled journal leaves colliding user jobs unchanged', () {
      final config = DartclawConfig(
        memory: MemoryConfig(journalEnabled: false),
        scheduling: SchedulingConfig(
          jobs: [
            {
              'id': 'memory-journal',
              'prompt': 'Custom journal',
              'schedule': {'type': 'cron', 'expression': '0 8 * * *'},
            },
          ],
        ),
      );

      expect(validateMemoryJournalConfig(config), isNull);
    });

    for (final identityKey in ['id', 'name']) {
      test('enabled journal rejects a user $identityKey collision before wiring', () {
        final config = DartclawConfig(
          memory: MemoryConfig(journalEnabled: true),
          scheduling: SchedulingConfig(
            jobs: [
              {
                identityKey: 'memory-journal',
                'prompt': 'Custom journal',
                'schedule': {'type': 'cron', 'expression': '0 8 * * *'},
              },
            ],
          ),
        );

        expect(
          () => validateMemoryJournalConfig(config),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              allOf(contains('memory-journal'), contains('memory.journal'), contains('scheduling.jobs')),
            ),
          ),
        );
      });
    }

    test('enabled journal rejects an invalid cron with the standard parser error', () {
      final config = DartclawConfig(memory: MemoryConfig(journalEnabled: true, journalSchedule: 'not-a-cron'));

      expect(() => validateMemoryJournalConfig(config), throwsFormatException);
      expect(() => CronExpression.parse('not-a-cron'), throwsFormatException);
    });
  });
}
