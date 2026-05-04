import 'package:dartclaw_config/dartclaw_config.dart' show CredentialEntry, CredentialType, DartclawConfig;

/// Startup-time validation result for project-scoped credentials.
class CredentialPreflightResult {
  final List<ProjectCredentialError> hardErrors;
  final List<String> warnings;

  const CredentialPreflightResult({this.hardErrors = const [], this.warnings = const []});

  bool get hasHardErrors => hardErrors.isNotEmpty;
}

/// Structured failure for a project credential that cannot be used safely.
class ProjectCredentialError {
  final String projectId;
  final String credentialRef;
  final String? envVar;
  final String reason;

  const ProjectCredentialError({
    required this.projectId,
    required this.credentialRef,
    this.envVar,
    required this.reason,
  });

  String get message => switch (reason) {
    'missing_credential_def' =>
      'Credential preflight failed: project "$projectId" references missing credential '
          '"$credentialRef"',
    'empty' when envVar == null =>
      'Credential preflight failed: project "$projectId" references credential '
          '"$credentialRef" but its configured secret resolved empty',
    _ =>
      'Credential preflight failed: project "$projectId" references credential '
          '"$credentialRef" but env var ${envVar ?? "<unknown>"} is unset or empty',
  };
}

/// Exception raised when startup must abort due to invalid project credentials.
class CredentialPreflightException implements Exception {
  final List<ProjectCredentialError> errors;

  const CredentialPreflightException(this.errors);

  @override
  String toString() => errors.map((error) => error.message).join('\n');
}

/// Validates env-backed credentials before standalone workflow startup.
abstract final class CredentialPreflight {
  /// Fallbacks used only when a credential entry was constructed without
  /// env-var provenance (typically in tests). Real YAML-loaded credentials
  /// carry their referenced env vars on the entry itself.
  static const Map<String, List<String>> _credentialEnvFallbacks = {
    'anthropic': ['ANTHROPIC_API_KEY'],
    'openai': ['CODEX_API_KEY', 'OPENAI_API_KEY'],
  };

  static CredentialPreflightResult validate(DartclawConfig config, Map<String, String> env) {
    final hardErrors = <ProjectCredentialError>[];
    final warnings = <String>[];
    final referencedCredentialNames = <String>{};

    for (final project in config.projects.definitions.values) {
      final credentialRef = project.credentials?.trim();
      if (credentialRef == null || credentialRef.isEmpty) {
        continue;
      }
      referencedCredentialNames.add(credentialRef);

      final entry = config.credentials[credentialRef];
      final envVars = _envVarsForCredential(credentialRef, entry);
      if (entry == null) {
        hardErrors.add(
          ProjectCredentialError(projectId: project.id, credentialRef: credentialRef, reason: 'missing_credential_def'),
        );
        continue;
      }
      if (_isCredentialResolved(entry, envVars, env)) {
        continue;
      }
      hardErrors.add(
        ProjectCredentialError(
          projectId: project.id,
          credentialRef: credentialRef,
          envVar: envVars.isEmpty ? null : envVars.first,
          reason: entry.secret.isEmpty ? 'empty' : 'unset',
        ),
      );
    }

    for (final entry in config.credentials.entries.entries) {
      final credentialRef = entry.key;
      if (referencedCredentialNames.contains(credentialRef)) {
        continue;
      }
      final envVars = _envVarsForCredential(credentialRef, entry.value);
      if (envVars.isEmpty || _isCredentialResolved(entry.value, envVars, env)) {
        continue;
      }
      warnings.add(
        'Credential preflight warning: credential "$credentialRef" uses env var ${envVars.first}, which is unset or empty',
      );
    }

    return CredentialPreflightResult(hardErrors: hardErrors, warnings: warnings);
  }

  static bool _isCredentialResolved(CredentialEntry entry, List<String> envVars, Map<String, String> env) {
    if (entry.secret.isNotEmpty) {
      return true;
    }
    for (final envVar in envVars) {
      final envValue = env[envVar];
      if (envValue != null && envValue.trim().isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  static List<String> _envVarsForCredential(String credentialRef, CredentialEntry? entry) {
    if (entry == null) {
      return const <String>[];
    }
    if (entry.envVars.isNotEmpty) {
      return entry.envVars;
    }
    return switch (entry.type) {
      CredentialType.githubToken => const ['GITHUB_TOKEN'],
      CredentialType.apiKey => _credentialEnvFallbacks[credentialRef] ?? const <String>[],
    };
  }
}
