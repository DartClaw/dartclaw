import 'credentials_config.dart';
import 'provider_identity.dart';

/// Synchronous provider-to-credential lookup service.
class CredentialRegistry {
  static const Map<String, String> _providerCredentialMap = {'claude': 'anthropic', 'codex': 'openai'};

  static const Map<String, String> _providerEnvFallback = {'claude': 'ANTHROPIC_API_KEY', 'codex': 'OPENAI_API_KEY'};

  final CredentialsConfig _credentials;
  final Map<String, String> _env;

  CredentialRegistry({required CredentialsConfig credentials, Map<String, String>? env})
    : _credentials = credentials,
      _env = env ?? const {};

  /// Returns the resolved API key for [providerId], or `null` if unavailable.
  String? getApiKey(String providerId) {
    final canonicalProviderId = ProviderIdentity.family(providerId);
    final credentialName = _providerCredentialMap[canonicalProviderId];
    if (credentialName != null) {
      final entry = _credentials[credentialName];
      if (entry != null && entry.isPresent) {
        return entry.apiKey;
      }
    }

    final envVar = _providerEnvFallback[canonicalProviderId];
    if (envVar == null) {
      return null;
    }

    final value = _env[envVar];
    if (value == null || value.isEmpty) {
      return null;
    }
    return value;
  }

  /// Returns whether an API key is available for [providerId].
  bool hasCredential(String providerId) => getApiKey(providerId) != null;

  /// Returns the expected fallback environment variable for [providerId].
  static String? envVarFor(String providerId) => _providerEnvFallback[ProviderIdentity.family(providerId)];
}
