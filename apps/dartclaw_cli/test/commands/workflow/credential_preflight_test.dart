import 'package:dartclaw_cli/src/commands/workflow/credential_preflight.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

void main() {
  group('CredentialPreflight.validate', () {
    test('returns a hard error for a referenced empty GitHub credential', () {
      final config = DartclawConfig(
        credentials: const CredentialsConfig(entries: {'github-main': CredentialEntry.githubToken(token: '')}),
        projects: const ProjectConfig(
          definitions: {
            'workflow-testing': ProjectDefinition(
              id: 'workflow-testing',
              remote: 'git@github.com:tolo/dartclaw-workflow-testing.git',
              credentials: 'github-main',
            ),
          },
        ),
      );

      final result = CredentialPreflight.validate(config, const {});

      expect(result.hardErrors, hasLength(1));
      expect(result.hardErrors.single.projectId, 'workflow-testing');
      expect(result.hardErrors.single.credentialRef, 'github-main');
      expect(result.hardErrors.single.envVar, 'GITHUB_TOKEN');
    });

    test('returns no hard errors when the referenced credential is present', () {
      final config = DartclawConfig(
        credentials: const CredentialsConfig(entries: {'github-main': CredentialEntry.githubToken(token: 'secret')}),
        projects: const ProjectConfig(
          definitions: {
            'workflow-testing': ProjectDefinition(
              id: 'workflow-testing',
              remote: 'git@github.com:tolo/dartclaw-workflow-testing.git',
              credentials: 'github-main',
            ),
          },
        ),
      );

      final result = CredentialPreflight.validate(config, const {'GITHUB_TOKEN': 'secret'});

      expect(result.hardErrors, isEmpty);
      expect(result.warnings, isEmpty);
    });

    test('returns a warning for an unreferenced empty credential', () {
      final config = DartclawConfig(
        credentials: const CredentialsConfig(entries: {'openai': CredentialEntry(apiKey: '')}),
      );

      final result = CredentialPreflight.validate(config, const {});

      expect(result.hardErrors, isEmpty);
      expect(result.warnings, [
        'Credential preflight warning: credential "openai" uses env var CODEX_API_KEY, which is unset or empty',
      ]);
    });

    test('treats a missing referenced credential definition as a hard error', () {
      final config = DartclawConfig(
        projects: const ProjectConfig(
          definitions: {
            'workflow-testing': ProjectDefinition(
              id: 'workflow-testing',
              remote: 'git@github.com:tolo/dartclaw-workflow-testing.git',
              credentials: 'github-main',
            ),
          },
        ),
      );

      final result = CredentialPreflight.validate(config, const {});

      expect(result.hardErrors, hasLength(1));
      expect(result.hardErrors.single.reason, 'missing_credential_def');
      expect(
        result.hardErrors.single.message,
        'Credential preflight failed: project "workflow-testing" references missing credential "github-main"',
      );
    });

    test('accepts alternate env fallbacks before warning on unreferenced credentials', () {
      final config = DartclawConfig(
        credentials: const CredentialsConfig(entries: {'openai': CredentialEntry(apiKey: '')}),
      );

      final result = CredentialPreflight.validate(config, const {'OPENAI_API_KEY': 'secret'});

      expect(result.hardErrors, isEmpty);
      expect(result.warnings, isEmpty);
    });

    test('fails fast on referenced custom-named credentials whose resolved secret is empty', () {
      final config = DartclawConfig(
        credentials: const CredentialsConfig(entries: {'github-ssh': CredentialEntry(apiKey: '')}),
        projects: const ProjectConfig(
          definitions: {
            'workflow-testing': ProjectDefinition(
              id: 'workflow-testing',
              remote: 'git@example.com:team/repo.git',
              credentials: 'github-ssh',
            ),
          },
        ),
      );

      final result = CredentialPreflight.validate(config, const {});

      expect(result.hardErrors, hasLength(1));
      expect(
        result.hardErrors.single.message,
        'Credential preflight failed: project "workflow-testing" references credential "github-ssh" but its configured secret resolved empty',
      );
    });

    test('reports the actual configured env var for custom-named api-key credentials', () {
      final config = DartclawConfig(
        credentials: const CredentialsConfig(
          entries: {
            'github-ssh': CredentialEntry(apiKey: '', envVars: ['MY_CUSTOM_SECRET']),
          },
        ),
        projects: const ProjectConfig(
          definitions: {
            'workflow-testing': ProjectDefinition(
              id: 'workflow-testing',
              remote: 'git@example.com:team/repo.git',
              credentials: 'github-ssh',
            ),
          },
        ),
      );

      final result = CredentialPreflight.validate(config, const {});

      expect(result.hardErrors, hasLength(1));
      expect(result.hardErrors.single.envVar, 'MY_CUSTOM_SECRET');
      expect(
        result.hardErrors.single.message,
        'Credential preflight failed: project "workflow-testing" references credential '
        '"github-ssh" but env var MY_CUSTOM_SECRET is unset or empty',
      );
    });

    test('reports the configured env var for openai credentials sourced from OPENAI_API_KEY', () {
      final config = DartclawConfig(
        credentials: const CredentialsConfig(
          entries: {
            'openai': CredentialEntry(apiKey: '', envVars: ['OPENAI_API_KEY']),
          },
        ),
        projects: const ProjectConfig(
          definitions: {
            'coding': ProjectDefinition(id: 'coding', remote: 'git@example.com:team/repo.git', credentials: 'openai'),
          },
        ),
      );

      final result = CredentialPreflight.validate(config, const {});

      expect(result.hardErrors, hasLength(1));
      expect(result.hardErrors.single.envVar, 'OPENAI_API_KEY');
    });
  });
}
