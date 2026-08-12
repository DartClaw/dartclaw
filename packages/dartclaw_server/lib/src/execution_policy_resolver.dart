import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show ProviderExecutionInventory, ProviderLaunchSurface;

import 'container/container_dispatcher.dart';

/// Raised when no valid execution policy exists for a request.
///
/// Always terminal: an unavailable, contradictory, or unsupported policy is
/// rejected before the turn starts and is never replaced by host execution.
final class ExecutionPolicyException implements Exception {
  /// Creates a rejection carrying an operator-actionable [message].
  const ExecutionPolicyException(this.message);

  /// Diagnostic naming the affected identity, the policy, and the remediation.
  final String message;

  @override
  String toString() => 'ExecutionPolicyException: $message';
}

/// The single resolution authority for host/container execution placement.
///
/// Every execution entry point — primary, logical agent, identityless task,
/// scheduled, advisor and system background — resolves through this type, so
/// no caller reconstructs placement from a nullable container manager or
/// duplicates the precedence rules locally.
final class ExecutionPolicyResolver {
  /// Creates a resolver over restart-time [config].
  ///
  /// [availableContainerProfiles] are the container profiles this deployment
  /// can actually run; an empty set means no container runtime is available.
  ExecutionPolicyResolver({required DartclawConfig config, required Set<String> availableContainerProfiles})
    : _config = config,
      _availableContainerProfiles = Set.unmodifiable(availableContainerProfiles);

  /// Profile used whenever container mode carries no stronger default.
  ///
  /// Neutral in the sense that it grants the workspace mount an ordinary host
  /// process would also have, which is why it — and only it — degrades to host
  /// execution when containers are disabled.
  static const neutralContainerProfile = 'workspace';

  final DartclawConfig _config;
  final Set<String> _availableContainerProfiles;

  /// The deployment default, derived solely from whether containers are enabled.
  ///
  /// Applies to every context carrying neither logical-agent identity nor a
  /// task type: scheduled prompts without agent identity, advisor turns, and
  /// system background turns.
  ExecutionPolicy get deploymentDefault => _resolve(
    explicitMode: null,
    containerProfile: neutralContainerProfile,
    subject: 'the deployment default',
    yamlPath: 'agent.execution',
  );

  /// Resolves the primary agent's policy.
  ExecutionPolicy resolveForPrimary({required String providerId}) => _resolve(
    explicitMode: _config.agent.execution,
    containerProfile: _providerContainerProfile(providerId) ?? neutralContainerProfile,
    subject: 'the primary agent',
    yamlPath: 'agent.execution',
  );

  /// Resolves a logical agent's policy, inheriting the primary agent's mode
  /// when [definition] declares none.
  ExecutionPolicy resolveForAgent(AgentDefinition definition, {required String providerId}) => _resolve(
    explicitMode: definition.execution ?? _config.agent.execution,
    containerProfile: definition.securityProfile ?? _providerContainerProfile(providerId) ?? neutralContainerProfile,
    subject: 'logical agent "${definition.id}"',
    yamlPath: 'agent.agents.${definition.id}.execution',
  );

  /// Resolves the fallback policy for a background task with no logical-agent
  /// identity, honoring the `tasks.execution.<task-type>` override.
  ExecutionPolicy resolveForTaskType(TaskType taskType) => _resolve(
    explicitMode: _config.tasks.execution[taskType],
    containerProfile: resolveProfile(taskType),
    subject: 'task type "${taskType.name}"',
    yamlPath: 'tasks.execution.${taskType.name}',
  );

  /// Reconstructs the policy pinned to a session.
  ///
  /// Sessions written before execution mode joined pinned routing carry only
  /// [securityProfile]; their mode is derived from container availability and
  /// the pinned profile, and the caller persists the derived value forward. A
  /// missing mode alone is never a rejection, but a pinned container-only
  /// profile that this deployment cannot run still fails closed.
  ExecutionPolicy resolveForPinnedSession({
    required String sessionId,
    ExecutionMode? executionMode,
    String? securityProfile,
  }) {
    return _resolve(
      explicitMode: executionMode,
      containerProfile: securityProfile ?? neutralContainerProfile,
      subject: 'session "$sessionId"',
      yamlPath: 'agent.execution',
    );
  }

  /// Startup warnings for explicit host selections that weaken a
  /// container-enabled deployment default.
  ///
  /// Each explicitly overridden YAML path is named exactly once; agents that
  /// merely inherit the primary agent's mode do not warn individually.
  List<String> hostOverrideWarnings() {
    if (!_config.container.enabled) return const [];
    final warnings = <String>[];
    void warn(String yamlPath) {
      warnings.add(
        'Execution boundary weakened: $yamlPath selects host execution while container isolation is enabled — '
        'that workload runs directly on the host.',
      );
    }

    if (_config.agent.execution == ExecutionMode.host) warn('agent.execution');
    for (final definition in _config.agent.definitions) {
      if (definition.execution == ExecutionMode.host) warn('agent.agents.${definition.id}.execution');
    }
    for (final entry in _config.tasks.execution.entries) {
      if (entry.value == ExecutionMode.host) warn('tasks.execution.${entry.key.name}');
    }
    return List.unmodifiable(warnings);
  }

  /// Startup warnings for contexts that will fail closed at first dispatch
  /// because their container-only profile default has no host equivalent.
  ///
  /// Startup stays bootable so an unconfigured deployment upgrades without an
  /// outage, but the operator learns which agent or task type is unrunnable
  /// before a user asks for it — not at the moment it is first needed.
  ///
  /// [agents] is the deployment's effective agent set, which includes built-in
  /// definitions that never appear in configuration; it defaults to the
  /// configured definitions.
  List<String> failClosedWarnings({Iterable<AgentDefinition>? agents}) {
    if (_config.container.enabled) return const [];
    final warnings = <String>[];
    for (final definition in agents ?? _config.agent.definitions) {
      final providerId = definition.provider ?? _config.agent.provider;
      try {
        resolveForAgent(definition, providerId: providerId);
      } on ExecutionPolicyException catch (error) {
        warnings.add('Agent "${definition.id}" cannot run in this deployment: ${error.message}');
      }
    }
    for (final taskType in TaskType.values) {
      try {
        resolveForTaskType(taskType);
      } on ExecutionPolicyException catch (error) {
        warnings.add('Task type "${taskType.name}" cannot run in this deployment: ${error.message}');
      }
    }
    return List.unmodifiable(warnings);
  }

  /// Startup warnings for provider/execution combinations this deployment
  /// resolves to but cannot actually run.
  ///
  /// Placement is resolved first and compatibility is checked after, so a
  /// warning never selects a replacement policy. Contexts that already fail
  /// policy resolution are left to [failClosedWarnings]; each remaining
  /// unavailable provider/mode combination is named exactly once, however many
  /// agents or task types reach it.
  ///
  /// [agents] is the deployment's effective agent set, which includes built-in
  /// definitions that never appear in configuration.
  List<String> providerCompatibilityWarnings({
    required ProviderExecutionInventory inventory,
    required String defaultProviderId,
    Iterable<AgentDefinition>? agents,
  }) {
    final warnings = <String>{};
    void check(String providerId, ExecutionPolicy Function() resolve) {
      final ExecutionPolicy policy;
      try {
        policy = resolve();
      } on ExecutionPolicyException {
        return;
      }
      final verdict = inventory.verdictFor(
        providerId: providerId,
        surface: ProviderLaunchSurface.longLived,
        policy: policy,
      );
      if (!verdict.isSupported) warnings.add(verdict.message);
    }

    check(defaultProviderId, () => resolveForPrimary(providerId: defaultProviderId));
    for (final definition in agents ?? _config.agent.definitions) {
      final providerId = definition.provider ?? defaultProviderId;
      check(providerId, () => resolveForAgent(definition, providerId: providerId));
    }
    for (final taskType in TaskType.values) {
      check(defaultProviderId, () => resolveForTaskType(taskType));
    }
    // A launch surface with no implementation is unavailable whatever the
    // policy resolves to, so it is reported per provider rather than per
    // context — an operator learns before a workflow step selects it.
    for (final providerId in inventory.supports.keys) {
      final verdict = inventory.verdictFor(
        providerId: providerId,
        surface: ProviderLaunchSurface.workflowOneShot,
        policy: const ExecutionPolicy.host(),
      );
      if (!verdict.isSupported) warnings.add(verdict.message);
    }
    return List.unmodifiable(warnings);
  }

  /// The container profile an ACP provider declares, or `null` when the
  /// provider declares none.
  String? _providerContainerProfile(String providerId) {
    final profile = _config.harness.acp[providerId]?.containerProfile;
    return switch (profile) {
      AcpContainerProfile.restricted => 'restricted',
      AcpContainerProfile.workspace => neutralContainerProfile,
      null => null,
    };
  }

  ExecutionPolicy _resolve({
    required ExecutionMode? explicitMode,
    required String containerProfile,
    required String subject,
    required String yamlPath,
  }) {
    final mode = explicitMode ?? (_config.container.enabled ? ExecutionMode.container : ExecutionMode.host);
    if (mode == ExecutionMode.host) {
      // A deliberate host selection drops mode-conditional profile defaults;
      // an unselected host default cannot silently discard a stronger one.
      if (explicitMode == null && containerProfile != neutralContainerProfile) {
        throw ExecutionPolicyException(
          'Cannot run $subject on the host: its container profile "$containerProfile" has no host equivalent, and '
          'container isolation is disabled. Enable container.enabled: true, or set $yamlPath: host to run it on the '
          'host without that profile.',
        );
      }
      return const ExecutionPolicy.host();
    }
    if (!_availableContainerProfiles.contains(containerProfile)) {
      throw ExecutionPolicyException(
        'Cannot run $subject in container profile "$containerProfile": no container manager is available for it. '
        '${_availableContainerProfiles.isEmpty ? 'Container isolation is unavailable — enable container.enabled: true '
                  'or set $yamlPath: host.' : 'Available profiles: ${(_availableContainerProfiles.toList()..sort()).join(', ')}.'}',
      );
    }
    return ExecutionPolicy.container(containerProfile);
  }
}
