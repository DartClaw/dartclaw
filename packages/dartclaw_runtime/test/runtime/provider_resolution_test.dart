import 'package:dartclaw_acp/dartclaw_acp.dart';
import 'package:dartclaw_runtime/src/runtime/provider_resolution.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
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

  /// Drives the shared seam with a target built straight from the family under
  /// test, so a case can pin an id/family pair the resolver would never produce
  /// — that mismatch is what the family-agreement cases exist to catch.
  Map<String, String> spawnEnvironment({
    required String providerId,
    required String providerFamily,
    required CredentialRegistry registry,
    required Map<String, String> baseEnvironment,
  }) => buildProviderSpawnEnvironment(
    target: ResolvedProviderTarget(
      providerId: providerId,
      executable: providerFamily,
      options: const {},
      family: providerFamily,
    ),
    registry: registry,
    baseEnvironment: baseEnvironment,
  );

  group('codex subscription mediation', () {
    final forcedCodexSubscription = ProvidersConfig(
      entries: {'codex': ProviderEntry(executable: 'codex', auth: ProviderAuth.subscription)},
    );

    test('a subscription-resolved codex spawn presents no API key at all', () {
      // The subscription is presented by pointing CODEX_HOME at the dedicated
      // store; also overlaying OPENAI_API_KEY would hand the vendor CLI the
      // credential the resolution ruled out, and it would authenticate on that.
      final env = spawnEnvironment(
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
      final env = spawnEnvironment(
        providerId: 'codex',
        providerFamily: 'codex',
        registry: registry(env: const {'OPENAI_API_KEY': 'sk-configured'}),
        baseEnvironment: const {},
      );

      expect(env['OPENAI_API_KEY'], 'sk-configured');
    });

    test('a forced codex subscription with nothing stored presents nothing', () {
      final env = spawnEnvironment(
        providerId: 'codex',
        providerFamily: 'codex',
        registry: registry(env: const {'OPENAI_API_KEY': 'sk-configured'}, providers: forcedCodexSubscription),
        baseEnvironment: const {},
      );

      expect(env.containsKey('OPENAI_API_KEY'), isFalse);
    });
  });

  group('spawn environment subscription mediation', () {
    test('presents the stored setup-token and no API key variable', () {
      final env = spawnEnvironment(
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
      final env = spawnEnvironment(
        providerId: 'claude',
        providerFamily: 'claude',
        registry: registry(subscriptions: storedClaudeToken()),
        baseEnvironment: const {'USER': 'tobias', 'CLAUDE_CODE_OAUTH_TOKEN': 'operator-shell-value'},
      );

      expect(env['CLAUDE_CODE_OAUTH_TOKEN'], _storedSetupToken);
    });

    test('drops an inherited OAuth token when no credential is stored', () {
      final env = spawnEnvironment(
        providerId: 'claude',
        providerFamily: 'claude',
        registry: registry(),
        baseEnvironment: const {'USER': 'tobias', 'CLAUDE_CODE_OAUTH_TOKEN': 'operator-shell-value'},
      );

      expect(env['CLAUDE_CODE_OAUTH_TOKEN'], isNull);
    });

    test('an API-key deployment presents the key and no OAuth variable', () {
      final env = spawnEnvironment(
        providerId: 'claude',
        providerFamily: 'claude',
        registry: registry(env: {'ANTHROPIC_API_KEY': 'sk-ant-test'}),
        baseEnvironment: const {'USER': 'tobias'},
      );

      expect(env['ANTHROPIC_API_KEY'], 'sk-ant-test');
      expect(env['CLAUDE_CODE_OAUTH_TOKEN'], isNull);
    });

    test('auth: api_key presents the key even with a token stored', () {
      final env = spawnEnvironment(
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
      final env = spawnEnvironment(
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
      final env = spawnEnvironment(
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
      final env = spawnEnvironment(
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
      final env = spawnEnvironment(
        providerId: 'my_claude',
        providerFamily: 'claude',
        registry: registry(env: {'ANTHROPIC_API_KEY': 'sk-ant-test'}),
        baseEnvironment: const {'USER': 'tobias'},
      );

      expect(env['ANTHROPIC_API_KEY'], 'sk-ant-test');
    });

    test('a codex-family spawn is untouched by a stored claude token', () {
      final env = spawnEnvironment(
        providerId: 'codex',
        providerFamily: 'codex',
        registry: registry(env: {'OPENAI_API_KEY': 'sk-openai-test'}, subscriptions: storedClaudeToken()),
        baseEnvironment: const {'USER': 'tobias'},
      );

      expect(env['CLAUDE_CODE_OAUTH_TOKEN'], isNull);
      expect(env['OPENAI_API_KEY'], 'sk-openai-test');
    });
  });

  group('spawn environment sanitize', () {
    test('preserves USER from the parent environment (keychain OAuth invariant)', () {
      final env = spawnEnvironment(
        providerId: 'claude',
        providerFamily: 'claude',
        registry: registry(),
        baseEnvironment: const {'USER': 'tobias', 'HOME': '/home/tobias', 'PATH': '/usr/bin'},
      );

      expect(env['USER'], 'tobias');
    });

    test('strips inherited provider subagent model controls', () {
      final env = spawnEnvironment(
        providerId: 'claude',
        providerFamily: 'claude',
        registry: registry(),
        baseEnvironment: const {'USER': 'tobias', 'CLAUDE_CODE_SUBAGENT_MODEL': 'inherited-model'},
      );

      expect(env['CLAUDE_CODE_SUBAGENT_MODEL'], isNull);
    });

    test('overlays a configured API key onto its accepted env vars', () {
      final env = spawnEnvironment(
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
      final env = spawnEnvironment(
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
      final env = spawnEnvironment(
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
      final env = spawnEnvironment(
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

  group('resolveProviderTarget', () {
    DartclawConfig configWith({ProvidersConfig? providers}) => DartclawConfig(
      server: const ServerConfig(claudeExecutable: '/opt/claude'),
      providers: providers ?? const ProvidersConfig.defaults(),
    );

    test('a config entry supplies the executable and its options', () {
      final target = resolveProviderTarget(
        configWith(
          providers: ProvidersConfig(
            entries: {
              'claude': ProviderEntry(executable: '/usr/local/bin/claude', options: const {'approval': 'on-request'}),
            },
          ),
        ),
        'claude',
      );

      expect(target.executable, '/usr/local/bin/claude');
      expect(target.options, {'approval': 'on-request'});
      expect(target.registeredEntry, isNull);
    });

    test('a registrar-owned provider supplies its binary and travels with the target', () {
      final target = resolveProviderTarget(
        configWith(),
        'goose',
        registeredProviders: const {'goose': ProviderEntry(executable: '/opt/goose')},
      );

      expect(target.executable, '/opt/goose');
      expect(target.registeredEntry?.executable, '/opt/goose');
      expect(target.isRegistered, isTrue);
    });

    test('a bare provider id falls back to its family default', () {
      expect(resolveProviderTarget(configWith(), 'claude').executable, '/opt/claude');
      expect(resolveProviderTarget(configWith(), 'codex').executable, 'codex');
      expect(resolveProviderTarget(configWith(), 'my_agent').executable, 'my_agent');
    });

    test('an alias whose executable names claude resolves to the claude family', () {
      // Name-only family derivation answers `my_claude` here, and an aliased
      // Claude provider would then spawn with no credential at all.
      final target = resolveProviderTarget(
        configWith(
          providers: ProvidersConfig(entries: {'my_claude': ProviderEntry(executable: 'claude')}),
        ),
        'my_claude',
      );

      expect(target.family, 'claude');
    });
  });

  group('spawn environment hardening and ownership', () {
    ResolvedProviderTarget target(String family, {ProviderEntry? registeredEntry}) => ResolvedProviderTarget(
      providerId: family,
      executable: family,
      options: const {},
      family: family,
      registeredEntry: registeredEntry,
    );

    test('a claude-family target carries the full hardening set', () {
      final env = buildProviderSpawnEnvironment(
        target: target('claude'),
        registry: registry(),
        baseEnvironment: const {'USER': 'tobias'},
      );

      expect(env['CLAUDE_CODE_SUBPROCESS_ENV_SCRUB'], '1');
      expect(env['DISABLE_AUTOUPDATER'], '1');
      expect(env['CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC'], '1');
    });

    test('a codex-family target carries none of them', () {
      final env = buildProviderSpawnEnvironment(
        target: target('codex'),
        registry: registry(),
        baseEnvironment: const {'USER': 'tobias'},
      );

      expect(env['CLAUDE_CODE_SUBPROCESS_ENV_SCRUB'], isNull);
      expect(env['DISABLE_AUTOUPDATER'], isNull);
      expect(env['CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC'], isNull);
    });

    test('request extras cannot introduce absent built-in credential or hardening keys', () {
      final env = sanitizeProviderRequestEnvironment({
        'ANTHROPIC_API_KEY': 'step-key',
        'CLAUDE_CODE_OAUTH_TOKEN': 'step-token',
        'claude_code_disable_nonessential_traffic': '0',
        'codex_home': '/tmp/step-home',
        'DARTCLAW_STEP_ARTIFACTS_DIR': '/tmp/artifacts',
      });

      expect(env, {'DARTCLAW_STEP_ARTIFACTS_DIR': '/tmp/artifacts'});
    });

    test('request extras cannot introduce an absent registrar-owned credential key', () {
      final env = sanitizeProviderRequestEnvironment({
        'ACME_TOKEN': 'step-token',
        'ACME_API_KEY': 'step-key',
        'ANDTHEN_REPORT_PATH': '/tmp/report.md',
      });

      expect(env, {'ANDTHEN_REPORT_PATH': '/tmp/report.md'});
    });

    test('an ACP target presents only the API key its registration names', () {
      const credentials = CredentialsConfig(
        entries: {
          'vendor': CredentialEntry(apiKey: 'vendor-key', envVars: ['VENDOR_API_KEY']),
        },
      );
      final env = buildProviderSpawnEnvironment(
        target: target('claude', registeredEntry: const ProviderEntry(executable: '/opt/goose')),
        registry: registry(env: {'ANTHROPIC_API_KEY': 'sk-ant-test'}, subscriptions: storedClaudeToken()),
        baseEnvironment: const {'USER': 'tobias'},
        registrarOverlay: (providerId, environment) => overlayAcpCredential(
          environment: environment,
          credentials: credentials,
          agent: const AcpAgentConfig(binary: '/opt/goose', credential: 'vendor'),
        ),
      );

      expect(env['VENDOR_API_KEY'], 'vendor-key');
      expect(env['ANTHROPIC_API_KEY'], isNull);
      expect(env['CLAUDE_CODE_OAUTH_TOKEN'], isNull);
    });

    test('a registrar owning the provider replaces the first-party overlay', () {
      // Ownership alone decides: falling through to the first-party arm would
      // hand DartClaw's own credential to a third-party provider.
      final env = buildProviderSpawnEnvironment(
        target: target('claude', registeredEntry: const ProviderEntry(executable: 'goose')),
        registry: registry(subscriptions: storedClaudeToken()),
        baseEnvironment: const {'USER': 'tobias'},
        registrarOverlay: (providerId, environment) => {...environment, 'REGISTRAR_KEY': 'owned'},
      );

      expect(env['REGISTRAR_KEY'], 'owned');
      expect(env['CLAUDE_CODE_OAUTH_TOKEN'], isNull);
    });
  });
}
