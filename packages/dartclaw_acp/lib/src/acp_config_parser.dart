import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'acp_config.dart';

const _acpRelayProviderSelectors = {'claude-acp', 'codex-acp'};

/// Parsed ACP registrations, cached per [DartclawConfig] instance.
///
/// The section is parsed once per config and every parse warning is appended to
/// that config's own load-warning sink, so a message reaches `config.warnings`
/// and stays reload-blocking exactly as it did when the parse ran inside
/// `DartclawConfig.load`. A second read neither re-parses nor duplicates a
/// warning.
///
/// Takes the whole config because `credential:` resolves against
/// `config.credentials`; that is safe because this runs after construction.
final _parsed = Expando<AcpConfig>('acpConfig');

/// The `harness.acp` registrations declared by [config].
///
/// Every production load path must call this — see
/// `HarnessConfig.assertSectionsHandled`. A config with no `harness.acp` key
/// parses to an empty [AcpConfig] and warns about nothing.
AcpConfig acpConfigFor(DartclawConfig config) {
  final cached = _parsed[config];
  if (cached != null) return cached;
  final parsed = config.parseWithLoadWarnings(
    (warns) => _parseAcpConfig(config.harness.sections['acp'], config.credentials, warns),
  );
  _parsed[config] = parsed;
  return parsed;
}

AcpConfig _parseAcpConfig(Map<String, dynamic>? acpMap, CredentialsConfig credentials, List<String> warns) {
  const defaults = AcpConfig.defaults();
  if (acpMap == null) return defaults;
  final agentsMap = readMap('agents', acpMap, warns);
  if (agentsMap == null) return defaults;

  final agents = <String, AcpAgentConfig>{};
  for (final entry in agentsMap.entries) {
    final rawAgentId = entry.key.toString();
    if (rawAgentId.trim().isEmpty) {
      warns.add('ACP provider ID must not be empty — skipping');
      continue;
    }
    final agentId = ProviderIdentity.normalize(rawAgentId);
    if (agents.containsKey(agentId)) {
      warns.add(
        'harness.acp.agents.$rawAgentId collides with another provider after normalization to "$agentId" — skipping',
      );
      continue;
    }
    final value = entry.value;
    if (value is! Map) {
      warns.add('Invalid type for harness.acp.agents.$agentId: "${value.runtimeType}" — skipping');
      continue;
    }
    final map = Map<String, dynamic>.from(value);
    final binary = readString('binary', map, warns)?.trim();
    if (binary == null || binary.isEmpty) {
      warns.add('harness.acp.agents.$agentId missing "binary" — skipping');
      continue;
    }

    final args = readStringList('args', map, warns, defaultValue: const <String>[]) ?? const <String>[];
    final requiredBuiltins =
        readStringList('required_builtins', map, warns, defaultValue: const <String>[]) ?? const <String>[];
    final topology = _parseAcpTopology(agentId, readString('topology', map, warns), warns);
    final containerProfile = _parseAcpContainerProfile(agentId, readString('container_profile', map, warns), warns);
    final config = AcpAgentConfig(
      binary: binary,
      args: List<String>.unmodifiable(args),
      topology: topology,
      modelProvider: readString('model_provider', map, warns),
      verification: readString('verification', map, warns),
      requiresGuardMediation: readBool('requires_guard_mediation', map, warns, defaultValue: false) ?? false,
      requiredBuiltins: List<String>.unmodifiable(requiredBuiltins),
      containerIsolationRequired: readBool('container_isolation_required', map, warns, defaultValue: false) ?? false,
      containerProfile: containerProfile,
      credential: _parseAcpCredentialReference(agentId, readString('credential', map, warns), credentials, warns),
    );
    final errors = _validateAcpAgentConfig(agentId, config);
    if (errors.isNotEmpty) {
      warns.addAll(errors);
      continue;
    }
    agents[agentId] = config;
  }

  return AcpConfig(agents: agents);
}

/// The `credentials.<name>` entry [raw] names, or `null` when it names nothing
/// presentable — in which case the ACP agent spawns with no DartClaw-managed
/// credential and a warning says so.
///
/// Only an API-key entry carrying a `${VAR}` reference can be presented: the
/// injection is by environment variable name, and a subscription credential is
/// never forwarded to a third-party client. Dropping an unusable reference here
/// keeps the parsed config an honest record of what a spawn will carry.
String? _parseAcpCredentialReference(String agentId, String? raw, CredentialsConfig credentials, List<String> warns) {
  if (raw == null) return null;
  const path = 'harness.acp.agents';
  final name = raw.trim();
  if (name.isEmpty) {
    warns.add('Invalid $path.$agentId.credential: must name a credentials entry — presenting no credential');
    return null;
  }
  final entry = credentials[name];
  final problem = switch (entry) {
    null => 'is not a configured credentials entry',
    CredentialEntry(isApiKeyCredential: false) => 'is not an api_key credential',
    CredentialEntry(isPresent: false) => 'resolves to an empty value',
    CredentialEntry(envVars: final envVars) when envVars.isEmpty =>
      'is a literal value with no environment variable name to present it under',
    _ => null,
  };
  if (problem == null) return name;
  warns.add('$path.$agentId.credential "$name" $problem — presenting no credential');
  return null;
}

AcpAgentTopology _parseAcpTopology(String agentId, String? raw, List<String> warns) {
  final normalized = raw?.trim().toLowerCase();
  return switch (normalized) {
    null || '' => AcpAgentTopology.unverified,
    'direct' => AcpAgentTopology.direct,
    'relay' => AcpAgentTopology.relay,
    'unverified' => AcpAgentTopology.unverified,
    _ => () {
      warns.add('Invalid harness.acp.agents.$agentId.topology: "$raw" — using unverified');
      return AcpAgentTopology.unverified;
    }(),
  };
}

AcpContainerProfile? _parseAcpContainerProfile(String agentId, String? raw, List<String> warns) {
  final normalized = raw?.trim().toLowerCase();
  return switch (normalized) {
    null || '' => null,
    'restricted' => AcpContainerProfile.restricted,
    'workspace' => AcpContainerProfile.workspace,
    _ => () {
      warns.add('Invalid harness.acp.agents.$agentId.container_profile: "$raw" — skipping profile');
      return null;
    }(),
  };
}

List<String> _validateAcpAgentConfig(String agentId, AcpAgentConfig config) {
  final errors = <String>[];
  final isGuarded = config.requiresGuardMediation;
  final isDirect = config.topology == AcpAgentTopology.direct;
  final modelProvider = config.modelProvider?.trim().toLowerCase();

  if (isGuarded) {
    if (!isDirect) {
      errors.add('Invalid harness.acp.agents.$agentId: requires_guard_mediation requires topology "direct"');
    }
    if (config.verification == null || config.verification!.trim().isEmpty) {
      errors.add('Invalid harness.acp.agents.$agentId: requires_guard_mediation requires verification');
    }
    if (modelProvider == null || modelProvider.isEmpty) {
      errors.add('Invalid harness.acp.agents.$agentId: requires_guard_mediation requires model_provider');
    } else if (_acpRelayProviderSelectors.contains(modelProvider)) {
      errors.add('Invalid harness.acp.agents.$agentId.model_provider: "$modelProvider" is an ACP relay selector');
    }
    final builtins = {
      ...config.requiredBuiltins.map((value) => value.toLowerCase()),
      ...config.args.map((value) => value.toLowerCase()),
    };
    if (agentId.toLowerCase() == 'goose' && !builtins.contains('developer')) {
      errors.add('Invalid harness.acp.agents.$agentId: guarded Goose requires developer builtin');
    }
  } else if (!isDirect) {
    if (!config.containerIsolationRequired) {
      errors.add(
        'Invalid harness.acp.agents.$agentId: relay/unverified ACP agents require container_isolation_required: true',
      );
    }
    if (config.containerProfile == null) {
      errors.add(
        'Invalid harness.acp.agents.$agentId: relay/unverified ACP agents require container_profile restricted or workspace',
      );
    }
  }

  return errors;
}
