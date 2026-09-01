import 'package:dartclaw_acp/dartclaw_acp.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';

/// A [HarnessConfig] carrying [agents] as the raw `harness.acp` section a YAML
/// load retains.
///
/// `dartclaw_kernel` parses no harness section, so a suite cannot hand the
/// runtime typed ACP registrations any more: the section reaches
/// `AcpHarnessRegistrar` as the raw map an operator wrote, and the registrar
/// parses it. Declaring fixtures as typed [AcpAgentConfig]s and rendering them
/// here keeps the suites reading as registrations rather than as YAML, and
/// keeps the rendering in one place.
HarnessConfig acpHarnessConfig(Map<String, AcpAgentConfig> agents) => HarnessConfig(
  sections: {
    'acp': {
      'agents': {for (final entry in agents.entries) entry.key: acpAgentYaml(entry.value)},
    },
  },
);

/// The YAML mapping [agent] parses back from.
Map<String, dynamic> acpAgentYaml(AcpAgentConfig agent) => {
  'binary': agent.binary,
  if (agent.args.isNotEmpty) 'args': agent.args,
  'topology': agent.topology.name,
  'model_provider': ?agent.modelProvider,
  'verification': ?agent.verification,
  if (agent.requiresGuardMediation) 'requires_guard_mediation': true,
  if (agent.requiredBuiltins.isNotEmpty) 'required_builtins': agent.requiredBuiltins,
  if (agent.containerIsolationRequired) 'container_isolation_required': true,
  'container_profile': ?agent.containerProfile?.name,
  'credential': ?agent.credential,
};
