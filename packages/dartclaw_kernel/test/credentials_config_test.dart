import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'support/load_config.dart';

DartclawConfig _loadYaml(String yaml, {Map<String, String>? env}) =>
    loadYaml(yaml, configPath: 'dartclaw.yaml', env: {'HOME': '/tmp', ...?env});

void main() {
  group('CredentialsConfig', () {
    test('value objects support equality and presence checks', () {
      const entry = CredentialEntry(apiKey: 'secret');
      const same = CredentialEntry(apiKey: 'secret');
      const config = CredentialsConfig(entries: {'anthropic': entry});

      expect(entry, equals(same));
      expect(entry.isPresent, isTrue);
      expect(config['anthropic'], entry);
      expect(config.toString(), contains('anthropic'));
    });

    test('parses credentials section with env var references', () {
      final config = _loadYaml(
        '''
credentials:
  anthropic:
    api_key: \${ANTHROPIC_API_KEY}
  openai:
    api_key: \${OPENAI_API_KEY}
''',
        env: {'ANTHROPIC_API_KEY': 'anthropic-test-key', 'OPENAI_API_KEY': 'openai-test-key'},
      );

      expect(config.credentials['anthropic']?.apiKey, 'anthropic-test-key');
      expect(config.credentials['anthropic']?.envVars, ['ANTHROPIC_API_KEY']);
      expect(config.credentials['openai']?.apiKey, 'openai-test-key');
      expect(config.credentials['openai']?.envVars, ['OPENAI_API_KEY']);
    });

    test('captures env-var provenance for custom-named api-key credentials', () {
      final config = _loadYaml('''
credentials:
  github-ssh:
    api_key: \${MY_CUSTOM_SECRET}
''');

      expect(config.credentials['github-ssh']?.envVars, ['MY_CUSTOM_SECRET']);
    });

    test('captures env-var provenance for github-token credentials', () {
      final config = _loadYaml(
        '''
credentials:
  github-main:
    type: github-token
    token: \${GH_TOKEN}
''',
        env: {'GH_TOKEN': 'secret'},
      );

      expect(config.credentials['github-main']?.token, 'secret');
      expect(config.credentials['github-main']?.envVars, ['GH_TOKEN']);
    });

    test('leaves envVars empty when the credential uses a literal value', () {
      final config = _loadYaml('''
credentials:
  openai:
    api_key: literal-api-key
''');

      expect(config.credentials['openai']?.envVars, isEmpty);
    });

    test('unresolved env var resolves to empty string and logs warning', () async {
      final records = <LogRecord>[];
      final previousLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      final subscription = Logger.root.onRecord.listen(records.add);
      addTearDown(() async {
        Logger.root.level = previousLevel;
        await subscription.cancel();
      });

      final config = _loadYaml('''
credentials:
  anthropic:
    api_key: \${ANTHROPIC_API_KEY}
''');

      await Future<void>.delayed(Duration.zero);

      expect(config.credentials['anthropic']?.apiKey, isEmpty);
      expect(
        records.any((record) => record.loggerName == 'envSubstitute' && record.message.contains('Undefined env var')),
        isTrue,
      );
    });

    test('returns empty CredentialsConfig when section absent', () {
      final config = _loadYaml('agent:\n  model: sonnet\n');

      expect(config.credentials, const CredentialsConfig.defaults());
      expect(config.credentials.isEmpty, isTrue);
    });

    test('handles literal API key values', () {
      final config = _loadYaml('''
credentials:
  openai:
    api_key: literal-api-key
''');

      expect(config.credentials['openai']?.apiKey, 'literal-api-key');
      expect(config.credentials['openai']?.type, CredentialType.apiKey);
    });

    test('parses typed github-token credentials with repository policy', () {
      final config = _loadYaml(
        '''
credentials:
  github-main:
    type: github-token
    token: \${GITHUB_TOKEN}
    repository: acme/platform
''',
        env: {'GITHUB_TOKEN': 'ghp_token'},
      );

      final entry = config.credentials['github-main'];
      expect(entry, isNotNull);
      expect(entry?.type, CredentialType.githubToken);
      expect(entry?.token, 'ghp_token');
      expect(entry?.repository, 'acme/platform');
    });

    test('handles missing api_key field in credential entry', () {
      final config = _loadYaml('''
credentials:
  anthropic:
    token: nope
''');

      expect(config.credentials.isEmpty, isTrue);
      expect(config.warnings, anyElement(contains('credentials.anthropic missing "api_key"')));
    });

    test('handles invalid type for credentials section', () {
      final config = _loadYaml('credentials: nope\n');

      expect(config.credentials.isEmpty, isTrue);
      expect(config.warnings, anyElement(contains('Invalid type for credentials')));
    });

    test('warns on missing github-token token field', () {
      final config = _loadYaml('''
credentials:
  github-main:
    type: github-token
''');

      expect(config.credentials.isEmpty, isTrue);
      expect(config.warnings, anyElement(contains('credentials.github-main missing "token"')));
    });
  });

  group('subscription credentials', () {
    final issuedAt = DateTime.utc(2026, 8, 14, 9);
    final expiry = CredentialExpiry(issuedAt: issuedAt, expiresAt: DateTime.utc(2027, 8, 14, 9), derived: true);

    test('round-trips issued-at, expiry and derived flag through equality', () {
      final entry = CredentialEntry.subscription(token: 'sk-ant-oat01-secret', expiry: expiry);
      final same = CredentialEntry.subscription(
        token: 'sk-ant-oat01-secret',
        expiry: CredentialExpiry(issuedAt: issuedAt, expiresAt: DateTime.utc(2027, 8, 14, 9), derived: true),
      );

      expect(entry.expiry?.issuedAt, issuedAt);
      expect(entry.expiry?.expiresAt, DateTime.utc(2027, 8, 14, 9));
      expect(entry.expiry?.derived, isTrue);
      expect(entry, equals(same));
      expect(entry.hashCode, equals(same.hashCode));
    });

    test('a differing derived flag or expiry makes entries unequal', () {
      final derived = CredentialEntry.subscription(token: 'token', expiry: expiry);
      final exact = CredentialEntry.subscription(
        token: 'token',
        expiry: CredentialExpiry(issuedAt: issuedAt, expiresAt: DateTime.utc(2027, 8, 14, 9), derived: false),
      );
      final later = CredentialEntry.subscription(
        token: 'token',
        expiry: CredentialExpiry(issuedAt: issuedAt, expiresAt: DateTime.utc(2027, 9, 14, 9), derived: true),
      );

      expect(derived, isNot(equals(exact)));
      expect(derived, isNot(equals(later)));
    });

    test('reports itself as a subscription credential', () {
      final entry = CredentialEntry.subscription(token: 'token', expiry: expiry);

      expect(entry.type, CredentialType.subscription);
      expect(entry.isSubscriptionCredential, isTrue);
      expect(entry.isApiKeyCredential, isFalse);
      expect(entry.isPresent, isTrue);
      expect(const CredentialEntry(apiKey: 'k').isSubscriptionCredential, isFalse);
    });

    test('toString leaks neither the token nor its prefix', () {
      final claude = CredentialEntry.subscription(token: 'sk-ant-oat01-abcdef123456', expiry: expiry);
      final codex = CredentialEntry.subscription(token: 'eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjF9.signature');

      expect(claude.toString(), isNot(contains('sk-ant')));
      expect(claude.toString(), isNot(contains('abcdef123456')));
      expect(claude.toString(), contains('***'));
      expect(claude.toString(), contains('derived: true'));
      expect(codex.toString(), isNot(contains('eyJ')));
    });

    test('YAML cannot declare a subscription credential', () {
      final config = _loadYaml('''
credentials:
  anthropic:
    type: subscription
    api_key: sk-ant-oat01-from-yaml
''');

      expect(config.credentials.isEmpty, isTrue);
      expect(config.warnings, contains('credentials.anthropic has unknown "type" – skipping'));
    });
  });
}
