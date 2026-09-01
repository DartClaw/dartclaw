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

/// Resolves the directory in which [task] executes and produces artifacts.
String taskExecutionDirectory(
  Task task, {
  required String standaloneDirectory,
  String? worktreePath,
  Project? project,
}) {
  final worktree = worktreePath?.trim();
  if (worktree != null && worktree.isNotEmpty) return worktree;

  if (taskProjectId(task) != null && project != null) return project.localPath;

  final workflowWorkspace = task.agentExecution?.workspaceDir?.trim();
  if (workflowWorkspace != null && workflowWorkspace.isNotEmpty) return workflowWorkspace;

  return standaloneDirectory;
}
