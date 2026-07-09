import 'path_utils.dart';
import 'provider_identity.dart';
import 'session_maintenance_config.dart' show MaintenanceMode;

/// Run-scoped policy for resolving workflow approval gates.
enum WorkflowApprovalPolicy {
  /// Pause on `needsInput` outcomes and explicit approval steps.
  manual('manual'),

  /// Auto-resolve `needsInput` outcomes while preserving explicit approvals.
  autoOnStall('auto-on-stall'),

  /// Auto-resolve both `needsInput` outcomes and explicit approval steps.
  auto('auto');

  const WorkflowApprovalPolicy(this.yamlValue);

  /// Serialized config and run-context value.
  final String yamlValue;

  /// Returns the policy represented by [value], or `null` when unsupported.
  static WorkflowApprovalPolicy? fromYaml(String value) {
    final normalized = value.trim();
    for (final policy in values) {
      if (policy.yamlValue == normalized) return policy;
    }
    return null;
  }
}

const _workflowApprovalPolicyValues = ['manual', 'auto-on-stall', 'auto'];

/// Provider/model selection for a workflow execution role.
class WorkflowRoleModelConfig {
  /// Provider override for this workflow role.
  final String? provider;

  /// Model override for this workflow role.
  final String? model;

  /// Reasoning effort override for this workflow role.
  final String? effort;

  /// Creates a [WorkflowRoleModelConfig] value.
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
  /// General fallback role defaults.
  final WorkflowRoleModelConfig workflow;

  /// Planner role defaults.
  final WorkflowRoleModelConfig planner;

  /// Executor role defaults.
  final WorkflowRoleModelConfig executor;

  /// Reviewer role defaults.
  final WorkflowRoleModelConfig reviewer;

  /// Creates a [WorkflowRoleDefaultsConfig] value.
  const WorkflowRoleDefaultsConfig({
    this.workflow = const WorkflowRoleModelConfig(provider: 'claude'),
    this.planner = const WorkflowRoleModelConfig(),
    this.executor = const WorkflowRoleModelConfig(),
    this.reviewer = const WorkflowRoleModelConfig(model: 'claude-opus-4'),
  });

  /// Creates a [WorkflowRoleDefaultsConfig.defaults] value.
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
  /// Whether failed workflow runs delete their remote branch during cleanup.
  final bool deleteRemoteBranchOnFailure;

  /// Creates a [WorkflowCleanupConfig] value.
  const WorkflowCleanupConfig({this.deleteRemoteBranchOnFailure = false});

  /// Creates a [WorkflowCleanupConfig.defaults] value.
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

/// Opt-in age-based retention for workflow runtime-artifacts directories.
///
/// Prunes the `runtime-artifacts/` subtree of completed runs older than
/// [pruneAfterDays] via the `dartclaw cleanup` maintenance CLI. The run's
/// `context.json` and DB record are never touched. Disabled by default
/// ([pruneAfterDays] == 0) so the keep-everything behavior is preserved unless
/// an operator opts in.
class WorkflowRuntimeArtifactsRetentionConfig {
  /// Maintenance mode: warn (dry-run) or enforce (apply).
  final MaintenanceMode mode;

  /// Prune runtime-artifacts of completed runs older than this many days.
  /// 0 = disabled.
  final int pruneAfterDays;

  /// Creates a [WorkflowRuntimeArtifactsRetentionConfig] value.
  const WorkflowRuntimeArtifactsRetentionConfig({this.mode = MaintenanceMode.warn, this.pruneAfterDays = 0});

  /// Default retention configuration (disabled).
  const WorkflowRuntimeArtifactsRetentionConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WorkflowRuntimeArtifactsRetentionConfig && mode == other.mode && pruneAfterDays == other.pruneAfterDays;

  @override
  int get hashCode => Object.hash(mode, pruneAfterDays);

  @override
  String toString() => 'WorkflowRuntimeArtifactsRetentionConfig(mode: $mode, pruneAfterDays: $pruneAfterDays)';
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

  /// Default approval-resolution policy for newly-started workflow runs.
  final WorkflowApprovalPolicy approvals;

  /// Opt-in age-based retention for runtime-artifacts directories.
  final WorkflowRuntimeArtifactsRetentionConfig runtimeArtifactsRetention;

  /// Creates a [WorkflowConfig] value.
  const WorkflowConfig({
    this.workspaceDir,
    this.defaults = const WorkflowRoleDefaultsConfig.defaults(),
    this.cleanup = const WorkflowCleanupConfig.defaults(),
    this.approvals = WorkflowApprovalPolicy.manual,
    this.runtimeArtifactsRetention = const WorkflowRuntimeArtifactsRetentionConfig.defaults(),
  });

  /// Default configuration with no custom workflow workspace override.
  const WorkflowConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WorkflowConfig &&
          workspaceDir == other.workspaceDir &&
          defaults == other.defaults &&
          cleanup == other.cleanup &&
          approvals == other.approvals &&
          runtimeArtifactsRetention == other.runtimeArtifactsRetention;

  @override
  int get hashCode => Object.hash(workspaceDir, defaults, cleanup, approvals, runtimeArtifactsRetention);

  @override
  String toString() =>
      'WorkflowConfig(workspaceDir: $workspaceDir, defaults: $defaults, cleanup: $cleanup, '
      'approvals: $approvals, runtimeArtifactsRetention: $runtimeArtifactsRetention)';
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
    approvals: _parseWorkflowApprovals(workflowMap['approvals'], warns),
    runtimeArtifactsRetention: _parseWorkflowRuntimeArtifactsRetention(
      workflowMap['runtime_artifacts_retention'],
      warns,
    ),
  );
}

WorkflowRuntimeArtifactsRetentionConfig _parseWorkflowRuntimeArtifactsRetention(Object? raw, List<String> warns) {
  if (raw == null) return const WorkflowRuntimeArtifactsRetentionConfig.defaults();
  if (raw is! Map) {
    warns.add('Invalid type for workflow.runtime_artifacts_retention: "${raw.runtimeType}" — using defaults');
    return const WorkflowRuntimeArtifactsRetentionConfig.defaults();
  }
  final map = raw.cast<Object?, Object?>();

  var mode = MaintenanceMode.warn;
  final modeRaw = map['mode'];
  if (modeRaw != null) {
    if (modeRaw is String) {
      final parsed = MaintenanceMode.fromYaml(modeRaw.trim());
      if (parsed != null) {
        mode = parsed;
      } else {
        warns.add(
          'Invalid value for workflow.runtime_artifacts_retention.mode: "$modeRaw" '
          '(allowed: warn, enforce) — using default warn',
        );
      }
    } else {
      warns.add(
        'Invalid type for workflow.runtime_artifacts_retention.mode: "${modeRaw.runtimeType}" — using default warn',
      );
    }
  }

  var pruneAfterDays = 0;
  final pruneRaw = map['prune_after_days'];
  if (pruneRaw != null) {
    if (pruneRaw is int && pruneRaw >= 0) {
      pruneAfterDays = pruneRaw;
    } else {
      warns.add(
        'Invalid value for workflow.runtime_artifacts_retention.prune_after_days: "$pruneRaw" '
        '(expected a non-negative integer) — using default 0 (disabled)',
      );
    }
  }

  return WorkflowRuntimeArtifactsRetentionConfig(mode: mode, pruneAfterDays: pruneAfterDays);
}

WorkflowApprovalPolicy _parseWorkflowApprovals(Object? raw, List<String> warns) {
  if (raw == null) return WorkflowApprovalPolicy.manual;
  if (raw is! String) {
    warns.add('Invalid type for workflow.approvals: "${raw.runtimeType}" – using default manual');
    return WorkflowApprovalPolicy.manual;
  }
  final policy = WorkflowApprovalPolicy.fromYaml(raw);
  if (policy != null) return policy;
  warns.add(
    'Invalid value for workflow.approvals: "$raw" '
    '(allowed: ${_workflowApprovalPolicyValues.join(', ')}) – using default manual',
  );
  return WorkflowApprovalPolicy.manual;
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
