import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  const parser = TaskTriggerParser();

  group('TaskTriggerParser.parse', () {
    test('returns null when config is disabled', () {
      final result = parser.parse('task: fix it', const TaskTriggerConfig());

      expect(result, isNull);
    });

    test('matches exact prefix and uses configured default type', () {
      final result = parser.parse('task: fix the login bug', const TaskTriggerConfig(enabled: true));

      expect(result, isNotNull);
      expect(result!.description, 'fix the login bug');
      expect(result.type, TaskType.research);
      expect(result.autoStart, isTrue);
    });

    test('parses known explicit task type', () {
      final result = parser.parse('task: coding: fix the login bug', const TaskTriggerConfig(enabled: true));

      expect(result, isNotNull);
      expect(result!.description, 'fix the login bug');
      expect(result.type, TaskType.coding);
    });

    test('matches prefix case-insensitively', () {
      final upper = parser.parse('TASK: fix it', const TaskTriggerConfig(enabled: true));
      final mixed = parser.parse('Task: fix it', const TaskTriggerConfig(enabled: true));

      expect(upper, isNotNull);
      expect(mixed, isNotNull);
      expect(upper!.description, 'fix it');
      expect(mixed!.description, 'fix it');
    });

    test('ignores mid-sentence prefixes', () {
      final result = parser.parse('I think task: fix this later', const TaskTriggerConfig(enabled: true));

      expect(result, isNull);
    });

    test('returns null for empty description by default', () {
      final result = parser.parse('task:', const TaskTriggerConfig(enabled: true));

      expect(result, isNull);
    });

    test('can surface empty description as a result when requested', () {
      final result = parser.parse('task:   ', const TaskTriggerConfig(enabled: true), emptyDescriptionError: true);

      expect(result, isNotNull);
      expect(result!.description, isEmpty);
      expect(result.type, TaskType.research);
    });

    test('returns null for explicit type prefix without a description by default', () {
      expect(parser.parse('task: coding:', const TaskTriggerConfig(enabled: true)), isNull);
      expect(parser.parse('task: refactor:   ', const TaskTriggerConfig(enabled: true)), isNull);
    });

    test('surfaces explicit type prefixes without a description when requested', () {
      final emptyTyped = parser.parse(
        'task: coding:',
        const TaskTriggerConfig(enabled: true),
        emptyDescriptionError: true,
      );
      final whitespaceTyped = parser.parse(
        'task: refactor:   ',
        const TaskTriggerConfig(enabled: true),
        emptyDescriptionError: true,
      );

      expect(emptyTyped, isNotNull);
      expect(emptyTyped!.description, isEmpty);
      expect(emptyTyped.type, TaskType.coding);
      expect(whitespaceTyped, isNotNull);
      expect(whitespaceTyped!.description, isEmpty);
      expect(whitespaceTyped.type, TaskType.custom);
    });

    test('unknown single-word explicit type resolves to custom', () {
      final result = parser.parse('task: refactor: clean up the module', const TaskTriggerConfig(enabled: true));

      expect(result, isNotNull);
      expect(result!.description, 'clean up the module');
      expect(result.type, TaskType.custom);
    });

    test('multi-word text before colon stays in description', () {
      final result = parser.parse('task: fix the login bug: more context', const TaskTriggerConfig(enabled: true));

      expect(result, isNotNull);
      expect(result!.description, 'fix the login bug: more context');
      expect(result.type, TaskType.research);
    });

    test('custom prefix is respected', () {
      final config = const TaskTriggerConfig(enabled: true, prefix: 'do:');

      expect(parser.parse('do: fix it', config), isNotNull);
      expect(parser.parse('task: fix it', config), isNull);
    });

    test('leading whitespace before prefix is ignored', () {
      final result = parser.parse('   task: fix it', const TaskTriggerConfig(enabled: true));

      expect(result, isNotNull);
      expect(result!.description, 'fix it');
    });

    test('propagates autoStart from config', () {
      final result = parser.parse('task: fix it', const TaskTriggerConfig(enabled: true, autoStart: false));

      expect(result, isNotNull);
      expect(result!.autoStart, isFalse);
    });

    test('uses configured default type when explicit type is absent', () {
      final result = parser.parse(
        'task: investigate the production issue',
        const TaskTriggerConfig(enabled: true, defaultType: 'coding'),
      );

      expect(result, isNotNull);
      expect(result!.type, TaskType.coding);
    });

    test('unknown default type resolves to custom', () {
      final result = parser.parse(
        'task: investigate the production issue',
        const TaskTriggerConfig(enabled: true, defaultType: 'future_type'),
      );

      expect(result, isNotNull);
      expect(result!.type, TaskType.custom);
    });

    test('supports every known task type name', () {
      for (final type in TaskType.values) {
        final result = parser.parse('task: ${type.name}: something', const TaskTriggerConfig(enabled: true));

        expect(result, isNotNull, reason: 'Expected parser result for ${type.name}');
        expect(result!.type, type);
        expect(result.description, 'something');
      }
    });
  });
}
