import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

import 'support/load_config.dart';

/// Restart-time parsing and validation of the two execution-policy axes.
///
/// Covers Acceptance Scenarios S01 (omitted-default preservation), S02
/// (coexisting explicit selections), and S05 (fail-closed rejection) at the
/// configuration layer.
void main() {
  group('accepted execution selections (S02)', () {
    test('parses agent.execution for the primary agent', () {
      final config = loadYaml('''
container:
  enabled: true
agent:
  execution: host
''');

      expect(config.agent.execution, ExecutionMode.host);
    });

    test('parses a logical-agent execution override independently of the primary', () {
      final config = loadYaml('''
container:
  enabled: true
agent:
  execution: container
  agents:
    coder:
      prompt: write code
      tools: [Read]
      execution: host
    reviewer:
      prompt: review code
      tools: [Read]
''');

      final agents = {for (final definition in config.agent.definitions) definition.id: definition};
      expect(config.agent.execution, ExecutionMode.container);
      expect(agents['coder']!.execution, ExecutionMode.host);
      expect(agents['reviewer']!.execution, isNull, reason: 'omitted override must inherit, not pin a mode');
    });

    test('parses tasks.execution fallbacks keyed by task type', () {
      final config = loadYaml('''
container:
  enabled: true
tasks:
  execution:
    coding: host
    research: container
''');

      expect(config.tasks.execution, {TaskType.coding: ExecutionMode.host, TaskType.research: ExecutionMode.container});
    });
  });

  group('omitted defaults are preserved (S01)', () {
    test('no execution keys leaves every axis unset', () {
      final config = loadNoFile();

      expect(config.agent.execution, isNull);
      expect(config.tasks.execution, isEmpty);
    });

    test('an unrelated tasks section does not invent execution fallbacks', () {
      final config = loadYaml('''
tasks:
  completion_action: accept
''');

      expect(config.tasks.execution, isEmpty);
      expect(config.tasks.completionAction, 'accept');
    });

    test('a logical agent keeps its built-in profile default without an execution key', () {
      final config = loadYaml('''
container:
  enabled: true
agent:
  agents:
    search:
      prompt: search the web
''');

      final search = config.agent.definitions.single;
      expect(search.securityProfile, 'restricted');
      expect(search.execution, isNull);
    });
  });

  group('invalid selections are rejected with their exact YAML path (S05)', () {
    test('unknown primary mode names agent.execution and the accepted values', () {
      expect(
        () => loadYaml('''
agent:
  execution: sandbox
'''),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            allOf(contains('agent.execution'), contains('sandbox'), contains('host'), contains('container')),
          ),
        ),
      );
    });

    test('unknown logical-agent mode names the full agent path', () {
      expect(
        () => loadYaml('''
agent:
  agents:
    coder:
      prompt: write code
      tools: [Read]
      execution: vm
'''),
        throwsA(
          isA<FormatException>().having((error) => error.message, 'message', contains('agent.agents.coder.execution')),
        ),
      );
    });

    test('unknown task-type key names the offending path and the known task types', () {
      expect(
        () => loadYaml('''
tasks:
  execution:
    codingg: host
'''),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            allOf(contains('tasks.execution.codingg'), contains('research')),
          ),
        ),
      );
    });

    test('a task-type key with no value is rejected rather than silently ignored', () {
      expect(
        () => loadYaml('''
tasks:
  execution:
    coding:
'''),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            allOf(contains('tasks.execution.coding'), contains('host'), contains('container')),
          ),
        ),
      );
    });

    test('unknown task-type mode names the task-type path', () {
      expect(
        () => loadYaml('''
tasks:
  execution:
    coding: sandbox
'''),
        throwsA(isA<FormatException>().having((error) => error.message, 'message', contains('tasks.execution.coding'))),
      );
    });
  });

  group('contradictory and unsatisfiable policies are rejected (S05)', () {
    test('host execution paired with an operator-configured container profile is contradictory', () {
      expect(
        () => loadYaml('''
container:
  enabled: true
agent:
  agents:
    coder:
      prompt: write code
      tools: [Read]
      execution: host
      security_profile: restricted
'''),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('agent.agents.coder.execution'),
              contains('agent.agents.coder.security_profile'),
              contains('restricted'),
            ),
          ),
        ),
      );
    });

    test('a built-in profile default never triggers the contradiction rule', () {
      final config = loadYaml('''
container:
  enabled: true
agent:
  agents:
    search:
      prompt: search the web
      execution: host
''');

      final search = config.agent.definitions.single;
      expect(search.execution, ExecutionMode.host);
      expect(search.securityProfile, 'restricted', reason: 'the mode-conditional default is dropped at resolution');
    });

    test('container execution while containers are disabled is rejected, never downgraded to host', () {
      expect(
        () => loadYaml('''
container:
  enabled: false
agent:
  execution: container
'''),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            allOf(contains('agent.execution'), contains('container.enabled')),
          ),
        ),
      );
    });

    test('container execution on a logical agent while containers are disabled is rejected', () {
      expect(
        () => loadYaml('''
agent:
  agents:
    coder:
      prompt: write code
      tools: [Read]
      execution: container
'''),
        throwsA(
          isA<FormatException>().having((error) => error.message, 'message', contains('agent.agents.coder.execution')),
        ),
      );
    });

    test('container execution on a task type while containers are disabled is rejected', () {
      expect(
        () => loadYaml('''
tasks:
  execution:
    coding: container
'''),
        throwsA(isA<FormatException>().having((error) => error.message, 'message', contains('tasks.execution.coding'))),
      );
    });
  });

  group('restart-time metadata', () {
    test('agent.execution is registered as a restart-only enum', () {
      final meta = ConfigMeta.fields['agent.execution']!;

      expect(meta.mutability, ConfigMutability.restart);
      expect(meta.type, ConfigFieldType.enum_);
      expect(meta.allowedValues, ['host', 'container']);
    });
  });

  group('API-path validation refuses an unsatisfiable container selection', () {
    test('container execution is rejected while containers are disabled', () {
      final errors = const ConfigValidator().validate(
        {'agent.execution': 'container'},
        currentValues: {'container.enabled': false},
      );

      expect(errors, hasLength(1));
      expect(errors.single.field, 'agent.execution');
      expect(errors.single.message, contains('container.enabled'));
    });

    test('container execution is accepted when the same write enables containers', () {
      final errors = const ConfigValidator().validate(
        {'agent.execution': 'container', 'container.enabled': true},
        currentValues: const {'container.enabled': false},
      );

      expect(errors.where((error) => error.field == 'agent.execution'), isEmpty);
    });

    test('host execution is always accepted', () {
      expect(
        const ConfigValidator().validate({'agent.execution': 'host'}, currentValues: {'container.enabled': false}),
        isEmpty,
      );
    });

    test('an unknown mode is rejected by the registry enum check', () {
      final errors = const ConfigValidator().validate({'agent.execution': 'sandbox'});

      expect(errors.single.field, 'agent.execution');
    });
  });

  group('value equality', () {
    test('execution mode participates in AgentConfig equality', () {
      expect(
        const AgentConfig(execution: ExecutionMode.host),
        isNot(equals(const AgentConfig(execution: ExecutionMode.container))),
      );
      expect(
        const AgentConfig(execution: ExecutionMode.host),
        equals(const AgentConfig(execution: ExecutionMode.host)),
      );
    });

    test('task-type fallbacks participate in TaskConfig equality', () {
      expect(
        const TaskConfig(execution: {TaskType.coding: ExecutionMode.host}),
        isNot(equals(const TaskConfig.defaults())),
      );
      expect(
        const TaskConfig(execution: {TaskType.coding: ExecutionMode.host}),
        equals(const TaskConfig(execution: {TaskType.coding: ExecutionMode.host})),
      );
    });

    test('execution mode participates in AgentDefinition equality', () {
      const base = AgentDefinition(id: 'coder', description: 'd', prompt: 'p');

      expect(
        base,
        isNot(equals(const AgentDefinition(id: 'coder', description: 'd', prompt: 'p', execution: ExecutionMode.host))),
      );
    });
  });
}
