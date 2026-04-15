import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

void main() {
  group('CredentialRegistry', () {
    test('getApiKey returns credential from config for claude', () {
      final registry = CredentialRegistry(
        credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      );

      expect(registry.getApiKey('claude'), 'anthropic-key');
    });

    test('getApiKey returns credential from config for codex', () {
      final registry = CredentialRegistry(
        credentials: const CredentialsConfig(entries: {'openai': CredentialEntry(apiKey: 'openai-key')}),
      );

      expect(registry.getApiKey('codex'), 'openai-key');
    });

    test('getApiKey falls back to env var when config entry missing', () {
      final registry = CredentialRegistry(
        credentials: const CredentialsConfig.defaults(),
        env: const {'ANTHROPIC_API_KEY': 'from-env'},
      );

      expect(registry.getApiKey('claude'), 'from-env');
    });

    test('getApiKey falls back to CODEX_API_KEY for codex when OPENAI_API_KEY is absent', () {
      final registry = CredentialRegistry(
        credentials: const CredentialsConfig.defaults(),
        env: const {'CODEX_API_KEY': 'from-codex-env'},
      );

      expect(registry.getApiKey('codex'), 'from-codex-env');
    });

    test('getApiKey returns null when both config and env missing', () {
      final registry = CredentialRegistry(credentials: const CredentialsConfig.defaults());

      expect(registry.getApiKey('claude'), isNull);
    });

    test('hasCredential returns true when API key available', () {
      final registry = CredentialRegistry(
        credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      );

      expect(registry.hasCredential('claude'), isTrue);
    });

    test('hasCredential returns false when API key unavailable', () {
      final registry = CredentialRegistry(credentials: const CredentialsConfig.defaults());

      expect(registry.hasCredential('claude'), isFalse);
    });

    test('config entry takes precedence over env var', () {
      final registry = CredentialRegistry(
        credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'from-config')}),
        env: const {'ANTHROPIC_API_KEY': 'from-env'},
      );

      expect(registry.getApiKey('claude'), 'from-config');
    });

    test('empty API key in config falls through to env var', () {
      final registry = CredentialRegistry(
        credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: '')}),
        env: const {'ANTHROPIC_API_KEY': 'from-env'},
      );

      expect(registry.getApiKey('claude'), 'from-env');
    });

    test('envVarFor returns expected env var names', () {
      expect(CredentialRegistry.envVarFor('claude'), 'ANTHROPIC_API_KEY');
      expect(CredentialRegistry.envVarFor('codex'), 'CODEX_API_KEY');
      expect(CredentialRegistry.envVarFor('unknown'), isNull);
    });

    test('envVarsFor returns accepted env var names in preference order', () {
      expect(CredentialRegistry.envVarsFor('claude'), ['ANTHROPIC_API_KEY']);
      expect(CredentialRegistry.envVarsFor('codex'), ['CODEX_API_KEY', 'OPENAI_API_KEY']);
      expect(CredentialRegistry.envVarsFor('unknown'), isEmpty);
    });

    test('typed github-token credentials are ignored for provider API-key lookup', () {
      final registry = CredentialRegistry(
        credentials: const CredentialsConfig(
          entries: {'anthropic': CredentialEntry.githubToken(token: 'ghp_token', repository: 'acme/repo')},
        ),
      );

      expect(registry.getApiKey('claude'), isNull);
    });
  });
}
