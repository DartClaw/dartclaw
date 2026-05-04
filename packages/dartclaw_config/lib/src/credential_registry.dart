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
