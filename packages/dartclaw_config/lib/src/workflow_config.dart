import 'path_utils.dart';
import 'provider_identity.dart';

/// Provider/model selection for a workflow execution role.
class WorkflowRoleModelConfig {
  final String? provider;
  final String? model;
  final String? effort;

  const WorkflowRoleModelConfig({this.provider, this.model, this.effort});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WorkflowRoleModelConfig && provider == other.provider && model == other.model && effort == other.effort;

  @override
  int get hashCode => Object.hash(provider, model, effort);

  @override
  String toString() => 'WorkflowRoleModelConfig(provider: $provider, model: $model, effort: $effort)';
}

/// Configurable workflow role defaults.
///
/// `workflow` is the general fallback. The other roles inherit missing values
/// from it at runtime.
class WorkflowRoleDefaultsConfig {
  final WorkflowRoleModelConfig workflow;
  final WorkflowRoleModelConfig planner;
  final WorkflowRoleModelConfig executor;
  final WorkflowRoleModelConfig reviewer;

  const WorkflowRoleDefaultsConfig({
    this.workflow = const WorkflowRoleModelConfig(provider: 'claude'),
    this.planner = const WorkflowRoleModelConfig(),
    this.executor = const WorkflowRoleModelConfig(),
    this.reviewer = const WorkflowRoleModelConfig(model: 'claude-opus-4'),
  });

  const WorkflowRoleDefaultsConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WorkflowRoleDefaultsConfig &&
          workflow == other.workflow &&
          planner == other.planner &&
          executor == other.executor &&
          reviewer == other.reviewer;

  @override
  int get hashCode => Object.hash(workflow, planner, executor, reviewer);

  @override
  String toString() =>
      'WorkflowRoleDefaultsConfig('
      'workflow: $workflow, '
      'planner: $planner, '
      'executor: $executor, '
      'reviewer: $reviewer'
      ')';
}

/// Cleanup behavior for workflow-owned git resources.
class WorkflowCleanupConfig {
  final bool deleteRemoteBranchOnFailure;

  const WorkflowCleanupConfig({this.deleteRemoteBranchOnFailure = false});

  const WorkflowCleanupConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WorkflowCleanupConfig && deleteRemoteBranchOnFailure == other.deleteRemoteBranchOnFailure;

  @override
  int get hashCode => deleteRemoteBranchOnFailure.hashCode;

  @override
  String toString() => 'WorkflowCleanupConfig(deleteRemoteBranchOnFailure: $deleteRemoteBranchOnFailure)';
}

/// Configuration for the workflow workspace subsystem.
///
/// `workspaceDir` overrides the built-in workflow workspace location when set.
/// Paths expand a leading `~` at load time.
class WorkflowConfig {
  /// Optional custom workflow workspace directory.
  final String? workspaceDir;

  /// Provider/model defaults for workflow roles.
  final WorkflowRoleDefaultsConfig defaults;

  /// Workflow-owned git cleanup settings.
  final WorkflowCleanupConfig cleanup;

  const WorkflowConfig({
    this.workspaceDir,
    this.defaults = const WorkflowRoleDefaultsConfig.defaults(),
    this.cleanup = const WorkflowCleanupConfig.defaults(),
  });

  /// Default configuration with no custom workflow workspace override.
  const WorkflowConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WorkflowConfig &&
          workspaceDir == other.workspaceDir &&
          defaults == other.defaults &&
          cleanup == other.cleanup;

  @override
  int get hashCode => Object.hash(workspaceDir, defaults, cleanup);

  @override
  String toString() => 'WorkflowConfig(workspaceDir: $workspaceDir, defaults: $defaults, cleanup: $cleanup)';
}

/// Parses the `workflow:` YAML section into a [WorkflowConfig].
///
/// Returns [WorkflowConfig.defaults] if the section is absent or empty.
WorkflowConfig parseWorkflowConfig(Map<String, dynamic>? workflowMap, List<String> warns, {Map<String, String>? env}) {
  if (workflowMap == null || workflowMap.isEmpty) return const WorkflowConfig.defaults();

  final workspaceDirRaw = workflowMap['workspace_dir'];
  String? workspaceDir;
  if (workspaceDirRaw == null) {
    workspaceDir = null;
  } else if (workspaceDirRaw is String) {
    workspaceDir = expandHome(workspaceDirRaw, env: env);
  } else {
    warns.add('Invalid type for workflow.workspace_dir: "${workspaceDirRaw.runtimeType}" — ignoring');
  }

  if (workflowMap.containsKey('execution_mode')) {
    warns.add('workflow.execution_mode was removed in 0.16.4 — workflow steps now always use one-shot execution');
  }

  return WorkflowConfig(
    workspaceDir: workspaceDir,
    defaults: _parseWorkflowRoleDefaults(workflowMap['defaults'], warns),
    cleanup: _parseWorkflowCleanup(workflowMap['cleanup'], warns),
  );
}

WorkflowCleanupConfig _parseWorkflowCleanup(Object? raw, List<String> warns) {
  if (raw == null) {
    return const WorkflowCleanupConfig.defaults();
  }
  if (raw is! Map) {
    warns.add('Invalid type for workflow.cleanup: "${raw.runtimeType}" — using defaults');
    return const WorkflowCleanupConfig.defaults();
  }
  final cleanupMap = raw.cast<Object?, Object?>();
  final deleteRemote = cleanupMap['delete_remote_branch_on_failure'];
  if (deleteRemote == null) {
    return const WorkflowCleanupConfig.defaults();
  }
  if (deleteRemote is! bool) {
    warns.add(
      'Invalid type for workflow.cleanup.delete_remote_branch_on_failure: '
      '"${deleteRemote.runtimeType}" — using default false',
    );
    return const WorkflowCleanupConfig.defaults();
  }
  return WorkflowCleanupConfig(deleteRemoteBranchOnFailure: deleteRemote);
}

WorkflowRoleDefaultsConfig _parseWorkflowRoleDefaults(Object? raw, List<String> warns) {
  if (raw == null) {
    return const WorkflowRoleDefaultsConfig.defaults();
  }
  if (raw is! Map) {
    warns.add('Invalid type for workflow.defaults: "${raw.runtimeType}" — using defaults');
    return const WorkflowRoleDefaultsConfig.defaults();
  }

  final defaultsMap = raw.cast<Object?, Object?>();
  return WorkflowRoleDefaultsConfig(
    workflow: _parseWorkflowRoleModel(defaultsMap, 'workflow', warns),
    planner: _parseWorkflowRoleModel(defaultsMap, 'planner', warns),
    executor: _parseWorkflowRoleModel(defaultsMap, 'executor', warns),
    reviewer: _parseWorkflowRoleModel(defaultsMap, 'reviewer', warns),
  );
}

WorkflowRoleModelConfig _parseWorkflowRoleModel(Map<Object?, Object?> defaultsMap, String role, List<String> warns) {
  final raw = defaultsMap[role];
  if (raw == null) {
    return switch (role) {
      'workflow' => const WorkflowRoleModelConfig(provider: 'claude'),
      'reviewer' => const WorkflowRoleModelConfig(model: 'claude-opus-4'),
      _ => const WorkflowRoleModelConfig(),
    };
  }
  if (raw is! Map) {
    warns.add('Invalid type for workflow.defaults.$role: "${raw.runtimeType}" — using defaults');
    return switch (role) {
      'workflow' => const WorkflowRoleModelConfig(provider: 'claude'),
      'reviewer' => const WorkflowRoleModelConfig(model: 'claude-opus-4'),
      _ => const WorkflowRoleModelConfig(),
    };
  }

  final roleMap = raw.cast<Object?, Object?>();
  var provider = _readNullableString(roleMap['provider'], 'workflow.defaults.$role.provider', warns);
  var model = _readNullableString(roleMap['model'], 'workflow.defaults.$role.model', warns);
  final effort = _readNullableString(roleMap['effort'], 'workflow.defaults.$role.effort', warns);
  final shorthand = ProviderIdentity.parseProviderModelShorthand(model);
  if (shorthand != null) {
    model = shorthand.model;
    if (provider == null) {
      provider = shorthand.provider;
    } else if (ProviderIdentity.normalize(provider) != shorthand.provider) {
      warns.add(
        'workflow.defaults.$role.model shorthand provider "${shorthand.provider}" conflicts with '
        'workflow.defaults.$role.provider "${ProviderIdentity.normalize(provider)}" — using the explicit provider',
      );
    }
  }
  return WorkflowRoleModelConfig(provider: provider, model: model, effort: effort);
}

String? _readNullableString(Object? raw, String path, List<String> warns) {
  if (raw == null) return null;
  if (raw is! String) {
    warns.add('Invalid type for $path: "${raw.runtimeType}" — ignoring');
    return null;
  }
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}
