import 'package:dartclaw_kernel/dartclaw_kernel.dart' show Project;
import 'package:dartclaw_core/dartclaw_core.dart' show Task;

/// Resolves the project binding for [task], including legacy config payloads.
String? taskProjectId(Task task) {
  final direct = task.projectId?.trim();
  if (direct != null && direct.isNotEmpty) {
    return direct;
  }

  final legacy = task.configJson['projectId'];
  if (legacy is String) {
    final trimmed = legacy.trim();
    if (trimmed.isNotEmpty) {
      return trimmed;
    }
  }

  return null;
}

/// Returns true when [task] targets a non-local project.
bool taskTargetsExternalProject(Task task) {
  final projectId = taskProjectId(task);
  return projectId != null && projectId != '_local';
}

/// Where a task executes, which decides what that directory may be trusted for.
enum TaskExecutionSite {
  /// The task's own worktree.
  worktree,

  /// The checkout of the project the task names.
  project,

  /// The workspace directory of the workflow step's agent, which the agent
  /// can write and is never a project repository.
  agentWorkspace,

  /// The runtime directory, which is the agent-writable workspace when the
  /// runtime has no local repository.
  runtimeDirectory,
}

/// Resolves the directory in which [task] executes and produces artifacts, and
/// which of the four sites it is.
({String path, TaskExecutionSite site}) taskExecutionDirectory(
  Task task, {
  required String standaloneDirectory,
  String? worktreePath,
  Project? project,
}) {
  final worktree = worktreePath?.trim();
  if (worktree != null && worktree.isNotEmpty) return (path: worktree, site: TaskExecutionSite.worktree);

  if (taskProjectId(task) != null && project != null) {
    return (path: project.localPath, site: TaskExecutionSite.project);
  }

  final workflowWorkspace = task.agentExecution?.workspaceDir?.trim();
  if (workflowWorkspace != null && workflowWorkspace.isNotEmpty) {
    return (path: workflowWorkspace, site: TaskExecutionSite.agentWorkspace);
  }

  return (path: standaloneDirectory, site: TaskExecutionSite.runtimeDirectory);
}
