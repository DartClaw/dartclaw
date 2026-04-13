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

      final authed = await ProviderValidator.probeAuthStatus('codex', providerId: 'codex-exec', homePath: tmpDir.path);

      expect(authed, isTrue);
    });

    test('probeAuthStatus returns false for codex with empty tokens map', () async {
      _writeCodexAuth(tmpDir, {'OPENAI_API_KEY': null, 'tokens': {}});

      final authed = await ProviderValidator.probeAuthStatus('codex', providerId: 'codex', homePath: tmpDir.path);

      expect(authed, isFalse);
    });

    test('probeAuthStatus routes codex-exec to codex auth check', () async {
      _writeCodexAuth(tmpDir, {
        'tokens': {'access_token': 'test-token'},
      });

      final authed = await ProviderValidator.probeAuthStatus('codex', providerId: 'codex-exec', homePath: tmpDir.path);

      expect(authed, isTrue);
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
        "Provider 'claude': credentials not configured (set ANTHROPIC_API_KEY or add to credentials section)",
      ]);
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
        "Provider 'codex': credentials not configured (set OPENAI_API_KEY or add to credentials section)",
      ]);
    });

    test('validate points codex-exec users at CODEX_API_KEY', () async {
      final result = await ProviderValidator.validate(
        providers: ProvidersConfig(
          entries: {
            'claude': ProviderEntry(executable: Platform.resolvedExecutable),
            'codex-exec': ProviderEntry(executable: Platform.resolvedExecutable),
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
        "Provider 'codex-exec': credentials not configured (set CODEX_API_KEY or add to credentials section)",
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
        "Provider 'gemini': credentials not configured (set API key or add to credentials section)",
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
