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
