import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/runtime/scheduling_wiring.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
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

  group('memory curation config validation', () {
    test('disabled curation leaves colliding user jobs unchanged', () {
      final config = DartclawConfig(
        memory: MemoryConfig(curationEnabled: false),
        scheduling: SchedulingConfig(
          jobs: [
            {
              'id': memoryCurationJobId,
              'prompt': 'Custom curation',
              'schedule': {'type': 'cron', 'expression': '0 8 * * *'},
            },
          ],
        ),
      );

      expect(validateMemoryCurationConfig(config), isNull);
    });

    // The built-in used to reserve this ID globally and reject the collision at
    // request time with a 409; now it is an ordinary duplicate refused at load.
    for (final identityKey in ['id', 'name']) {
      test('enabled curation rejects a user $identityKey collision before wiring', () {
        final config = DartclawConfig(
          memory: MemoryConfig(curationEnabled: true),
          scheduling: SchedulingConfig(
            jobs: [
              {
                identityKey: memoryCurationJobId,
                'prompt': 'Custom curation',
                'schedule': {'type': 'cron', 'expression': '0 8 * * *'},
              },
            ],
          ),
        );

        expect(
          () => validateMemoryCurationConfig(config),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              allOf(
                contains('Duplicate scheduled job ID'),
                contains(memoryCurationJobId),
                contains('memory.curation'),
                contains('scheduling.jobs'),
              ),
            ),
          ),
        );
      });
    }

    test('enabled curation rejects an invalid cron with the standard parser error', () {
      final config = DartclawConfig(memory: MemoryConfig(curationEnabled: true, curationSchedule: 'not-a-cron'));

      expect(() => validateMemoryCurationConfig(config), throwsFormatException);
    });

    test('enabled curation parses its schedule', () {
      final config = DartclawConfig(memory: MemoryConfig(curationEnabled: true, curationSchedule: '0 4 * * *'));

      expect(validateMemoryCurationConfig(config)!.hours, {4});
    });
  });
}
