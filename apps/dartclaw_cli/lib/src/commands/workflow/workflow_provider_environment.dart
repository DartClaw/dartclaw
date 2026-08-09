import 'package:dartclaw_config/dartclaw_config.dart' show CredentialRegistry, ProviderIdentity;
import 'package:dartclaw_core/dartclaw_core.dart' show claudeHardeningEnvVars;
import 'package:dartclaw_security/dartclaw_security.dart' show SafeProcess;

/// Builds the sanitized spawn environment for a workflow provider CLI.
///
/// Sanitizes [baseEnvironment] (no allowlist, sensitive-name strip, and
/// Claude-only hardening where applicable) and overlays a configured provider API key onto its
/// accepted env vars. No allowlist is applied, so `USER` is preserved — the
/// standalone `claude` CLI reads its keychain subscription OAuth only when
/// `USER` is present (`HOME`+`PATH` alone resolve to "not logged in").
Map<String, String> buildWorkflowProviderEnvironment({
  required String providerId,
  String? providerFamily,
  required CredentialRegistry registry,
  required Map<String, String> baseEnvironment,
}) {
  final resolvedFamily = providerFamily ?? ProviderIdentity.family(providerId);
  final environment = SafeProcess.sanitize(
    baseEnvironment: baseEnvironment,
    extraEnvironment: resolvedFamily == ProviderIdentity.claude ? claudeHardeningEnvVars : const {},
  );
  // Family-aware key + env-var resolution is shared with the workflow auth
  // preflight (CredentialRegistry) so the preflight's "key present → skip CLI
  // probe" decision can never disagree with which key gets injected here.
  final apiKey = registry.getApiKeyForFamily(providerId, providerFamily);
  if (apiKey != null) {
    for (final envVar in CredentialRegistry.envVarsForFamily(providerId, providerFamily)) {
      environment[envVar] = apiKey;
    }
  }
  return environment;
}
