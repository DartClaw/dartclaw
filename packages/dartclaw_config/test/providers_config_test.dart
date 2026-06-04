import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

DartclawConfig _loadYaml(String yaml) {
  return DartclawConfig.load(
    fileReader: (path) => path == '/tmp/.dartclaw/dartclaw.yaml' ? yaml : null,
    env: {'HOME': '/tmp'},
  );
}

void main() {
  group('ProvidersConfig', () {
    test('value objects support equality and lookups', () {
      const entry = ProviderEntry(executable: 'codex', poolSize: 2, options: {'sandbox': 'workspace-write'});
      const same = ProviderEntry(executable: 'codex', poolSize: 2, options: {'sandbox': 'workspace-write'});
      const config = ProvidersConfig(entries: {'codex': entry});

      expect(entry, equals(same));
      expect(config['codex'], entry);
      expect(config.toString(), contains('codex'));
    });

    test('parses providers section with claude and codex entries', () {
      final config = _loadYaml('''
providers:
  claude:
    executable: claude
    pool_size: 1
  codex:
    executable: codex
    pool_size: 2
    sandbox: workspace-write
    approval: on-request
''');

      expect(config.providers.entries.keys, containsAll(['claude', 'codex']));
      expect(config.providers['claude']?.executable, 'claude');
      expect(config.providers['claude']?.poolSize, 1);
      expect(config.providers['claude']?.options, {'inherit_user_settings': true});
      expect(config.providers['codex']?.poolSize, 2);
      expect(config.providers['codex']?.options, {'sandbox': 'workspace-write', 'approval': 'on-request'});
      expect(config.warnings, isEmpty);
    });

    test('parses claude inherit_user_settings provider option', () {
      final config = _loadYaml('''
providers:
  claude:
    executable: claude
    inherit_user_settings: false
''');

      expect(config.providers['claude']?.options['inherit_user_settings'], isFalse);
      expect(ClaudeProviderOptions.inheritUserSettings(config.providers['claude']!.options), isFalse);
      expect(ClaudeProviderOptions.useProjectSettingSources(config.providers['claude']!.options), isTrue);
      expect(config.warnings, isEmpty);
    });

    test('warns and defaults claude inherit_user_settings to true on invalid type', () {
      final config = _loadYaml('''
providers:
  claude:
    executable: claude
    inherit_user_settings: project
''');

      expect(config.providers['claude']?.options['inherit_user_settings'], isTrue);
      expect(config.warnings, anyElement(contains('Invalid type for providers.claude.inherit_user_settings')));
    });

    test('defaults pool size to 0 when omitted', () {
      final config = _loadYaml('''
providers:
  claude:
    executable: claude
''');

      expect(config.providers['claude']?.poolSize, 0);
    });

    test('warns on missing executable field', () {
      final config = _loadYaml('''
providers:
  codex:
    sandbox: workspace-write
''');

      expect(config.providers.isEmpty, isTrue);
      expect(config.warnings, anyElement(contains('providers.codex missing "executable"')));
    });

    test('returns empty ProvidersConfig when section absent', () {
      final config = _loadYaml('agent:\n  model: sonnet\n');

      expect(config.providers, const ProvidersConfig.defaults());
      expect(config.providers.isEmpty, isTrue);
    });

    test('handles invalid type for providers section', () {
      final config = _loadYaml('providers: codex\n');

      expect(config.providers.isEmpty, isTrue);
      expect(config.warnings, anyElement(contains('Invalid type for providers')));
    });
  });
}
