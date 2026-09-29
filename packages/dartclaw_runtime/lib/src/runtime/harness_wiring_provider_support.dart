part of 'harness_wiring.dart';

/// Tools a worker must refuse, resolved against the MCP surface it will really
/// have.
///
/// On the host a provider-native web tool is suppressed only where the
/// deployment MCP endpoint replaces it, already folded into
/// [hostDisallowedTools]. Every container loses both of them regardless of what
/// its bridge serves: they run at the provider rather than in the container, so
/// `network:none` cannot contain them and the host gateway refuses any request
/// declaring one. Keeping a native tool the gateway would 403 buys no
/// capability — it only moves the failure to the agent's first call.
List<String> workerDisallowedTools({
  required String? containerProfile,
  required List<String> hostDisallowedTools,
  required List<String> userDisallowedTools,
}) {
  if (containerProfile == null) return hostDisallowedTools;
  return [...userDisallowedTools, 'WebFetch', 'WebSearch'];
}

/// Why [providerId] cannot present the credential selected for it, or `null`
/// when it can — the credential half of every execution-admission verdict.
///
/// [CredentialUnavailableReason.noneConfigured] is not a refusal: nothing was
/// selected, DartClaw presents nothing, and the vendor CLI's own login stays
/// admissible. Every other reason means the operator forced a credential this
/// deployment cannot present, and spawning anyway would authenticate the turn on
/// the ambient login they ruled out — not injecting one is not the same as
/// refusing one. A provider that declares it supplies its own credentials is
/// left alone, matching the startup gate; so is a registrar-owned provider,
/// which is credential-isolated and therefore has no first-party selection to
/// fail.
String? _credentialRefusalFor(
  DartclawConfig config,
  CredentialRegistry registry,
  String providerId,
  Map<String, ProviderEntry> registeredProviders,
) {
  final target = resolveProviderTarget(config, providerId, registeredProviders: registeredProviders);
  if (target.options['credentials_required'] == false || target.isRegistered) return null;
  final family = target.family;
  final reason = registry.resolve(providerId, family: family).reason;
  if (reason == null || reason == CredentialUnavailableReason.noneConfigured) return null;
  return credentialRemediationFor(
    reason,
    providerId: providerId,
    family: family,
    credentialsDir: config.credentialsDir,
  );
}

/// The configured provider entries, with the registrar-owned validation options
/// an operator must not be able to forge stripped out.
///
/// A registrar layers its own entries — validation options included — over this
/// through `HarnessRegistration.providerEntries`; what an operator wrote under
/// `providers.<id>.options` never counts as a registrar's verdict.
Map<String, ProviderEntry> _effectiveWorkerProviderEntries(DartclawConfig config) {
  final entries = <String, ProviderEntry>{
    for (final entry in ProviderIdentity.normalizeKeys(config.providers.entries).entries)
      entry.key: entry.value.copyWith(options: _withoutRegistrarValidationOptions(entry.value.options)),
  };
  entries.putIfAbsent(
    ProviderIdentity.normalize(config.agent.provider),
    () => ProviderEntry(
      executable: resolveProviderTarget(config, ProviderIdentity.normalize(config.agent.provider)).executable,
    ),
  );
  return entries;
}

Map<String, dynamic> _withoutRegistrarValidationOptions(Map<String, dynamic> options) {
  final sanitized = Map<String, dynamic>.from(options);
  sanitized.remove('registration_validation_result');
  sanitized.remove('registration_validation_owned');
  sanitized.remove('security_classification');
  sanitized.remove('validation_evidence');
  return sanitized;
}

Map<String, ProviderEntry> _effectiveValidationProviderEntries(
  DartclawConfig config,
  Map<String, ProviderEntry> workerEntries, {
  required bool hasRegisteredProviders,
}) {
  if (config.providers.isEmpty && !hasRegisteredProviders) {
    final defaultProviderId = ProviderIdentity.normalize(config.agent.provider);
    return {defaultProviderId: ProviderEntry(executable: resolveProviderTarget(config, defaultProviderId).executable)};
  }
  return workerEntries;
}

/// Returns built-in tool names to suppress when the MCP server is active.
///
/// `WebFetch` is always suppressed when MCP is enabled (replaced by the
/// `web_fetch` MCP tool which includes ContentGuard scanning).
/// `WebSearch` is only suppressed when at least one search provider is
/// configured — otherwise the agent loses search capability entirely.
List<String> mcpDisallowedTools({
  required bool mcpEnabled,
  required bool searchEnabled,
  required List<String> userDisallowed,
}) {
  return [...userDisallowed, if (mcpEnabled) 'WebFetch', if (mcpEnabled && searchEnabled) 'WebSearch'];
}
