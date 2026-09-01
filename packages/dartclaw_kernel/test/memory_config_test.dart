import 'package:test/test.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'support/load_config.dart';

void main() {
  group('memory namespace config', () {
    test('parses memory.max_bytes from nested config', () {
      final config = loadYaml('memory:\n  max_bytes: 65536\n');
      expect(config.memory.maxBytes, 65536);
    });

    test('falls back to top-level memory_max_bytes when memory.max_bytes is absent', () {
      final config = loadYaml('memory_max_bytes: 65536\n');
      expect(config.memory.maxBytes, 65536);
    });

    test('CLI memory_max_bytes takes precedence over nested and top-level config', () {
      final config = loadYaml(
        'memory_max_bytes: 131072\nmemory:\n  max_bytes: 65536\n',
        cli: const {'memory_max_bytes': '262144'},
      );
      expect(config.memory.maxBytes, 262144);
    });

    test('nested memory.max_bytes takes precedence over top-level memory_max_bytes', () {
      final config = loadYaml('memory_max_bytes: 131072\nmemory:\n  max_bytes: 65536\n');
      expect(config.memory.maxBytes, 65536);
    });

    test('emits deprecation warning for top-level memory_max_bytes', () {
      final config = loadYaml('memory_max_bytes: 65536\n');
      expect(
        config.warnings,
        anyElement(allOf(contains('memory_max_bytes'), contains('memory.max_bytes'), contains('deprecated'))),
      );
    });

    test('no deprecation warning when using nested memory.max_bytes', () {
      final config = loadYaml('memory:\n  max_bytes: 65536\n');
      expect(config.warnings, isNot(anyElement(contains('memory_max_bytes'))));
    });

    for (final entry in <(String, String)>[
      ('memory:\n  max_bytes: 0\n', 'memory.max_bytes'),
      ('memory:\n  max_bytes: -1\n', 'memory.max_bytes'),
      ('memory:\n  max_bytes: 1.5\n', 'memory.max_bytes'),
      ('memory:\n  max_bytes: invalid\n', 'memory.max_bytes'),
      ('memory_max_bytes: 0\n', 'memory.max_bytes'),
      ('memory:\n  pruning:\n    archive_after_days: 0\n', 'memory.pruning.archive_after_days'),
      ('memory:\n  pruning:\n    archive_after_days: -1\n', 'memory.pruning.archive_after_days'),
      ('memory:\n  pruning:\n    archive_after_days: 1.5\n', 'memory.pruning.archive_after_days'),
    ]) {
      test('rejects present-invalid positive integer ${entry.$2}: ${entry.$1.trim()}', () {
        expect(
          () => loadYaml(entry.$1),
          throwsA(isA<FormatException>().having((error) => error.message, 'message', contains(entry.$2))),
        );
      });
    }

    for (final entry in <({String yaml, Map<String, String>? cli, String path})>[
      (yaml: 'memory:\n  max_bytes: 0\n', cli: null, path: 'memory.max_bytes'),
      (yaml: 'memory:\n  max_bytes: invalid\n', cli: null, path: 'memory.max_bytes'),
      (yaml: '', cli: {'memory_max_bytes': '0'}, path: 'memory.max_bytes'),
      (yaml: 'memory:\n  pruning:\n    archive_after_days: -1\n', cli: null, path: 'memory.pruning.archive_after_days'),
    ]) {
      test('${entry.path} keeps its exact positive-integer failure', () {
        expect(
          () => loadYaml(entry.yaml, cli: entry.cli),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              '${entry.path} must be a positive integer.',
            ),
          ),
        );
      });
    }

    test('declared minimum one still loads on both memory paths', () {
      final config = loadYaml('memory:\n  max_bytes: 1\n  pruning:\n    archive_after_days: 1\n');

      expect(config.memory.maxBytes, 1);
      expect(config.memory.archiveAfterDays, 1);
    });

    test('typed construction rejects non-positive memory integers', () {
      expect(() => MemoryConfig(maxBytes: 0), throwsArgumentError);
      expect(() => MemoryConfig(archiveAfterDays: -1), throwsArgumentError);
    });

    test('memory.pruning CLI overrides take precedence over YAML', () {
      final config = loadYaml(
        'memory:\n  pruning:\n    enabled: true\n    archive_after_days: 90\n    schedule: "0 3 * * *"\n',
        cli: const {
          'memory_pruning_enabled': 'false',
          'memory_pruning_archive_after_days': '7',
          'memory_pruning_schedule': '0 4 * * *',
        },
      );
      expect(config.memory.pruningEnabled, isFalse);
      expect(config.memory.archiveAfterDays, 7);
      expect(config.memory.pruningSchedule, '0 4 * * *');
    });

    test('parses memory.journal and defaults it off', () {
      final configured = loadYaml('memory:\n  journal:\n    enabled: true\n    schedule: "0 6 * * *"\n');
      final defaults = loadNoFile();

      expect(configured.memory.journalEnabled, isTrue);
      expect(configured.memory.journalSchedule, '0 6 * * *');
      expect(defaults.memory.journalEnabled, isFalse);
      expect(defaults.memory.journalSchedule, '0 22 * * *');
    });

    for (final malformedJournal in ['1', '[]', 'invalid', 'null']) {
      test('rejects non-map memory.journal value $malformedJournal', () {
        expect(
          () => loadYaml('memory:\n  journal: $malformedJournal\n'),
          throwsA(isA<FormatException>().having((error) => error.message, 'message', contains('memory.journal'))),
        );
      });
    }

    for (final malformedSchedule in ['1', '[]', '{}', 'null']) {
      test('rejects non-string memory.journal.schedule value $malformedSchedule', () {
        expect(
          () => loadYaml('memory:\n  journal:\n    schedule: $malformedSchedule\n'),
          throwsA(
            isA<FormatException>().having((error) => error.message, 'message', contains('memory.journal.schedule')),
          ),
        );
      });
    }

    test('parses memory.curation and defaults it off after the journal hour', () {
      final configured = loadYaml('memory:\n  curation:\n    enabled: true\n    schedule: "0 4 * * *"\n');
      final defaults = loadNoFile();

      expect(configured.memory.curationEnabled, isTrue);
      expect(configured.memory.curationSchedule, '0 4 * * *');
      expect(defaults.memory.curationEnabled, isFalse);
      expect(defaults.memory.curationSchedule, '0 3 * * *');
    });

    for (final malformedCuration in ['1', '[]', 'invalid', 'null']) {
      test('rejects non-map memory.curation value $malformedCuration', () {
        expect(
          () => loadYaml('memory:\n  curation: $malformedCuration\n'),
          throwsA(isA<FormatException>().having((error) => error.message, 'message', contains('memory.curation'))),
        );
      });
    }

    for (final malformedSchedule in ['1', '[]', '{}', 'null']) {
      test('rejects non-string memory.curation.schedule value $malformedSchedule', () {
        expect(
          () => loadYaml('memory:\n  curation:\n    schedule: $malformedSchedule\n'),
          throwsA(
            isA<FormatException>().having((error) => error.message, 'message', contains('memory.curation.schedule')),
          ),
        );
      });
    }
  });
}
