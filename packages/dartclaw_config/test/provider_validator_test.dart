import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

const _missingBinary = 'dartclaw-definitely-missing-binary-12345';

void main() {
  group('ProviderValidator', () {
    late Directory tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('provider_validator_test_');
    });

    tearDown(() {
      tmpDir.deleteSync(recursive: true);
    });

    // ── probeBinary ──────────────────────────────────────────────

    test('probeBinary returns version for existing binary', () async {
      final version = await ProviderValidator.probeBinary(Platform.resolvedExecutable);

      expect(version, isNotNull);
      expect(version, isNotEmpty);
    });

    test('probeBinary returns null for nonexistent binary', () async {
      final version = await ProviderValidator.probeBinary(_missingBinary);

      expect(version, isNull);
    });

    // ── probeAuthStatus — Claude path ────────────────────────────

    test('probeAuthStatus returns false for nonexistent binary', () async {
      final authed = await ProviderValidator.probeAuthStatus(_missingBinary);

      expect(authed, isFalse);
    });

    test('probeAuthStatus returns false for binary without auth command', () async {
      // The Dart binary doesn't have `auth status`, so this returns false.
      final authed = await ProviderValidator.probeAuthStatus(Platform.resolvedExecutable);

      expect(authed, isFalse);
    });

    // ── probeAuthStatus — Codex path ─────────────────────────────

    test('probeAuthStatus returns false for codex with no auth file', () async {
      final authed = await ProviderValidator.probeAuthStatus('codex', providerId: 'codex', homePath: tmpDir.path);

      expect(authed, isFalse);
    });

    test('probeAuthStatus returns true for codex with valid OAuth tokens', () async {
      _writeCodexAuth(tmpDir, {
        'tokens': {'access_token': 'test-token', 'id_token': 'test-id'},
      });

      final authed = await ProviderValidator.probeAuthStatus('codex', providerId: 'codex', homePath: tmpDir.path);

      expect(authed, isTrue);
    });

    test('probeAuthStatus returns true for codex with stored API key', () async {
      _writeCodexAuth(tmpDir, {'OPENAI_API_KEY': 'sk-test-key'});

      final authed = await ProviderValidator.probeAuthStatus('codex', providerId: 'codex', homePath: tmpDir.path);

      expect(authed, isTrue);
    });

    test('probeAuthStatus returns true for codex with stored CODEX_API_KEY', () async {
      _writeCodexAuth(tmpDir, {'CODEX_API_KEY': 'sk-test-key'});

      final authed = await ProviderValidator.probeAuthStatus('codex', providerId: 'codex', homePath: tmpDir.path);

      expect(authed, isTrue);
    });

    test('probeAuthStatus returns false for codex with empty tokens map', () async {
      _writeCodexAuth(tmpDir, {'OPENAI_API_KEY': null, 'tokens': {}});

      final authed = await ProviderValidator.probeAuthStatus('codex', providerId: 'codex', homePath: tmpDir.path);

      expect(authed, isFalse);
    });

    test('probeAuthStatus rejects non-string access_token', () async {
      _writeCodexAuth(tmpDir, {
        'tokens': {'access_token': 42},
      });

      final authed = await ProviderValidator.probeAuthStatus('codex', providerId: 'codex', homePath: tmpDir.path);

      expect(authed, isFalse);
    });

    test('probeAuthStatus rejects empty-string access_token', () async {
      _writeCodexAuth(tmpDir, {
        'tokens': {'access_token': ''},
      });

      final authed = await ProviderValidator.probeAuthStatus('codex', providerId: 'codex', homePath: tmpDir.path);

      expect(authed, isFalse);
    });

    test('probeAuthStatus rejects whitespace-only stored API key', () async {
      _writeCodexAuth(tmpDir, {'OPENAI_API_KEY': '   '});

      final authed = await ProviderValidator.probeAuthStatus('codex', providerId: 'codex', homePath: tmpDir.path);

      expect(authed, isFalse);
    });

    test('probeAuthStatus returns false for malformed JSON auth file', () async {
      final codexDir = Directory('${tmpDir.path}/.codex')..createSync();
      File('${codexDir.path}/auth.json').writeAsStringSync('not json at all');

      final authed = await ProviderValidator.probeAuthStatus('codex', providerId: 'codex', homePath: tmpDir.path);

      expect(authed, isFalse);
    });

    test('probeAuthStatus returns false for empty auth file', () async {
      final codexDir = Directory('${tmpDir.path}/.codex')..createSync();
      File('${codexDir.path}/auth.json').writeAsStringSync('');

      final authed = await ProviderValidator.probeAuthStatus('codex', providerId: 'codex', homePath: tmpDir.path);

      expect(authed, isFalse);
    });

    test('probeAuthStatus returns false for JSON array auth file', () async {
      final codexDir = Directory('${tmpDir.path}/.codex')..createSync();
      File('${codexDir.path}/auth.json').writeAsStringSync('[1, 2, 3]');

      final authed = await ProviderValidator.probeAuthStatus('codex', providerId: 'codex', homePath: tmpDir.path);

      expect(authed, isFalse);
    });

    test('probeAuthStatus returns false for codex with non-map tokens field', () async {
      _writeCodexAuth(tmpDir, {'tokens': 'broken'});

      final authed = await ProviderValidator.probeAuthStatus('codex', providerId: 'codex', homePath: tmpDir.path);

      expect(authed, isFalse);
    });

    // ── validate — binary checks ─────────────────────────────────

    test('validate returns error for missing default provider binary', () async {
      final result = await ProviderValidator.validate(
        providers: const ProvidersConfig(entries: {'claude': ProviderEntry(executable: _missingBinary)}),
        registry: CredentialRegistry(
          credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
        ),
        defaultProvider: 'claude',
        homePath: tmpDir.path,
      );

      expect(result.errors, ["Provider 'claude': binary not found at '$_missingBinary'"]);
      expect(result.warnings, isEmpty);
    });

    test('validate returns warning for missing secondary provider binary', () async {
      final result = await ProviderValidator.validate(
        providers: ProvidersConfig(
          entries: {
            'claude': ProviderEntry(executable: Platform.resolvedExecutable),
            'codex': ProviderEntry(executable: _missingBinary),
          },
        ),
        registry: CredentialRegistry(
          credentials: const CredentialsConfig(
            entries: {
              'anthropic': CredentialEntry(apiKey: 'anthropic-key'),
              'openai': CredentialEntry(apiKey: 'openai-key'),
            },
          ),
        ),
        defaultProvider: 'claude',
        homePath: tmpDir.path,
      );

      expect(result.errors, isEmpty);
      expect(result.warnings, ["Provider 'codex': binary not found at '$_missingBinary'"]);
    });

    // ── validate — credential checks ─────────────────────────────

    test('validate returns error for missing default provider credential', () async {
      final result = await ProviderValidator.validate(
        providers: ProvidersConfig(entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable)}),
        registry: CredentialRegistry(credentials: CredentialsConfig.defaults()),
        defaultProvider: 'claude',
        homePath: tmpDir.path,
      );

      // The Dart binary doesn't support `auth status`, so this still fails.
      expect(result.errors, [
        'Provider "claude" has no credential configured – run `claude setup-token` and store it with '
            '`dartclaw auth claude`, or set ANTHROPIC_API_KEY.',
      ]);
      expect(result.warnings, isEmpty);
    });

    test('validate accepts a stored subscription credential without probing the binary', () async {
      // The binary here is the Dart VM, whose `auth status` always fails — so a
      // pass proves the stored credential was accepted before any probe ran.
      final result = await ProviderValidator.validate(
        providers: ProvidersConfig(entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable)}),
        registry: CredentialRegistry(
          credentials: CredentialsConfig.defaults(),
          subscriptions: const {'claude': CredentialEntry.subscription(token: 'sk-ant-oat01-stored')},
        ),
        defaultProvider: 'claude',
        homePath: tmpDir.path,
      );

      expect(result.errors, isEmpty);
      expect(result.warnings, isEmpty);
    });

    test('validate returns warning for missing secondary provider credential', () async {
      final result = await ProviderValidator.validate(
        providers: ProvidersConfig(
          entries: {
            'claude': ProviderEntry(executable: Platform.resolvedExecutable),
            'codex': ProviderEntry(executable: Platform.resolvedExecutable),
          },
        ),
        registry: CredentialRegistry(
          credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
        ),
        defaultProvider: 'claude',
        homePath: tmpDir.path,
      );

      expect(result.errors, isEmpty);
      expect(result.warnings, [
        'Provider "codex" has no credential configured – run `dartclaw auth codex` to perform the `codex login`, '
            'or set CODEX_API_KEY or OPENAI_API_KEY.',
      ]);
    });

    test('validate shows generic message for unknown provider', () async {
      final result = await ProviderValidator.validate(
        providers: ProvidersConfig(
          entries: {
            'claude': ProviderEntry(executable: Platform.resolvedExecutable),
            'gemini': ProviderEntry(executable: Platform.resolvedExecutable),
          },
        ),
        registry: CredentialRegistry(
          credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
        ),
        defaultProvider: 'claude',
        homePath: tmpDir.path,
      );

      expect(result.errors, isEmpty);
      expect(result.warnings, [
        'Provider "gemini" has no credential configured – authenticate the "gemini" provider CLI, '
            'or add an API key for "gemini" to the credentials section.',
      ]);
    });

    // ── validate — OAuth fallback ────────────────────────────────

    test('validate accepts codex with OAuth auth file instead of API key', () async {
      _writeCodexAuth(tmpDir, {
        'tokens': {'access_token': 'test-token'},
      });

      final result = await ProviderValidator.validate(
        providers: ProvidersConfig(
          entries: {
            'claude': ProviderEntry(executable: Platform.resolvedExecutable),
            'codex': ProviderEntry(executable: Platform.resolvedExecutable),
          },
        ),
        registry: CredentialRegistry(
          credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
        ),
        defaultProvider: 'claude',
        homePath: tmpDir.path,
      );

      expect(result.errors, isEmpty);
      expect(result.warnings, isEmpty);
    });

    test('validate accepts default provider via OAuth without API key', () async {
      _writeCodexAuth(tmpDir, {
        'tokens': {'access_token': 'test-token'},
      });

      final result = await ProviderValidator.validate(
        providers: ProvidersConfig(entries: {'codex': ProviderEntry(executable: Platform.resolvedExecutable)}),
        registry: CredentialRegistry(credentials: CredentialsConfig.defaults()),
        defaultProvider: 'codex',
        homePath: tmpDir.path,
      );

      // Default provider with no API key but valid OAuth — no error.
      expect(result.errors, isEmpty);
      expect(result.warnings, isEmpty);
    });

    // ── validate — credential precedence ─────────────────────────

    const codexSubscription = CredentialEntry.subscription(token: 'codex-subscription-token');

    test('a forced subscription selection is not rescued by an API key or a logged-in CLI', () async {
      _writeCodexAuth(tmpDir, {
        'tokens': {'access_token': 'test-token'},
      });

      final result = await ProviderValidator.validate(
        providers: ProvidersConfig(
          entries: {'codex': ProviderEntry(executable: Platform.resolvedExecutable, auth: ProviderAuth.subscription)},
        ),
        registry: CredentialRegistry(
          credentials: const CredentialsConfig(entries: {'openai': CredentialEntry(apiKey: 'openai-key')}),
          providers: ProvidersConfig(
            entries: {'codex': ProviderEntry(executable: Platform.resolvedExecutable, auth: ProviderAuth.subscription)},
          ),
        ),
        defaultProvider: 'codex',
        homePath: tmpDir.path,
      );

      expect(
        result.errors.single,
        allOf(contains('auth: subscription'), contains('codex login'), isNot(contains('OPENAI_API_KEY'))),
      );
      expect(result.warnings, isEmpty);
    });

    test('a refusal names the credential store this deployment resolved', () async {
      // Without the searched path the operator cannot tell "never stored" from
      // "stored under a different data_dir" — and `serve --data-dir` makes the
      // second case reachable from a documented invocation.
      final result = await ProviderValidator.validate(
        providers: ProvidersConfig(
          entries: {'codex': ProviderEntry(executable: Platform.resolvedExecutable, auth: ProviderAuth.subscription)},
        ),
        registry: CredentialRegistry(
          credentials: const CredentialsConfig(),
          providers: ProvidersConfig(
            entries: {'codex': ProviderEntry(executable: Platform.resolvedExecutable, auth: ProviderAuth.subscription)},
          ),
        ),
        defaultProvider: 'codex',
        homePath: tmpDir.path,
        credentialsDir: '/srv/dartclaw/credentials',
      );

      expect(result.errors.single, contains('/srv/dartclaw/credentials'));
    });

    test('a stored subscription credential admits the default provider with no API key', () async {
      final result = await ProviderValidator.validate(
        providers: ProvidersConfig(entries: {'codex': ProviderEntry(executable: Platform.resolvedExecutable)}),
        registry: CredentialRegistry(
          credentials: const CredentialsConfig.defaults(),
          subscriptions: const {'codex': codexSubscription},
        ),
        defaultProvider: 'codex',
        homePath: tmpDir.path,
      );

      expect(result.errors, isEmpty);
      expect(result.warnings, isEmpty);
    });

    test('a subscription credential past its derived expiry is still admitted', () async {
      // Derived expiry drives warning, not refusal — a hard-expired token is
      // caught by the live fail-closed path, not by refusing every turn early.
      final expired = CredentialEntry.subscription(
        token: 'sk-ant-oat01-stored',
        expiry: CredentialExpiry(issuedAt: DateTime.utc(2024), expiresAt: DateTime.utc(2025), derived: true),
      );

      final result = await ProviderValidator.validate(
        providers: ProvidersConfig(entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable)}),
        registry: CredentialRegistry(
          credentials: const CredentialsConfig.defaults(),
          subscriptions: {'claude': expired},
        ),
        defaultProvider: 'claude',
        homePath: tmpDir.path,
      );

      expect(result.errors, isEmpty);
      expect(result.warnings, isEmpty);
    });

    test('a credentials-exempt provider is not refused by a forced selection it cannot satisfy', () async {
      final providers = ProvidersConfig(
        entries: {
          'claude': ProviderEntry(
            executable: Platform.resolvedExecutable,
            auth: ProviderAuth.subscription,
            options: const {'credentials_required': false},
          ),
        },
      );

      final result = await ProviderValidator.validate(
        providers: providers,
        registry: CredentialRegistry(credentials: const CredentialsConfig.defaults(), providers: providers),
        defaultProvider: 'claude',
        homePath: tmpDir.path,
      );

      expect(result.errors, isEmpty);
      expect(result.warnings, isEmpty);
    });

    test('a container-bound provider is not admitted on the vendor CLI login alone', () async {
      _writeCodexAuth(tmpDir, {
        'tokens': {'access_token': 'test-token'},
      });

      final result = await ProviderValidator.validate(
        providers: ProvidersConfig(entries: {'codex': ProviderEntry(executable: Platform.resolvedExecutable)}),
        registry: CredentialRegistry(credentials: const CredentialsConfig.defaults()),
        defaultProvider: 'codex',
        homePath: tmpDir.path,
        isHostExecution: (_) => false,
      );

      expect(result.errors.single, contains('codex login'));
    });

    test('a forced-selection absence on a secondary provider warns rather than errors', () async {
      final providers = ProvidersConfig(
        entries: {
          'claude': ProviderEntry(executable: Platform.resolvedExecutable),
          'codex': ProviderEntry(executable: Platform.resolvedExecutable, auth: ProviderAuth.subscription),
        },
      );

      final result = await ProviderValidator.validate(
        providers: providers,
        registry: CredentialRegistry(
          credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
          providers: providers,
        ),
        defaultProvider: 'claude',
        homePath: tmpDir.path,
      );

      expect(result.errors, isEmpty);
      expect(result.warnings.where((w) => w.contains('auth: subscription')), hasLength(1));
    });

    test('a credentials-exempt provider is neither an error nor a warning', () async {
      final result = await ProviderValidator.validate(
        providers: ProvidersConfig(
          entries: {
            'claude': ProviderEntry(executable: Platform.resolvedExecutable),
            'gemini': ProviderEntry(
              executable: Platform.resolvedExecutable,
              options: const {'credentials_required': false},
            ),
          },
        ),
        registry: CredentialRegistry(
          credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
        ),
        defaultProvider: 'claude',
        homePath: tmpDir.path,
      );

      expect(result.errors, isEmpty);
      expect(result.warnings, isEmpty);
    });

    test('an unrecognized auth value refuses the default provider with the accepted values', () async {
      final providers = ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, auth: ProviderAuth.unrecognized)},
      );

      final result = await ProviderValidator.validate(
        providers: providers,
        registry: CredentialRegistry(
          credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
          providers: providers,
        ),
        defaultProvider: 'claude',
        homePath: tmpDir.path,
      );

      expect(result.errors.single, allOf(contains('auto'), contains('subscription'), contains('api_key')));
    });

    // ── validate — happy path ────────────────────────────────────

    test('validate returns empty lists when all providers are valid', () async {
      final result = await ProviderValidator.validate(
        providers: ProvidersConfig(
          entries: {
            'claude': ProviderEntry(executable: Platform.resolvedExecutable),
            'codex': ProviderEntry(executable: Platform.resolvedExecutable),
          },
        ),
        registry: CredentialRegistry(
          credentials: const CredentialsConfig(
            entries: {
              'anthropic': CredentialEntry(apiKey: 'anthropic-key'),
              'openai': CredentialEntry(apiKey: 'openai-key'),
            },
          ),
        ),
        defaultProvider: 'claude',
        homePath: tmpDir.path,
      );

      expect(result.errors, isEmpty);
      expect(result.warnings, isEmpty);
    });
  });
}

/// Writes a Codex auth.json file in the expected location under [tmpDir].
void _writeCodexAuth(Directory tmpDir, Map<String, dynamic> content) {
  final codexDir = Directory('${tmpDir.path}/.codex')..createSync();
  File('${codexDir.path}/auth.json').writeAsStringSync(jsonEncode(content));
}
