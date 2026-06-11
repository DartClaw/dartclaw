import 'package:test/test.dart';

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
  });
}
