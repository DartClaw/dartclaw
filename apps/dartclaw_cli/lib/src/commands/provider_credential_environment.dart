import 'package:dartclaw_config/dartclaw_config.dart'
    show AcpAgentConfig, CredentialMode, CredentialRegistry, CredentialsConfig, ProviderIdentity;
import 'package:dartclaw_core/dartclaw_core.dart' show claudeOauthTokenEnvVar;

/// Overlays the single credential [providerId] presents onto an already-sanitized
/// host spawn [environment], and returns it.
///
/// Must run *after* `SafeProcess.sanitize`, which strips every inherited
/// `*_TOKEN` variable — that ordering is what keeps the dedicated store
/// authoritative over an operator's own exported value.
///
/// [providerFamily] is the family of the binary being spawned; [credentialFamily]
/// overrides it for credential lookup when a provider alias resolves elsewhere.
///
/// [subscriptionHome] is the already-prepared dedicated `CODEX_HOME` for a
/// caller that spawns the vendor CLI itself. Lanes whose spawn environment is
/// completed downstream (the harness, the workflow one-shot provider driver)
/// resolve that home per spawn and pass none here.
Map<String, String> overlayProviderCredential({
  required Map<String, String> environment,
  required CredentialRegistry registry,
  required String providerId,
  required String providerFamily,
  String? credentialFamily,
  String? subscriptionHome,
}) {
  // One family for the resolution and the overlay: two lookups keyed
  // differently can report a credential present and then inject nothing.
  final family = credentialFamily ?? providerFamily;
  final resolution = registry.resolve(providerId, family: family);
  switch (resolution.mode) {
    case CredentialMode.subscription:
      // Claude presents its subscription as a token variable. A Codex
      // subscription is presented by pointing `CODEX_HOME` at the dedicated
      // store — never as the API key, which would hand the vendor CLI the very
      // credential the resolution ruled out. A caller with no downstream driver
      // to set that home resolves it first and passes it through here, so this
      // stays the single point where a credential enters a spawn environment.
      if (providerFamily == ProviderIdentity.claude) {
        environment[claudeOauthTokenEnvVar] = resolution.secret!;
      } else if (subscriptionHome != null) {
        environment['CODEX_HOME'] = subscriptionHome;
      }
    case CredentialMode.apiKey:
      _overlayApiKey(environment, registry, providerId, family);
    // Nothing resolved: an unsatisfiable `providers.<id>.auth` must not fall
    // back to the credential the operator ruled out.
    case null:
      break;
  }
  return environment;
}

/// Overlays the API key [agent] explicitly names onto an already-sanitized ACP
/// spawn [environment], and returns it.
///
/// ACP agents are credential-isolated from DartClaw's first-party provider auth:
/// an agent's `model_provider` selects no credential, and a subscription token is
/// never handed to a third-party client. `harness.acp.agents.<id>.credential` is
/// the one injection path, and it can only carry an API-key entry whose YAML
/// captured a `${VAR}` reference to present it under — config load warns about
/// every other shape and drops the reference, so this overlays nothing.
Map<String, String> overlayAcpCredential({
  required Map<String, String> environment,
  required CredentialsConfig credentials,
  required AcpAgentConfig agent,
}) {
  final name = agent.credential;
  if (name == null) return environment;
  final entry = credentials[name];
  if (entry == null || !entry.isApiKeyCredential || !entry.isPresent) return environment;
  for (final envVar in entry.envVars) {
    environment[envVar] = entry.apiKey;
  }
  return environment;
}

void _overlayApiKey(Map<String, String> environment, CredentialRegistry registry, String providerId, String? family) {
  final apiKey = registry.getApiKeyForFamily(providerId, family);
  if (apiKey == null) return;
  for (final envVar in CredentialRegistry.envVarsForFamily(providerId, family)) {
    environment[envVar] = apiKey;
  }
}
