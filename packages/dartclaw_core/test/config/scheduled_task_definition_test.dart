import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('ScheduledTaskDefinition.fromYaml', () {
    test('parses valid entry with all fields', () {
      final warnings = <String>[];
      final def = ScheduledTaskDefinition.fromYaml({
        'id': 'weekly-report',
        'schedule': '0 9 * * 1',
        'enabled': true,
        'task': {
          'title': 'Weekly Report',
          'description': 'Generate a summary',
          'type': 'research',
          'acceptance_criteria': 'Must include commits',
          'auto_start': false,
        },
      }, warnings);

      expect(def, isNotNull);
      expect(def!.id, 'weekly-report');
      expect(def.cronExpression, '0 9 * * 1');
      expect(def.enabled, true);
      expect(def.title, 'Weekly Report');
      expect(def.description, 'Generate a summary');
      expect(def.type, TaskType.research);
      expect(def.acceptanceCriteria, 'Must include commits');
      expect(def.autoStart, false);
      expect(warnings, isEmpty);
    });

    test('parses entry with minimal required fields', () {
      final warnings = <String>[];
      final def = ScheduledTaskDefinition.fromYaml({
        'id': 'minimal',
        'schedule': '* * * * *',
        'task': {
          'title': 'Minimal Task',
          'description': 'A simple task',
          'type': 'analysis',
        },
      }, warnings);

      expect(def, isNotNull);
      expect(def!.id, 'minimal');
      expect(def.enabled, true); // default
      expect(def.autoStart, true); // default
      expect(def.acceptanceCriteria, isNull);
      expect(warnings, isEmpty);
    });

    test('defaults autoStart to true when not specified', () {
      final warnings = <String>[];
      final def = ScheduledTaskDefinition.fromYaml({
        'id': 'auto',
        'schedule': '0 0 * * *',
        'task': {
          'title': 'Task',
          'description': 'Desc',
          'type': 'research',
        },
      }, warnings);

      expect(def!.autoStart, true);
    });

    test('defaults enabled to true when not specified', () {
      final warnings = <String>[];
      final def = ScheduledTaskDefinition.fromYaml({
        'id': 'test',
        'schedule': '0 0 * * *',
        'task': {
          'title': 'Task',
          'description': 'Desc',
          'type': 'research',
        },
      }, warnings);

      expect(def!.enabled, true);
    });

    test('rejects entry with missing id', () {
      final warnings = <String>[];
      final def = ScheduledTaskDefinition.fromYaml({
        'schedule': '0 0 * * *',
        'task': {
          'title': 'Task',
          'description': 'Desc',
          'type': 'research',
        },
      }, warnings);

      expect(def, isNull);
      expect(warnings, hasLength(1));
      expect(warnings.first, contains('id'));
    });

    test('rejects entry with empty id', () {
      final warnings = <String>[];
      final def = ScheduledTaskDefinition.fromYaml({
        'id': '',
        'schedule': '0 0 * * *',
        'task': {
          'title': 'Task',
          'description': 'Desc',
          'type': 'research',
        },
      }, warnings);

      expect(def, isNull);
      expect(warnings, hasLength(1));
    });

    test('rejects entry with missing schedule', () {
      final warnings = <String>[];
      final def = ScheduledTaskDefinition.fromYaml({
        'id': 'test',
        'task': {
          'title': 'Task',
          'description': 'Desc',
          'type': 'research',
        },
      }, warnings);

      expect(def, isNull);
      expect(warnings, hasLength(1));
      expect(warnings.first, contains('schedule'));
    });

    test('rejects entry with missing title', () {
      final warnings = <String>[];
      final def = ScheduledTaskDefinition.fromYaml({
        'id': 'test',
        'schedule': '0 0 * * *',
        'task': {
          'description': 'Desc',
          'type': 'research',
        },
      }, warnings);

      expect(def, isNull);
      expect(warnings, hasLength(1));
      expect(warnings.first, contains('title'));
    });

    test('rejects entry with missing description', () {
      final warnings = <String>[];
      final def = ScheduledTaskDefinition.fromYaml({
        'id': 'test',
        'schedule': '0 0 * * *',
        'task': {
          'title': 'Task',
          'type': 'research',
        },
      }, warnings);

      expect(def, isNull);
      expect(warnings, hasLength(1));
      expect(warnings.first, contains('description'));
    });

    test('rejects entry with invalid task type', () {
      final warnings = <String>[];
      final def = ScheduledTaskDefinition.fromYaml({
        'id': 'test',
        'schedule': '0 0 * * *',
        'task': {
          'title': 'Task',
          'description': 'Desc',
          'type': 'nonexistent',
        },
      }, warnings);

      expect(def, isNull);
      expect(warnings, hasLength(1));
      expect(warnings.first, contains('nonexistent'));
    });

    test('rejects entry with missing task section', () {
      final warnings = <String>[];
      final def = ScheduledTaskDefinition.fromYaml({
        'id': 'test',
        'schedule': '0 0 * * *',
      }, warnings);

      expect(def, isNull);
      expect(warnings, hasLength(1));
      expect(warnings.first, contains('task'));
    });
  });

  group('ScheduledTaskDefinition.toJson', () {
    test('round-trips correctly', () {
      final def = ScheduledTaskDefinition(
        id: 'weekly',
        cronExpression: '0 9 * * 1',
        enabled: true,
        title: 'Weekly Report',
        description: 'Generate report',
        type: TaskType.research,
        acceptanceCriteria: 'Must include commits',
        autoStart: true,
      );

      final json = def.toJson();
      expect(json['id'], 'weekly');
      expect(json['schedule'], '0 9 * * 1');
      expect(json['enabled'], true);
      expect((json['task'] as Map)['title'], 'Weekly Report');
      expect((json['task'] as Map)['description'], 'Generate report');
      expect((json['task'] as Map)['type'], 'research');
      expect((json['task'] as Map)['acceptance_criteria'], 'Must include commits');
    });

    test('omits auto_start when true (default)', () {
      final def = ScheduledTaskDefinition(
        id: 'test',
        cronExpression: '* * * * *',
        title: 'Task',
        description: 'Desc',
        type: TaskType.analysis,
        autoStart: true,
      );

      final json = def.toJson();
      expect((json['task'] as Map).containsKey('auto_start'), false);
    });

    test('includes auto_start when false', () {
      final def = ScheduledTaskDefinition(
        id: 'test',
        cronExpression: '* * * * *',
        title: 'Task',
        description: 'Desc',
        type: TaskType.analysis,
        autoStart: false,
      );

      final json = def.toJson();
      expect((json['task'] as Map)['auto_start'], false);
    });

    test('omits acceptance_criteria when null', () {
      final def = ScheduledTaskDefinition(
        id: 'test',
        cronExpression: '* * * * *',
        title: 'Task',
        description: 'Desc',
        type: TaskType.analysis,
      );

      final json = def.toJson();
      expect((json['task'] as Map).containsKey('acceptance_criteria'), false);
    });

    test('toJson can be reparsed by fromYaml', () {
      final original = ScheduledTaskDefinition(
        id: 'round-trip',
        cronExpression: '0 0 * * *',
        enabled: false,
        title: 'Round Trip',
        description: 'Test round trip',
        type: TaskType.writing,
        acceptanceCriteria: 'Must pass',
        autoStart: false,
      );

      final json = original.toJson();
      final warnings = <String>[];
      final reparsed = ScheduledTaskDefinition.fromYaml(json, warnings);

      expect(warnings, isEmpty);
      expect(reparsed, isNotNull);
      expect(reparsed!.id, original.id);
      expect(reparsed.cronExpression, original.cronExpression);
      expect(reparsed.enabled, original.enabled);
      expect(reparsed.title, original.title);
      expect(reparsed.description, original.description);
      expect(reparsed.type, original.type);
      expect(reparsed.acceptanceCriteria, original.acceptanceCriteria);
      expect(reparsed.autoStart, original.autoStart);
    });
  });
}
