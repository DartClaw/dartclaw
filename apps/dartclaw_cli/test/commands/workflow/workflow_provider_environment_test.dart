import 'package:dartclaw_cli/src/commands/workflow/workflow_provider_environment.dart';
import 'package:dartclaw_config/dartclaw_config.dart'
    show CredentialEntry, CredentialRegistry, CredentialsConfig, ProviderAuth, ProviderEntry, ProvidersConfig;
import 'package:test/test.dart';

const _storedSetupToken = 'sk-ant-oat01-STORED-SENTINEL';

void main() {
  CredentialRegistry registry({
    Map<String, String> env = const {},
    Map<String, CredentialEntry> subscriptions = const {},
    ProvidersConfig providers = const ProvidersConfig.defaults(),
  }) => CredentialRegistry(
    credentials: const CredentialsConfig(),
    env: env,
    providers: providers,
    subscriptions: subscriptions,
  );

  Map<String, CredentialEntry> storedClaudeToken([String token = _storedSetupToken]) => {
    'claude': CredentialEntry.subscription(token: token),
  };

  group('codex subscription mediation', () {
    final forcedCodexSubscription = ProvidersConfig(
      entries: {'codex': ProviderEntry(executable: 'codex', auth: ProviderAuth.subscription)},
    );

    test('a subscription-resolved codex spawn presents no API key at all', () {
      // The subscription is presented by pointing CODEX_HOME at the dedicated
      // store; also overlaying OPENAI_API_KEY would hand the vendor CLI the
      // credential the resolution ruled out, and it would authenticate on that.
      final env = buildWorkflowProviderEnvironment(
        providerId: 'codex',
        providerFamily: 'codex',
        registry: registry(
          env: const {'OPENAI_API_KEY': 'sk-configured'},
          providers: forcedCodexSubscription,
          subscriptions: {'codex': CredentialEntry.subscription(token: 'chatgpt-access-token')},
        ),
        baseEnvironment: const {'USER': 'tobias'},
      );

      expect(env.containsKey('OPENAI_API_KEY'), isFalse);
      expect(env['USER'], 'tobias');
    });

    test('an api-key-resolved codex spawn still presents the key', () {
      final env = buildWorkflowProviderEnvironment(
        providerId: 'codex',
        providerFamily: 'codex',
        registry: registry(env: const {'OPENAI_API_KEY': 'sk-configured'}),
        baseEnvironment: const {},
      );

      expect(env['OPENAI_API_KEY'], 'sk-configured');
    });

    test('a forced codex subscription with nothing stored presents nothing', () {
      final env = buildWorkflowProviderEnvironment(
        providerId: 'codex',
        providerFamily: 'codex',
        registry: registry(env: const {'OPENAI_API_KEY': 'sk-configured'}, providers: forcedCodexSubscription),
        baseEnvironment: const {},
      );

      expect(env.containsKey('OPENAI_API_KEY'), isFalse);
    });
  });

  group('buildWorkflowProviderEnvironment subscription mediation', () {
    test('presents the stored setup-token and no API key variable', () {
      final env = buildWorkflowProviderEnvironment(
        providerId: 'claude',
        providerFamily: 'claude',
        registry: registry(subscriptions: storedClaudeToken()),
        baseEnvironment: const {'USER': 'tobias'},
      );

      expect(env['CLAUDE_CODE_OAUTH_TOKEN'], _storedSetupToken);
      expect(env['ANTHROPIC_API_KEY'], isNull);
      expect(env['USER'], 'tobias', reason: 'the keychain-OAuth invariant must survive the credential overlay');
    });

    test("replaces an operator's own inherited OAuth token with the stored one", () {
      // The sanitize pass strips every inherited `*_TOKEN`, so the store is
      // authoritative and a stale shell value cannot shadow it.
      final env = buildWorkflowProviderEnvironment(
        providerId: 'claude',
        providerFamily: 'claude',
        registry: registry(subscriptions: storedClaudeToken()),
        baseEnvironment: const {'USER': 'tobias', 'CLAUDE_CODE_OAUTH_TOKEN': 'operator-shell-value'},
      );

      expect(env['CLAUDE_CODE_OAUTH_TOKEN'], _storedSetupToken);
    });

    test('drops an inherited OAuth token when no credential is stored', () {
      final env = buildWorkflowProviderEnvironment(
        providerId: 'claude',
        providerFamily: 'claude',
        registry: registry(),
        baseEnvironment: const {'USER': 'tobias', 'CLAUDE_CODE_OAUTH_TOKEN': 'operator-shell-value'},
      );

      expect(env['CLAUDE_CODE_OAUTH_TOKEN'], isNull);
    });

    test('an API-key deployment presents the key and no OAuth variable', () {
      final env = buildWorkflowProviderEnvironment(
        providerId: 'claude',
        providerFamily: 'claude',
        registry: registry(env: {'ANTHROPIC_API_KEY': 'sk-ant-test'}),
        baseEnvironment: const {'USER': 'tobias'},
      );

      expect(env['ANTHROPIC_API_KEY'], 'sk-ant-test');
      expect(env['CLAUDE_CODE_OAUTH_TOKEN'], isNull);
    });

    test('auth: api_key presents the key even with a token stored', () {
      final env = buildWorkflowProviderEnvironment(
        providerId: 'claude',
        providerFamily: 'claude',
        registry: registry(
          env: {'ANTHROPIC_API_KEY': 'sk-ant-test'},
          subscriptions: storedClaudeToken(),
          providers: ProvidersConfig(
            entries: {'claude': ProviderEntry(executable: 'claude', auth: ProviderAuth.apiKey)},
          ),
        ),
        baseEnvironment: const {'USER': 'tobias'},
      );

      expect(env['ANTHROPIC_API_KEY'], 'sk-ant-test');
      expect(env['CLAUDE_CODE_OAUTH_TOKEN'], isNull);
    });

    test('an unsatisfiable auth selection presents nothing, not the ruled-out key', () {
      // An operator who pinned `subscription` to keep a metered key out of the
      // loop must not be silently billed on it because the token is missing.
      final env = buildWorkflowProviderEnvironment(
        providerId: 'claude',
        providerFamily: 'claude',
        registry: registry(
          env: {'ANTHROPIC_API_KEY': 'sk-ant-metered'},
          providers: ProvidersConfig(
            entries: {'claude': ProviderEntry(executable: 'claude', auth: ProviderAuth.subscription)},
          ),
        ),
        baseEnvironment: const {'USER': 'tobias'},
      );

      expect(env['ANTHROPIC_API_KEY'], isNull);
      expect(env['CLAUDE_CODE_OAUTH_TOKEN'], isNull);
    });

    test('an unrecognized auth value presents nothing', () {
      final env = buildWorkflowProviderEnvironment(
        providerId: 'claude',
        providerFamily: 'claude',
        registry: registry(
          env: {'ANTHROPIC_API_KEY': 'sk-ant-metered'},
          subscriptions: storedClaudeToken(),
          providers: ProvidersConfig(
            entries: {'claude': ProviderEntry(executable: 'claude', auth: ProviderAuth.unrecognized)},
          ),
        ),
        baseEnvironment: const {'USER': 'tobias'},
      );

      expect(env['ANTHROPIC_API_KEY'], isNull);
      expect(env['CLAUDE_CODE_OAUTH_TOKEN'], isNull);
    });

    test('a claude-family provider alias presents the stored token', () {
      // The family, not the id, decides: an alias resolved to the claude CLI is
      // the same spawn as `claude` and must present the same credential.
      final env = buildWorkflowProviderEnvironment(
        providerId: 'my_claude',
        providerFamily: 'claude',
        registry: registry(subscriptions: storedClaudeToken()),
        baseEnvironment: const {'USER': 'tobias'},
      );

      expect(env['CLAUDE_CODE_OAUTH_TOKEN'], _storedSetupToken);
    });

    test('a claude-family alias with only a key presents that key', () {
      // Resolution and overlay must agree on the family, or resolution reports a
      // credential present while the spawn goes out with none.
      final env = buildWorkflowProviderEnvironment(
        providerId: 'my_claude',
        providerFamily: 'claude',
        registry: registry(env: {'ANTHROPIC_API_KEY': 'sk-ant-test'}),
        baseEnvironment: const {'USER': 'tobias'},
      );

      expect(env['ANTHROPIC_API_KEY'], 'sk-ant-test');
    });

    test('a codex-family spawn is untouched by a stored claude token', () {
      final env = buildWorkflowProviderEnvironment(
        providerId: 'codex',
        providerFamily: 'codex',
        registry: registry(env: {'OPENAI_API_KEY': 'sk-openai-test'}, subscriptions: storedClaudeToken()),
        baseEnvironment: const {'USER': 'tobias'},
      );

      expect(env['CLAUDE_CODE_OAUTH_TOKEN'], isNull);
      expect(env['OPENAI_API_KEY'], 'sk-openai-test');
    });
  });

  group('buildWorkflowProviderEnvironment', () {
    test('preserves USER from the parent environment (keychain OAuth invariant)', () {
      final env = buildWorkflowProviderEnvironment(
        providerId: 'claude',
        providerFamily: 'claude',
        registry: registry(),
        baseEnvironment: const {'USER': 'tobias', 'HOME': '/home/tobias', 'PATH': '/usr/bin'},
      );

      expect(env['USER'], 'tobias');
    });

    test('strips inherited provider subagent model controls', () {
      final env = buildWorkflowProviderEnvironment(
        providerId: 'claude',
        providerFamily: 'claude',
        registry: registry(),
        baseEnvironment: const {'USER': 'tobias', 'CLAUDE_CODE_SUBAGENT_MODEL': 'inherited-model'},
      );

      expect(env['CLAUDE_CODE_SUBAGENT_MODEL'], isNull);
    });

    test('overlays a configured API key onto its accepted env vars', () {
      final env = buildWorkflowProviderEnvironment(
        providerId: 'claude',
        providerFamily: 'claude',
        registry: registry(env: {'ANTHROPIC_API_KEY': 'sk-ant-test'}),
        baseEnvironment: const {'USER': 'tobias'},
      );

      expect(env['ANTHROPIC_API_KEY'], 'sk-ant-test');
      expect(env['USER'], 'tobias');
      expect(env['CLAUDE_CODE_SUBPROCESS_ENV_SCRUB'], '1');
    });

    test('overlays a family API key for provider aliases', () {
      final env = buildWorkflowProviderEnvironment(
        providerId: 'my_agent',
        providerFamily: 'codex',
        registry: registry(env: {'OPENAI_API_KEY': 'sk-openai-test'}),
        baseEnvironment: const {'USER': 'tobias'},
      );

      expect(env['OPENAI_API_KEY'], 'sk-openai-test');
      expect(env['CODEX_API_KEY'], 'sk-openai-test');
      expect(env['USER'], 'tobias');
      expect(env['CLAUDE_CODE_SUBPROCESS_ENV_SCRUB'], isNull);
    });

    test('resolved family key wins over provider-id key family', () {
      final env = buildWorkflowProviderEnvironment(
        providerId: 'codex',
        providerFamily: 'claude',
        registry: registry(env: {'OPENAI_API_KEY': 'sk-openai-test', 'ANTHROPIC_API_KEY': 'sk-ant-test'}),
        baseEnvironment: const {'USER': 'tobias'},
      );

      expect(env['ANTHROPIC_API_KEY'], 'sk-ant-test');
      expect(env['OPENAI_API_KEY'], isNull);
      expect(env['CODEX_API_KEY'], isNull);
    });

    test('provider-id key does not overlay when resolved family key is missing', () {
      final env = buildWorkflowProviderEnvironment(
        providerId: 'codex',
        providerFamily: 'claude',
        registry: registry(env: {'OPENAI_API_KEY': 'sk-openai-test'}),
        baseEnvironment: const {'USER': 'tobias'},
      );

      expect(env['ANTHROPIC_API_KEY'], isNull);
      expect(env['OPENAI_API_KEY'], isNull);
      expect(env['CODEX_API_KEY'], isNull);
    });
  });
}
