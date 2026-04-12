import 'path_utils.dart';

/// Configuration for the workflow workspace subsystem.
///
/// `workspaceDir` overrides the built-in workflow workspace location when set.
/// Paths expand a leading `~` at load time.
class WorkflowConfig {
  /// Optional custom workflow workspace directory.
  final String? workspaceDir;

  const WorkflowConfig({this.workspaceDir});

  /// Default configuration with no custom workflow workspace override.
  const WorkflowConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is WorkflowConfig && workspaceDir == other.workspaceDir;

  @override
  int get hashCode => workspaceDir.hashCode;

  @override
  String toString() => 'WorkflowConfig(workspaceDir: $workspaceDir)';
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

  return WorkflowConfig(workspaceDir: workspaceDir);
}
