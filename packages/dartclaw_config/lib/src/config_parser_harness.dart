part of 'dartclaw_config.dart';

const _acpRelayProviderSelectors = {'claude-acp', 'codex-acp'};

HarnessConfig _parseHarness(
  Map<String, dynamic> yaml,
  HarnessConfig defaults,
  List<String> warns, {
  required int workerTimeoutSeconds,
}) {
  final harnessMap = _sectionMap('harness', yaml, warns);
  if (harnessMap == null) return defaults;

  var turnMonitor = defaults.turnMonitor;
  final monitorMap = readMap('turn_monitor', harnessMap, warns);
  if (monitorMap != null) {
    final waitRaw = monitorMap['wait_warning_after'];
    final stuckRaw = monitorMap['stuck_after'];
    final parsedWait = tryParseDuration(waitRaw);
    final parsedStuck = tryParseDuration(stuckRaw);
    var waitWarningAfter = parsedWait ?? turnMonitor.waitWarningAfter;
    var stuckAfter = parsedStuck ?? turnMonitor.stuckAfter;

    if (waitRaw != null && parsedWait == null) {
      warns.add('Invalid value for harness.turn_monitor.wait_warning_after: "$waitRaw" — using default');
    }
    if (stuckRaw != null && parsedStuck == null) {
      warns.add('Invalid value for harness.turn_monitor.stuck_after: "$stuckRaw" — using default');
    }
    if (waitWarningAfter <= Duration.zero) {
      warns.add('Invalid harness.turn_monitor.wait_warning_after: must be a positive duration — using default');
      waitWarningAfter = turnMonitor.waitWarningAfter;
    }
    if (stuckAfter <= Duration.zero) {
      warns.add('Invalid harness.turn_monitor.stuck_after: must be a positive duration — using default');
      stuckAfter = turnMonitor.stuckAfter;
    }
    if (waitWarningAfter > stuckAfter) {
      warns.add('Invalid harness.turn_monitor: wait_warning_after must be <= stuck_after — using defaults');
      waitWarningAfter = turnMonitor.waitWarningAfter;
      stuckAfter = turnMonitor.stuckAfter;
    }
    final workerTimeout = Duration(seconds: workerTimeoutSeconds);
    if (workerTimeout > Duration.zero && stuckAfter >= workerTimeout) {
      warns.add(
        'Invalid harness.turn_monitor.stuck_after: must be below worker_timeout when known — using adjusted value',
      );
      stuckAfter = workerTimeout > const Duration(milliseconds: 1)
          ? workerTimeout - const Duration(milliseconds: 1)
          : const Duration(milliseconds: 1);
      if (waitWarningAfter > stuckAfter) {
        waitWarningAfter = stuckAfter;
      }
    }
    turnMonitor = TurnMonitorConfig(waitWarningAfter: waitWarningAfter, stuckAfter: stuckAfter);
  }

  return HarnessConfig(turnMonitor: turnMonitor, acp: _parseAcpConfig(harnessMap, defaults.acp, warns));
}

AcpConfig _parseAcpConfig(Map<String, dynamic> harnessMap, AcpConfig defaults, List<String> warns) {
  final acpMap = readMap('acp', harnessMap, warns);
  if (acpMap == null) return defaults;
  final agentsMap = readMap('agents', acpMap, warns);
  if (agentsMap == null) return defaults;

  final agents = <String, AcpAgentConfig>{};
  for (final entry in agentsMap.entries) {
    final agentId = entry.key.toString();
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
