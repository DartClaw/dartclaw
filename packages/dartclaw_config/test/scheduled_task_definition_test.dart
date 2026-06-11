import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

void main() {
  group('ScheduledTaskDefinition.fromYaml', () {
    test('parses valid entries and defaults', () {
      final cases = <({Map<String, dynamic> yaml, void Function(ScheduledTaskDefinition def) verify})>[
        (
          yaml: {
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
          },
          verify: (def) {
            expect(def.id, 'weekly-report');
            expect(def.cronExpression, '0 9 * * 1');
            expect(def.enabled, true);
            expect(def.title, 'Weekly Report');
            expect(def.description, 'Generate a summary');
            expect(def.type, TaskType.research);
            expect(def.acceptanceCriteria, 'Must include commits');
            expect(def.autoStart, false);
          },
        ),
        (
          yaml: {
            'id': 'minimal',
            'schedule': '* * * * *',
            'task': {'title': 'Minimal Task', 'description': 'A simple task', 'type': 'analysis'},
          },
          verify: (def) {
            expect(def.id, 'minimal');
            expect(def.enabled, true);
            expect(def.autoStart, true);
            expect(def.acceptanceCriteria, isNull);
          },
        ),
        (
          yaml: {
            'id': 'auto',
            'schedule': '0 0 * * *',
            'task': {'title': 'Task', 'description': 'Desc', 'type': 'research'},
          },
          verify: (def) => expect(def.autoStart, true),
        ),
        (
          yaml: {
            'id': 'test',
            'schedule': '0 0 * * *',
            'task': {'title': 'Task', 'description': 'Desc', 'type': 'research'},
          },
          verify: (def) => expect(def.enabled, true),
        ),
      ];

      for (final (:yaml, :verify) in cases) {
        final warnings = <String>[];
        final def = ScheduledTaskDefinition.fromYaml(yaml, warnings);
        expect(def, isNotNull, reason: yaml.toString());
        verify(def!);
        expect(warnings, isEmpty, reason: yaml.toString());
      }
    });

    test('rejects invalid entries with warnings', () {
      final cases = <({Map<String, dynamic> yaml, String warningContains})>[
        (
          yaml: {
            'schedule': '0 0 * * *',
            'task': {'title': 'Task', 'description': 'Desc', 'type': 'research'},
          },
          warningContains: 'id',
        ),
        (
          yaml: {
            'id': '',
            'schedule': '0 0 * * *',
            'task': {'title': 'Task', 'description': 'Desc', 'type': 'research'},
          },
          warningContains: 'id',
        ),
        (
          yaml: {
            'id': 'test',
            'task': {'title': 'Task', 'description': 'Desc', 'type': 'research'},
          },
          warningContains: 'schedule',
        ),
        (
          yaml: {
            'id': 'test',
            'schedule': '0 0 * * *',
            'task': {'description': 'Desc', 'type': 'research'},
          },
          warningContains: 'title',
        ),
        (
          yaml: {
            'id': 'test',
            'schedule': '0 0 * * *',
            'task': {'title': 'Task', 'type': 'research'},
          },
          warningContains: 'description',
        ),
        (
          yaml: {
            'id': 'test',
            'schedule': '0 0 * * *',
            'task': {'title': 'Task', 'description': 'Desc', 'type': 'nonexistent'},
          },
          warningContains: 'nonexistent',
        ),
        (yaml: {'id': 'test', 'schedule': '0 0 * * *'}, warningContains: 'task'),
      ];

      for (final (:yaml, :warningContains) in cases) {
        final warnings = <String>[];
        final def = ScheduledTaskDefinition.fromYaml(yaml, warnings);
        expect(def, isNull, reason: yaml.toString());
        expect(warnings, hasLength(1), reason: yaml.toString());
        expect(warnings.first, contains(warningContains), reason: yaml.toString());
      }
    });

    test('parses optional model, effort, token budget, and task_type alias fields', () {
      final cases = <({Map<String, dynamic> yaml, void Function(ScheduledTaskDefinition def) verify})>[
        (
          yaml: {
            'id': 'test-task',
            'schedule': '0 0 * * *',
            'task': {
              'title': 'Test',
              'description': 'Test task',
              'task_type': 'research',
              'model': 'claude-haiku-4-5',
              'effort': 'low',
              'token_budget': 10000,
            },
          },
          verify: (def) {
            expect(def.type, TaskType.research);
            expect(def.model, 'claude-haiku-4-5');
            expect(def.effort, 'low');
            expect(def.tokenBudget, 10000);
          },
        ),
        (
          yaml: {
            'id': 'test-task',
            'schedule': '0 0 * * *',
            'task': {'title': 'Test', 'description': 'Test task', 'type': 'research'},
          },
          verify: (def) {
            expect(def.model, isNull);
            expect(def.effort, isNull);
            expect(def.tokenBudget, isNull);
          },
        ),
        (
          yaml: {
            'id': 'alias-test',
            'schedule': '0 0 * * *',
            'task': {'title': 'Alias Test', 'description': 'Uses task_type key', 'task_type': 'coding'},
          },
          verify: (def) => expect(def.type, TaskType.coding),
        ),
        (
          yaml: {
            'id': 'precedence-test',
            'schedule': '0 0 * * *',
            'task': {
              'title': 'Precedence Test',
              'description': 'Both keys present',
              'task_type': 'research',
              'type': 'analysis',
            },
          },
          verify: (def) => expect(def.type, TaskType.research),
        ),
      ];

      for (final (:yaml, :verify) in cases) {
        final warnings = <String>[];
        final def = ScheduledTaskDefinition.fromYaml(yaml, warnings);
        expect(def, isNotNull, reason: yaml.toString());
        verify(def!);
        expect(warnings, isEmpty, reason: yaml.toString());
      }
    });
  });

  group('ScheduledTaskDefinition.toJson', () {
    test('serializes required fields and optional omissions', () {
      final cases =
          <
            ({
              ScheduledTaskDefinition def,
              void Function(Map<String, dynamic> json, Map<dynamic, dynamic> taskMap) verify,
            })
          >[
            (
              def: const ScheduledTaskDefinition(
                id: 'weekly',
                cronExpression: '0 9 * * 1',
                enabled: true,
                title: 'Weekly Report',
                description: 'Generate report',
                type: TaskType.research,
                acceptanceCriteria: 'Must include commits',
                autoStart: true,
              ),
              verify: (json, taskMap) {
                expect(json['id'], 'weekly');
                expect(json['schedule'], '0 9 * * 1');
                expect(json['enabled'], true);
                expect(taskMap['title'], 'Weekly Report');
                expect(taskMap['description'], 'Generate report');
                expect(taskMap['type'], 'research');
                expect(taskMap['acceptance_criteria'], 'Must include commits');
                expect(taskMap.containsKey('auto_start'), false);
              },
            ),
            (
              def: const ScheduledTaskDefinition(
                id: 'test',
                cronExpression: '* * * * *',
                title: 'Task',
                description: 'Desc',
                type: TaskType.analysis,
                autoStart: false,
              ),
              verify: (_, taskMap) => expect(taskMap['auto_start'], false),
            ),
            (
              def: const ScheduledTaskDefinition(
                id: 'test',
                cronExpression: '* * * * *',
                title: 'Task',
                description: 'Desc',
                type: TaskType.analysis,
              ),
              verify: (_, taskMap) {
                expect(taskMap.containsKey('acceptance_criteria'), false);
                expect(taskMap.containsKey('model'), false);
                expect(taskMap.containsKey('effort'), false);
                expect(taskMap.containsKey('token_budget'), false);
              },
            ),
            (
              def: const ScheduledTaskDefinition(
                id: 'new-fields',
                cronExpression: '0 0 * * *',
                title: 'New Fields Task',
                description: 'Task with new fields',
                type: TaskType.research,
                model: 'claude-haiku-4-5',
                effort: 'low',
                tokenBudget: 5000,
              ),
              verify: (_, taskMap) {
                expect(taskMap['model'], 'claude-haiku-4-5');
                expect(taskMap['effort'], 'low');
                expect(taskMap['token_budget'], 5000);
                expect(taskMap['type'], 'research');
                expect(taskMap['task_type'], 'research');
              },
            ),
          ];

      for (final (:def, :verify) in cases) {
        final json = def.toJson();
        verify(json, json['task'] as Map<dynamic, dynamic>);
      }
    });

    test('serialized values can be reparsed by fromYaml', () {
      final cases = [
        const ScheduledTaskDefinition(
          id: 'round-trip',
          cronExpression: '0 0 * * *',
          enabled: false,
          title: 'Round Trip',
          description: 'Test round trip',
          type: TaskType.writing,
          acceptanceCriteria: 'Must pass',
          autoStart: false,
        ),
        const ScheduledTaskDefinition(
          id: 'new-fields',
          cronExpression: '0 0 * * *',
          title: 'New Fields Task',
          description: 'Task with new fields',
          type: TaskType.research,
          model: 'claude-haiku-4-5',
          effort: 'low',
          tokenBudget: 5000,
        ),
      ];

      for (final original in cases) {
        final warnings = <String>[];
        final reparsed = ScheduledTaskDefinition.fromYaml(original.toJson(), warnings);

        expect(warnings, isEmpty, reason: original.id);
        expect(reparsed, isNotNull, reason: original.id);
        expect(reparsed!.id, original.id);
        expect(reparsed.cronExpression, original.cronExpression);
        expect(reparsed.enabled, original.enabled);
        expect(reparsed.title, original.title);
        expect(reparsed.description, original.description);
        expect(reparsed.type, original.type);
        expect(reparsed.acceptanceCriteria, original.acceptanceCriteria);
        expect(reparsed.autoStart, original.autoStart);
        expect(reparsed.model, original.model);
        expect(reparsed.effort, original.effort);
        expect(reparsed.tokenBudget, original.tokenBudget);
      }
    });
  });
}
