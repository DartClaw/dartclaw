import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('TaskTriggerConfig.fromYaml', () {
    test('parses all supported fields', () {
      final warns = <String>[];
      final config = TaskTriggerConfig.fromYaml({
        'enabled': true,
        'prefix': 'do:',
        'default_type': 'coding',
        'auto_start': false,
      }, warns);

      expect(warns, isEmpty);
      expect(config.enabled, isTrue);
      expect(config.prefix, 'do:');
      expect(config.defaultType, 'coding');
      expect(config.autoStart, isFalse);
    });

    test('uses defaults for empty yaml', () {
      final config = TaskTriggerConfig.fromYaml({}, []);

      expect(config.enabled, isFalse);
      expect(config.prefix, 'task:');
      expect(config.defaultType, 'research');
      expect(config.autoStart, isTrue);
    });

    test('warns on invalid field types and falls back to defaults', () {
      final warns = <String>[];
      final config = TaskTriggerConfig.fromYaml({
        'enabled': 'yes',
        'prefix': 123,
        'default_type': false,
        'auto_start': 'no',
      }, warns);

      expect(warns, hasLength(4));
      expect(config.enabled, isFalse);
      expect(config.prefix, 'task:');
      expect(config.defaultType, 'research');
      expect(config.autoStart, isTrue);
    });

    test('whitespace-only prefix falls back to default', () {
      final config = TaskTriggerConfig.fromYaml({'prefix': '   '}, []);

      expect(config.prefix, 'task:');
    });

    test('unknown default type is preserved for parser-time resolution', () {
      final config = TaskTriggerConfig.fromYaml({'default_type': 'future_type'}, []);

      expect(config.defaultType, 'future_type');
    });

    test('trims default type and resolves known values correctly', () {
      final config = TaskTriggerConfig.fromYaml({'enabled': true, 'default_type': ' analysis '}, []);

      final result = const TaskTriggerParser().parse('task: investigate the production issue', config);

      expect(config.defaultType, 'analysis');
      expect(result, isNotNull);
      expect(result!.type, TaskType.analysis);
    });

    test('whitespace-only default type falls back to the default type', () {
      final config = TaskTriggerConfig.fromYaml({'default_type': '   '}, []);

      expect(config.defaultType, 'research');
    });
  });
}
