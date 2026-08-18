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

    group('resolve', () {
      final subscription = CredentialEntry.subscription(
        token: 'sk-ant-oat01-stored',
        expiry: CredentialExpiry(
          issuedAt: DateTime.utc(2026, 8, 14),
          expiresAt: DateTime.utc(2027, 8, 14),
          derived: true,
        ),
      );

      CredentialRegistry registryFor(ProviderAuth auth, {bool withSubscription = true, bool withApiKey = true}) =>
          CredentialRegistry(
            credentials: CredentialsConfig(
              entries: withApiKey ? const {'anthropic': CredentialEntry(apiKey: 'anthropic-key')} : const {},
            ),
            providers: ProvidersConfig(
              entries: {'claude': ProviderEntry(executable: 'claude', auth: auth)},
            ),
            subscriptions: withSubscription ? {'claude': subscription} : const {},
          );

      test('auto presents the subscription credential when one is stored', () {
        final resolution = registryFor(ProviderAuth.auto).resolve('claude');

        expect(resolution.mode, CredentialMode.subscription);
        expect(resolution.secret, 'sk-ant-oat01-stored');
        expect(resolution.expiry?.derived, isTrue);
        expect(resolution.reason, isNull);
      });

      test('api_key presents the API key even when a subscription is stored', () {
        final resolution = registryFor(ProviderAuth.apiKey).resolve('claude');

        expect(resolution.mode, CredentialMode.apiKey);
        expect(resolution.secret, 'anthropic-key');
        expect(resolution.expiry, isNull);
      });

      test('auto falls back to the API key when no subscription is stored', () {
        final resolution = registryFor(ProviderAuth.auto, withSubscription: false).resolve('claude');

        expect(resolution.mode, CredentialMode.apiKey);
        expect(resolution.secret, 'anthropic-key');
      });

      test('an unconfigured provider resolves like auto, so 0.24 deployments keep running', () {
        final registry = CredentialRegistry(
          credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
        );

        final resolution = registry.resolve('claude');

        expect(resolution.mode, CredentialMode.apiKey);
        expect(resolution.secret, 'anthropic-key');
      });

      test('forced subscription with none stored yields no credential, never the API key', () {
        final resolution = registryFor(ProviderAuth.subscription, withSubscription: false).resolve('claude');

        expect(resolution.isPresent, isFalse);
        expect(resolution.credential, isNull);
        expect(resolution.secret, isNull);
        expect(resolution.reason, CredentialUnavailableReason.subscriptionAbsent);
      });

      test('forced api_key with none configured yields the api-key-absent reason', () {
        final resolution = registryFor(ProviderAuth.apiKey, withApiKey: false).resolve('claude');

        expect(resolution.isPresent, isFalse);
        expect(resolution.reason, CredentialUnavailableReason.apiKeyAbsent);
      });

      test('auto with nothing configured yields the none-configured reason', () {
        final resolution = registryFor(ProviderAuth.auto, withSubscription: false, withApiKey: false).resolve('claude');

        expect(resolution.reason, CredentialUnavailableReason.noneConfigured);
      });

      test('an unrecognized auth setting yields no credential and its own reason', () {
        final resolution = registryFor(ProviderAuth.unrecognized).resolve('claude');

        expect(resolution.isPresent, isFalse);
        expect(resolution.reason, CredentialUnavailableReason.unrecognizedAuthSetting);
      });

      // An alias inherits the resolved family's auth when it configures none,
      // so a vendor-level selection binds every alias that resolves to it.
      group('alias auth inheritance', () {
        CredentialRegistry registryWith(Map<String, ProviderEntry> providers) => CredentialRegistry(
          credentials: const CredentialsConfig(entries: {'openai': CredentialEntry(apiKey: 'openai-key')}),
          providers: ProvidersConfig(entries: providers),
          subscriptions: {'codex': subscription},
        );

        test('an alias with no auth inherits the family api_key selection', () {
          final resolution = registryWith({
            'codex': const ProviderEntry(executable: 'codex', auth: ProviderAuth.apiKey),
            'my-codex': const ProviderEntry(executable: 'codex'),
          }).resolve('my-codex', family: 'codex');

          expect(resolution.mode, CredentialMode.apiKey);
          expect(resolution.secret, 'openai-key');
          expect(resolution.credential, isNotNull);
          expect(
            resolution.credential!.isSubscriptionCredential,
            isFalse,
            reason: 'the forbidden subscription credential must not be presented',
          );
        });

        test("an alias's own explicit auth overrides the family", () {
          final resolution = registryWith({
            'codex': const ProviderEntry(executable: 'codex', auth: ProviderAuth.apiKey),
            'my-codex': const ProviderEntry(executable: 'codex', auth: ProviderAuth.subscription),
          }).resolve('my-codex', family: 'codex');

          expect(resolution.mode, CredentialMode.subscription);
          expect(resolution.secret, 'sk-ant-oat01-stored');
        });

        test('an explicit auto on the alias also overrides the family', () {
          final resolution = registryWith({
            'codex': const ProviderEntry(executable: 'codex', auth: ProviderAuth.apiKey),
            'my-codex': const ProviderEntry(executable: 'codex', auth: ProviderAuth.auto),
          }).resolve('my-codex', family: 'codex');

          expect(resolution.mode, CredentialMode.subscription, reason: 'auto prefers the subscription credential');
        });

        test('no family entry falls back to auto', () {
          final resolution = registryWith({'my-codex': const ProviderEntry(executable: 'codex')})
              .resolve('my-codex', family: 'codex');

          expect(resolution.mode, CredentialMode.subscription);
        });

        test('an unrecognized value on the supplying family entry still refuses', () {
          final resolution = registryWith({
            'codex': const ProviderEntry(executable: 'codex', auth: ProviderAuth.unrecognized),
            'my-codex': const ProviderEntry(executable: 'codex'),
          }).resolve('my-codex', family: 'codex');

          expect(resolution.isPresent, isFalse);
          expect(resolution.reason, CredentialUnavailableReason.unrecognizedAuthSetting);
        });

        test('a provider that is its own family uses its own auth', () {
          final resolution = registryWith({
            'codex': const ProviderEntry(executable: 'codex', auth: ProviderAuth.apiKey),
          }).resolve('codex', family: 'codex');

          expect(resolution.mode, CredentialMode.apiKey);
        });

        test('a blank provider id still honors the family selection', () {
          // A blank id normalizes to the `claude` fallback, so this is the one
          // input where the auth lookup could disagree with the credential
          // lookup below it — and disagreeing would present exactly the
          // credential the family selection excluded.
          final registry = CredentialRegistry(
            credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
            providers: const ProvidersConfig(
              entries: {'claude': ProviderEntry(executable: 'claude', auth: ProviderAuth.apiKey)},
            ),
            subscriptions: {'claude': subscription},
          );

          final resolution = registry.resolve('', family: 'claude');

          expect(resolution.mode, CredentialMode.apiKey);
          expect(resolution.secret, 'anthropic-key');
        });
      });

      test('an alias resolves its family credential, never a foreign provider one', () {
        final registry = CredentialRegistry(
          credentials: const CredentialsConfig.defaults(),
          providers: const ProvidersConfig(entries: {'my_agent': ProviderEntry(executable: 'codex')}),
          subscriptions: {'claude': subscription},
        );

        expect(registry.resolve('my_agent', family: 'codex').isPresent, isFalse);
        expect(registry.resolve('my_agent', family: 'claude').secret, 'sk-ant-oat01-stored');
        expect(registry.resolve('my_agent').isPresent, isFalse);
      });

      test('an empty subscription entry is not presentable', () {
        final registry = CredentialRegistry(
          credentials: const CredentialsConfig.defaults(),
          subscriptions: const {'claude': CredentialEntry.subscription(token: '')},
        );

        expect(registry.resolve('claude').reason, CredentialUnavailableReason.noneConfigured);
      });

      test('string forms carry no secret', () {
        expect(registryFor(ProviderAuth.auto).resolve('claude').toString(), isNot(contains('sk-ant')));
        expect(registryFor(ProviderAuth.auto).resolve('claude').toString(), contains('***'));
        expect(registryFor(ProviderAuth.apiKey).resolve('claude').toString(), isNot(contains('anthropic-key')));
        expect(
          registryFor(ProviderAuth.subscription, withSubscription: false).resolve('claude').toString(),
          contains('subscriptionAbsent'),
        );
      });
    });

    group('credentialRemediationFor', () {
      test('a forced subscription selection names its own fix and the setting, not the API key', () {
        final message = credentialRemediationFor(CredentialUnavailableReason.subscriptionAbsent, providerId: 'claude');

        expect(message, contains('claude setup-token'));
        expect(message, contains('auth: subscription'));
        expect(message, contains('providers.claude.auth'));
        expect(message, isNot(contains('ANTHROPIC_API_KEY')));
      });

      test('a forced API-key selection names the env var and the setting, not the subscription command', () {
        final message = credentialRemediationFor(CredentialUnavailableReason.apiKeyAbsent, providerId: 'codex');

        expect(message, contains('CODEX_API_KEY'));
        expect(message, contains('auth: api_key'));
        expect(message, isNot(contains('codex login')));
      });

      test('nothing configured offers both credentials, per family', () {
        final claude = credentialRemediationFor(CredentialUnavailableReason.noneConfigured, providerId: 'claude');
        final codex = credentialRemediationFor(CredentialUnavailableReason.noneConfigured, providerId: 'codex');

        expect(claude, allOf(contains('claude setup-token'), contains('ANTHROPIC_API_KEY')));
        expect(codex, allOf(contains('codex login'), contains('OPENAI_API_KEY')));
      });

      test('an unrecognized auth setting names the three accepted values', () {
        final message = credentialRemediationFor(
          CredentialUnavailableReason.unrecognizedAuthSetting,
          providerId: 'claude',
        );

        expect(message, allOf(contains('auto'), contains('subscription'), contains('api_key')));
      });

      test('an alias reads its resolved family fix, not its own name', () {
        final message = credentialRemediationFor(
          CredentialUnavailableReason.noneConfigured,
          providerId: 'my_agent',
          family: 'codex',
        );

        expect(message, allOf(contains('codex login'), contains('CODEX_API_KEY'), contains('"my_agent"')));
      });

      test('no remediation reproduces credential material', () {
        for (final reason in CredentialUnavailableReason.values) {
          for (final providerId in const ['claude', 'codex']) {
            final message = credentialRemediationFor(reason, providerId: providerId);
            expect(message, isNot(contains('sk-ant')));
            expect(message, isNot(contains('eyJ')));
          }
        }
      });

      group('searched store', () {
        // `data_dir` selects the store, so `dartclaw auth` and a `serve` started
        // with a different `--data-dir` write and read different directories.
        // Without the searched path the refusal tells an operator to re-run a
        // command they already ran successfully, and nothing names the split.
        test('a missing subscription credential names the directory that was searched', () {
          for (final reason in const [
            CredentialUnavailableReason.subscriptionAbsent,
            CredentialUnavailableReason.noneConfigured,
          ]) {
            final message = credentialRemediationFor(
              reason,
              providerId: 'claude',
              credentialsDir: '/srv/dartclaw/credentials',
            );

            expect(message, contains('/srv/dartclaw/credentials'), reason: '$reason must name the searched store');
            expect(message, contains('data_dir'), reason: '$reason must name what selects the store');
          }
        });

        test('a reason that does not involve the store stays silent about it', () {
          for (final reason in const [
            CredentialUnavailableReason.apiKeyAbsent,
            CredentialUnavailableReason.unrecognizedAuthSetting,
          ]) {
            final message = credentialRemediationFor(
              reason,
              providerId: 'claude',
              credentialsDir: '/srv/dartclaw/credentials',
            );

            expect(message, isNot(contains('/srv/dartclaw/credentials')));
          }
        });

        test('an absent or blank directory leaves the message unchanged', () {
          final baseline = credentialRemediationFor(
            CredentialUnavailableReason.subscriptionAbsent,
            providerId: 'claude',
          );

          expect(
            credentialRemediationFor(
              CredentialUnavailableReason.subscriptionAbsent,
              providerId: 'claude',
              credentialsDir: '   ',
            ),
            baseline,
          );
        });
      });
    });
  });
}
