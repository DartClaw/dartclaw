import 'credentials_config.dart';
import 'provider_identity.dart';

/// Synchronous provider-to-credential lookup service.
class CredentialRegistry {
  static const Map<String, String> _providerCredentialMap = {'claude': 'anthropic', 'codex': 'openai'};

  static const Map<String, List<String>> _providerEnvFallbacks = {
    'claude': ['ANTHROPIC_API_KEY'],
    'codex': ['CODEX_API_KEY', 'OPENAI_API_KEY'],
  };

  final CredentialsConfig _credentials;
  final Map<String, String> _env;

  /// CredentialRegistry({required CredentialsConfig credentials, .
  CredentialRegistry({required CredentialsConfig credentials, Map<String, String>? env})
    : _credentials = credentials,
      _env = env ?? const {};

  /// Returns the resolved API key for [providerId], or `null` if unavailable.
  String? getApiKey(String providerId) {
    final normalizedProviderId = ProviderIdentity.normalize(providerId);
    final providerFamily = ProviderIdentity.family(providerId);
    final credentialName = _providerCredentialMap[providerFamily];
    if (credentialName != null) {
      final entry = _credentials[credentialName];
      if (entry != null && entry.isApiKeyCredential && entry.isPresent) {
        return entry.apiKey;
      }
    }

    final envVars = _providerEnvFallbacks[normalizedProviderId] ?? _providerEnvFallbacks[providerFamily] ?? const [];
    for (final envVar in envVars) {
      final value = _env[envVar];
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
    return null;
  }

  /// Returns whether an API key is available for [providerId].
  bool hasCredential(String providerId) => getApiKey(providerId) != null;

  /// Resolves the API key honoring an explicit resolved [family] that may differ
  /// from [providerId]'s intrinsic family (a provider alias such as `my_agent`
  /// wrapping `codex`).
  ///
  /// When [family] names a known-credential family, its key wins and the
  /// provider-id key is **not** used as a fallback — so a foreign provider's key
  /// (e.g. `OPENAI_API_KEY` under a claude-family alias) never leaks through.
  /// Falls back to the provider-id key only when the resolved family has no
  /// known credential env vars. A null/empty or matching [family] degrades to a
  /// plain [getApiKey].
  ///
  /// This is the single source for family-aware key resolution: the workflow
  /// auth preflight (CLI-probe short-circuit) and the provider spawn-env builder
  /// must both call it so a "key present → skip probe" decision can never
  /// disagree with "inject this key into the spawn env."
  String? getApiKeyForFamily(String providerId, String? family) {
    final normalizedProvider = ProviderIdentity.normalize(providerId);
    final normalizedFamily = family == null || family.trim().isEmpty ? null : ProviderIdentity.normalize(family);
    if (normalizedFamily == null || normalizedFamily == normalizedProvider) {
      return getApiKey(providerId);
    }
    final familyKey = getApiKey(normalizedFamily);
    if (familyKey != null || envVarsFor(normalizedFamily).isNotEmpty) {
      return familyKey;
    }
    return getApiKey(providerId);
  }

  /// Returns the accepted fallback env vars honoring an explicit resolved
  /// [family] (provider aliases), the env-var counterpart to
  /// [getApiKeyForFamily]. The resolved family's env vars win when non-empty;
  /// otherwise falls back to the provider-id env vars, then the family's
  /// (possibly empty) list. A null/empty or matching [family] degrades to a
  /// plain [envVarsFor].
  static List<String> envVarsForFamily(String providerId, String? family) {
    final normalizedProvider = ProviderIdentity.normalize(providerId);
    final normalizedFamily = family == null || family.trim().isEmpty ? null : ProviderIdentity.normalize(family);
    if (normalizedFamily == null || normalizedFamily == normalizedProvider) {
      return envVarsFor(providerId);
    }
    final familyEnvVars = envVarsFor(normalizedFamily);
    if (familyEnvVars.isNotEmpty) return familyEnvVars;
    final providerEnvVars = envVarsFor(providerId);
    return providerEnvVars.isNotEmpty ? providerEnvVars : familyEnvVars;
  }

  /// Returns the accepted fallback environment variables for [providerId].
  static List<String> envVarsFor(String providerId) {
    final normalizedProviderId = ProviderIdentity.normalize(providerId);
    final providerFamily = ProviderIdentity.family(providerId);
    return List<String>.unmodifiable(
      _providerEnvFallbacks[normalizedProviderId] ?? _providerEnvFallbacks[providerFamily] ?? const [],
    );
  }

  /// Returns the primary fallback environment variable for [providerId].
  static String? envVarFor(String providerId) {
    final envVars = envVarsFor(providerId);
    return envVars.isEmpty ? null : envVars.first;
  }
}
