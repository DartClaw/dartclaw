import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

import 'support/load_config.dart';

void main() {
  group('AgentConfig.provider', () {
    test('defaults to claude', () {
      expect(const AgentConfig.defaults().provider, 'claude');
      expect(const DartclawConfig.defaults().agent.provider, 'claude');
    });

    test('parses agent.provider from YAML', () {
      final config = loadYaml(
        '''
agent:
  provider: codex
''',
        configPath: 'dartclaw.yaml',
        env: const {'HOME': '/tmp'},
      );

      expect(config.agent.provider, 'codex');
    });

    test('normalizes mixed-case agent.provider at parse time', () {
      final config = loadYaml(
        '''
agent:
  provider: " Codex "
''',
        configPath: 'dartclaw.yaml',
        env: const {'HOME': '/tmp'},
      );

      expect(config.agent.provider, 'codex');
    });

    test('rejects a blank agent.provider', () {
      expect(
        () => loadYaml(
          '''
agent:
  provider: " "
''',
          configPath: 'dartclaw.yaml',
          env: const {'HOME': '/tmp'},
        ),
        throwsFormatException,
      );
    });

    test('invalid type for agent.provider produces warning and uses default', () {
      final config = loadYaml(
        '''
agent:
  provider: 42
''',
        configPath: 'dartclaw.yaml',
        env: const {'HOME': '/tmp'},
      );

      expect(config.agent.provider, 'claude');
      expect(config.warnings, anyElement(contains('Invalid type for provider')));
    });
  });

  test('parses optional provider and security profile for each logical agent', () {
    final config = loadYaml(
      '''
agent:
  provider: claude
  agents:
    reviewer:
      provider: codex
      security_profile: workspace
      prompt: Review the change
      tools: [file_read]
''',
      configPath: 'dartclaw.yaml',
      env: const {'HOME': '/tmp'},
    );

    expect(config.agent.definitions.single.provider, 'codex');
    expect(config.agent.definitions.single.securityProfile, 'workspace');
  });

  test('removed delegation config warns and creates no parallel agent model', () {
    final config = loadYaml(
      '''
delegation:
  enabled: true
  agents:
    - id: reviewer
''',
      configPath: 'dartclaw.yaml',
      env: const {'HOME': '/tmp'},
    );

    expect(config.agent.definitions, isEmpty);
    expect(config.warnings, anyElement(contains('define logical agents under agent.agents')));
    expect(config.warnings, isNot(anyElement(contains('Unknown config key: delegation'))));
  });

  test('removed logical-agent controls emit migration warnings', () {
    final config = loadYaml(
      '''
agent:
  agents:
    reviewer:
      tools: [file_read]
      max_spawn_depth: 2
      max_children_per_agent: 4
      max_concurrent: 3
      session_store_path: custom-sessions
''',
      configPath: 'dartclaw.yaml',
      env: const {'HOME': '/tmp'},
    );

    for (final key in const ['max_spawn_depth', 'max_children_per_agent', 'max_concurrent', 'session_store_path']) {
      expect(config.warnings, anyElement(contains('Ignoring removed agent.agents.reviewer.$key')));
    }
    expect(config.agent.definitions.single.allowedTools, {'file_read'});
  });

  test('history bounds keep their exact warnings and independent defaults', () {
    final config = loadYaml('''
agent:
  history:
    max_message_chars: 100
    max_total_chars: 1000
''');

    const defaults = HistoryConfig.defaults();
    expect(config.agent.history, defaults);
    expect(config.warnings, [
      'Invalid agent.history.max_message_chars: 100 (must be int >= 500) — using default',
      'Invalid agent.history.max_total_chars: 1000 (must be int >= 5000) — using default',
    ]);
  });
}
