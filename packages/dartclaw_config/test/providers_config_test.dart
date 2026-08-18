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

    test('direct construction retains normalized lookup compatibility', () {
      const entry = ProviderEntry(executable: 'codex');
      const config = ProvidersConfig(entries: {' Codex ': entry});

      expect(config['codex'], same(entry));
    });

    test('direct construction never routes blank IDs to the default provider', () {
      const entry = ProviderEntry(executable: 'claude');
      const config = ProvidersConfig(entries: {'claude': entry, ' ': entry});

      expect(config[' '], isNull);
      expect(const ProvidersConfig(entries: {' ': entry})['claude'], isNull);
    });

    test('direct construction rejects normalized lookup collisions', () {
      const first = ProviderEntry(executable: 'codex-first');
      const second = ProviderEntry(executable: 'codex-second');
      const config = ProvidersConfig(entries: {'Codex': first, ' codex ': second});

      expect(() => config['codex'], throwsStateError);
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

    test('normalizes provider IDs and rejects normalization collisions', () {
      final config = loadYaml('''
providers:
  OpenAI-Work:
    executable: codex-first
  openai-work:
    executable: codex-second
''');

      expect(config.providers.entries.keys, ['openai-work']);
      expect(config.providers['OPENAI-WORK']?.executable, 'codex-first');
      expect(config.warnings, anyElement(contains('collides with another provider after normalization')));
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

  group('providers.<id>.auth', () {
    test('parses the three accepted values and defaults to auto', () {
      final config = loadYaml('''
providers:
  claude:
    executable: claude
    auth: subscription
  codex:
    executable: codex
    auth: api_key
  other:
    executable: other
    auth: auto
  unset:
    executable: unset
''');

      expect(config.providers['claude']?.auth, ProviderAuth.subscription);
      expect(config.providers['codex']?.auth, ProviderAuth.apiKey);
      expect(config.providers['other']?.auth, ProviderAuth.auto);
      // Unset stays null and is distinct from an explicit `auto`, so an alias
      // can inherit its family's selection.
      expect(config.providers['unset']?.auth, isNull);
      expect(config.warnings, isEmpty);
    });

    test('auth is a typed field, not an untyped option', () {
      final config = loadYaml('''
providers:
  claude:
    executable: claude
    auth: subscription
''');

      expect(config.providers['claude']?.options, isNot(contains('auth')));
    });

    test('an unrecognized value blocks reload and names the accepted values', () {
      final config = loadYaml('''
providers:
  claude:
    executable: claude
    auth: nonsense
''');

      // Blocking (`warns.add`), not advisory — a typo must not be reloadable.
      expect(
        config.reloadBlockingWarnings,
        anyElement(
          allOf(contains('providers.claude.auth: "nonsense"'), contains('accepted: auto, subscription, api_key')),
        ),
      );
      expect(config.providers['claude']?.auth, ProviderAuth.unrecognized);
    });

    test('casing and surrounding whitespace are normalized, not treated as typos', () {
      final config = loadYaml('''
providers:
  claude:
    executable: claude
    auth: "  Subscription "
  codex:
    executable: codex
    auth: API_KEY
''');

      expect(config.providers['claude']?.auth, ProviderAuth.subscription);
      expect(config.providers['codex']?.auth, ProviderAuth.apiKey);
      expect(config.reloadBlockingWarnings, isEmpty);
    });

    test('a non-string value is unrecognized rather than silently defaulted', () {
      final config = loadYaml('''
providers:
  claude:
    executable: claude
    auth: true
''');

      expect(config.providers['claude']?.auth, ProviderAuth.unrecognized);
      expect(config.reloadBlockingWarnings, anyElement(contains('providers.claude.auth')));
    });

    test('entries differing only in auth are unequal', () {
      const unset = ProviderEntry(executable: 'claude');
      const forced = ProviderEntry(executable: 'claude', auth: ProviderAuth.subscription);
      const explicitAuto = ProviderEntry(executable: 'claude', auth: ProviderAuth.auto);

      expect(unset.auth, isNull);
      expect(unset, isNot(equals(forced)));
      expect(unset.hashCode, isNot(equals(forced.hashCode)));
      // An explicit `auto` is the operator's own choice, not an unset value.
      expect(unset, isNot(equals(explicitAuto)));
      expect(forced.toString(), contains('auth: subscription'));
    });

    test('copyWith carries every unnamed field, so a rebuild cannot drop auth', () {
      const forced = ProviderEntry(
        executable: 'codex',
        poolSize: 3,
        auth: ProviderAuth.subscription,
        options: {'sandbox': 'workspace-write'},
      );

      final rebuilt = forced.copyWith(options: const {'sandbox': 'read-only'});

      // A rebuild site that dropped `auth` would present the wrong credential
      // while every other field still looked right.
      expect(rebuilt.auth, ProviderAuth.subscription);
      expect(rebuilt.executable, 'codex');
      expect(rebuilt.poolSize, 3);
      expect(rebuilt.options, {'sandbox': 'read-only'});

      // An unset `auth` stays unset — materializing `auto` here would defeat
      // the family inheritance an alias depends on.
      const unset = ProviderEntry(executable: 'codex');
      expect(unset.copyWith(options: const {'sandbox': 'read-only'}).auth, isNull);
    });
  });
}
