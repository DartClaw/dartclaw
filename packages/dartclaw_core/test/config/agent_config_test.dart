import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

DartclawConfig _loadYaml(String yaml) {
  return DartclawConfig.load(
    configPath: 'dartclaw.yaml',
    fileReader: (path) => path == 'dartclaw.yaml' ? yaml : null,
    env: {'HOME': '/tmp'},
  );
}

void main() {
  group('AgentConfig.provider', () {
    test('defaults to claude', () {
      expect(const AgentConfig.defaults().provider, 'claude');
      expect(const DartclawConfig.defaults().agent.provider, 'claude');
    });

    test('parses agent.provider from YAML', () {
      final config = _loadYaml('''
agent:
  provider: codex
''');

      expect(config.agent.provider, 'codex');
    });

    test('invalid type for agent.provider produces warning and uses default', () {
      final config = _loadYaml('''
agent:
  provider: 42
''');

      expect(config.agent.provider, 'claude');
      expect(config.warnings, anyElement(contains('Invalid type for agent.provider')));
    });
  });
}
