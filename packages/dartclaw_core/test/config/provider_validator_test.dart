import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

const _missingBinary = 'dartclaw-definitely-missing-binary-12345';

void main() {
  group('ProviderValidator', () {
    test('probeBinary returns version for existing binary', () async {
      final version = await ProviderValidator.probeBinary(Platform.resolvedExecutable);

      expect(version, isNotNull);
      expect(version, isNotEmpty);
    });

    test('probeBinary returns null for nonexistent binary', () async {
      final version = await ProviderValidator.probeBinary(_missingBinary);

      expect(version, isNull);
    });

    test('validate returns error for missing default provider binary', () async {
      final result = await ProviderValidator.validate(
        providers: const ProvidersConfig(entries: {'claude': ProviderEntry(executable: _missingBinary)}),
        registry: CredentialRegistry(
          credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
        ),
        defaultProvider: 'claude',
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
      );

      expect(result.errors, isEmpty);
      expect(result.warnings, ["Provider 'codex': binary not found at '$_missingBinary'"]);
    });

    test('validate returns error for missing default provider credential', () async {
      final result = await ProviderValidator.validate(
        providers: ProvidersConfig(entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable)}),
        registry: CredentialRegistry(credentials: CredentialsConfig.defaults()),
        defaultProvider: 'claude',
      );

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
      );

      expect(result.errors, isEmpty);
      expect(result.warnings, [
        "Provider 'codex': credentials not configured (set OPENAI_API_KEY or add to credentials section)",
      ]);
    });

    test('validate points codex-exec users at OPENAI_API_KEY', () async {
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
      );

      expect(result.errors, isEmpty);
      expect(result.warnings, [
        "Provider 'codex-exec': credentials not configured (set OPENAI_API_KEY or add to credentials section)",
      ]);
    });

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
      );

      expect(result.errors, isEmpty);
      expect(result.warnings, isEmpty);
    });
  });
}
