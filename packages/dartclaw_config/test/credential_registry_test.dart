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

    group('family-aware resolution (provider aliases)', () {
      test('null/matching family degrades to plain getApiKey/envVarsFor', () {
        final registry = CredentialRegistry(
          credentials: const CredentialsConfig.defaults(),
          env: const {'ANTHROPIC_API_KEY': 'from-env'},
        );

        expect(registry.getApiKeyForFamily('claude', null), 'from-env');
        expect(registry.getApiKeyForFamily('claude', 'claude'), 'from-env');
        expect(CredentialRegistry.envVarsForFamily('codex', null), ['CODEX_API_KEY', 'OPENAI_API_KEY']);
        expect(CredentialRegistry.envVarsForFamily('codex', 'codex'), ['CODEX_API_KEY', 'OPENAI_API_KEY']);
      });

      test('resolved family wins and a foreign provider key never leaks through', () {
        final registry = CredentialRegistry(
          credentials: const CredentialsConfig.defaults(),
          env: const {'OPENAI_API_KEY': 'from-openai'},
        );

        // provider `codex` overridden to the claude family: the codex env key
        // must not satisfy a claude-family probe short-circuit.
        expect(registry.getApiKeyForFamily('codex', 'claude'), isNull);
        expect(CredentialRegistry.envVarsForFamily('codex', 'claude'), ['ANTHROPIC_API_KEY']);
      });

      test('family API key is honored for a non-canonical provider alias', () {
        final registry = CredentialRegistry(
          credentials: const CredentialsConfig.defaults(),
          env: const {'OPENAI_API_KEY': 'from-openai'},
        );

        expect(registry.getApiKeyForFamily('my_agent', 'codex'), 'from-openai');
        expect(CredentialRegistry.envVarsForFamily('my_agent', 'codex'), ['CODEX_API_KEY', 'OPENAI_API_KEY']);
      });

      test('falls back to the provider-id key when the resolved family has no known credentials', () {
        final registry = CredentialRegistry(
          credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
        );

        // `unknown` family has no env-var fallbacks, so the claude provider-id
        // key is used rather than being suppressed.
        expect(registry.getApiKeyForFamily('claude', 'unknown'), 'anthropic-key');
        expect(CredentialRegistry.envVarsForFamily('claude', 'unknown'), ['ANTHROPIC_API_KEY']);
      });
    });
  });
}
