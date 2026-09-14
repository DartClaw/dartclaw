import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show GroupEntry;

import '../behavior/behavior_file_service.dart';
import '../container/security_profile.dart';
import '../execution_policy_resolver.dart';
import 'harness_wiring.dart';

/// What a channel conversation bound to a logical agent runs as.
final class ChannelAgentBinding {
  const new({required this.definition, required this.providerId, required this.policy, required this.behavior});

  final AgentDefinition definition;

  /// The agent's provider, normalized; the deployment default when it names none.
  final String providerId;

  /// The execution policy the session is pinned with.
  final ExecutionPolicy policy;

  /// The behavior composed from this agent's pinned workspace. An absent
  /// workspace reads no owner files; an explicit prompt occupies the SOUL
  /// position for every profile.
  final BehaviorFileService behavior;

  PromptScope get promptScope =>
      policy.containerProfile == SecurityProfile.restricted.id ? PromptScope.restricted : PromptScope.task;
}

/// Resolves an allowlist row's `agent` to its [ChannelAgentBinding] through the
/// one [ExecutionPolicyResolver], mirroring the logical-agent dispatch.
final class ChannelAgentBinder {
  new({
    required Map<String, AgentDefinition> agents,
    required ExecutionPolicyResolver policyResolver,
    required String defaultProviderId,
    required BehaviorFileService behavior,
    BehaviorFileService Function(String agentId, PromptScope scope)? behaviorSnapshot,
  }) : _agents = agents,
       _policyResolver = policyResolver,
       _defaultProviderId = defaultProviderId,
       _behavior = behavior,
       _behaviorSnapshot = behaviorSnapshot;

  /// The binder over [harness]'s one policy resolver, agent definitions,
  /// default provider and primary behaviour service.
  factory forHarness(HarnessWiring harness) => ChannelAgentBinder(
    agents: harness.agentMap,
    policyResolver: harness.policyResolver,
    defaultProviderId: harness.defaultProviderId,
    behavior: harness.behavior,
    behaviorSnapshot: harness.agentWorkerBehavior,
  );

  final Map<String, AgentDefinition> _agents;
  final ExecutionPolicyResolver _policyResolver;
  final String _defaultProviderId;
  final BehaviorFileService _behavior;
  final BehaviorFileService Function(String agentId, PromptScope scope)? _behaviorSnapshot;

  /// The binding for [row], or null for a plain row or one without `agent`.
  ///
  /// Throws [StateError] for an undeclared agent; config load refuses such a
  /// row, so reaching this is a wiring defect, never a routing fallback.
  ChannelAgentBinding? bind(GroupEntry? row) {
    final name = row?.agent;
    if (name == null) return null;
    final definition = _agents[name] ?? (throw StateError('Allowlist row "${row!.id}" binds undeclared agent "$name"'));
    definition.requireWorkspaceAvailable();
    final configured = definition.provider?.trim();
    final providerId = configured == null || configured.isEmpty
        ? _defaultProviderId
        : ProviderIdentity.normalize(configured);
    final policy = _policyResolver.resolveForAgent(definition, providerId: providerId);
    final scope = policy.containerProfile == SecurityProfile.restricted.id ? PromptScope.restricted : PromptScope.task;
    final behavior = _behaviorSnapshot?.call(definition.id, scope) ?? _behavior.forAgentDefinition(definition);
    return ChannelAgentBinding(definition: definition, providerId: providerId, policy: policy, behavior: behavior);
  }
}
