import 'package:dartclaw_config/dartclaw_config.dart';
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
}
