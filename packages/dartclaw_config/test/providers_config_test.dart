import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

import 'support/load_config.dart';

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
      final config = loadYaml('''
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
      final config = loadYaml('''
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

    test('parses claude approval and sandbox parity options', () {
      final config = loadYaml('''
providers:
  claude:
    executable: claude
    approval: unless-allow-listed
    sandbox: workspace-write
''');

      final options = config.providers['claude']!.options;
      expect(options['approval'], 'unless-allow-listed');
      expect(options['sandbox'], 'workspace-write');
      expect(ClaudeProviderOptions.approval(options), 'unless-allow-listed');
      expect(ClaudeProviderOptions.isFullAccessApproval(options), isFalse);
      expect(ClaudeProviderOptions.coarseSandbox(options), 'workspace-write');
      expect(config.warnings, isEmpty);
    });

    test('approval: never parses, opts into full access, and emits a loud security warning', () {
      final config = loadYaml('''
providers:
  claude:
    executable: claude
    approval: never
''');

      final options = config.providers['claude']!.options;
      expect(options['approval'], 'never');
      expect(ClaudeProviderOptions.isFullAccessApproval(options), isTrue);
      expect(
        config.warnings,
        anyElement(allOf(contains('providers.claude.approval is "never"'), contains('FULL ACCESS'))),
      );
    });

    test('non-full-access approval values do not emit the full-access warning', () {
      final config = loadYaml('''
providers:
  claude:
    executable: claude
    approval: on-request
''');

      expect(config.providers['claude']!.options['approval'], 'on-request');
      expect(config.warnings, isNot(anyElement(contains('FULL ACCESS'))));
    });

    test('warns and drops invalid claude approval / sandbox values', () {
      final config = loadYaml('''
providers:
  claude:
    executable: claude
    approval: yolo
    sandbox: full-send
''');

      final options = config.providers['claude']!.options;
      expect(options.containsKey('approval'), isFalse);
      expect(options.containsKey('sandbox'), isFalse);
      expect(config.warnings, anyElement(contains('providers.claude.approval: "yolo"')));
      expect(config.warnings, anyElement(contains('providers.claude.sandbox: "full-send"')));
    });

    test('preserves a raw map-valued claude sandbox block (advanced passthrough)', () {
      final config = loadYaml('''
providers:
  claude:
    executable: claude
    sandbox:
      enabled: true
      filesystem:
        allowWrite: ["/tmp/build"]
''');

      final sandbox = config.providers['claude']!.options['sandbox'];
      expect(sandbox, isA<Map<dynamic, dynamic>>());
      expect((sandbox as Map<dynamic, dynamic>)['enabled'], isTrue);
      expect(ClaudeProviderOptions.coarseSandbox(config.providers['claude']!.options), isNull);
      expect(config.warnings, isEmpty);
    });

    test('warns and defaults claude inherit_user_settings to true on invalid type', () {
      final config = loadYaml('''
providers:
  claude:
    executable: claude
    inherit_user_settings: project
''');

      expect(config.providers['claude']?.options['inherit_user_settings'], isTrue);
      expect(config.warnings, anyElement(contains('Invalid type for providers.claude.inherit_user_settings')));
    });

    test('defaults pool size to 0 when omitted', () {
      final config = loadYaml('''
providers:
  claude:
    executable: claude
''');

      expect(config.providers['claude']?.poolSize, 0);
      expect(config.providers['claude']?.effectivePoolSize, 1);
    });

    test('warns and defaults negative pool size to effective one', () {
      final config = loadYaml('''
providers:
  claude:
    executable: claude
    pool_size: -1
''');

      expect(config.providers['claude']?.poolSize, 0);
      expect(config.providers['claude']?.effectivePoolSize, 1);
      expect(config.warnings, anyElement(contains('Invalid value for providers.claude.pool_size')));
    });

    test('warns on missing executable field', () {
      final config = loadYaml('''
providers:
  codex:
    sandbox: workspace-write
''');

      expect(config.providers.isEmpty, isTrue);
      expect(config.warnings, anyElement(contains('providers.codex missing "executable"')));
    });

    test('returns empty ProvidersConfig when section absent', () {
      final config = loadYaml('agent:\n  model: sonnet\n');

      expect(config.providers, const ProvidersConfig.defaults());
      expect(config.providers.isEmpty, isTrue);
    });

    test('handles invalid type for providers section', () {
      final config = loadYaml('providers: codex\n');

      expect(config.providers.isEmpty, isTrue);
      expect(config.warnings, anyElement(contains('Invalid type for providers')));
    });
  });
}
