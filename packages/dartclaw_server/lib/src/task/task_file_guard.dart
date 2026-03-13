import 'package:path/path.dart' as p;

/// Per-task file access registry for worktree isolation.
///
/// Registers allowed directory paths for task sessions. When a coding task's
/// worktree is created, the worktree path is registered as allowed. When the
/// worktree is cleaned up, the registration is removed. The harness uses this
/// to validate file access requests.
///
/// Named `TaskFileGuard` to avoid collision with the security-layer
/// `FileGuard` in `dartclaw_core`.
class TaskFileGuard {
  final Map<String, String> _allowedPaths = {};

  /// Registers a worktree path as allowed for the given task.
  void register(String taskId, String worktreePath) {
    _allowedPaths[taskId] = p.canonicalize(worktreePath);
  }

  /// Deregisters the allowed path for the given task.
  void deregister(String taskId) {
    _allowedPaths.remove(taskId);
  }

  /// Returns true if [filePath] is within the registered worktree for [taskId].
  /// Returns false if no path is registered for [taskId] or if [filePath] is
  /// outside the worktree.
  bool isAllowed(String taskId, String filePath) {
    final allowed = _allowedPaths[taskId];
    if (allowed == null) return false;
    final canonical = p.canonicalize(filePath);
    return canonical == allowed || p.isWithin(allowed, canonical);
  }

  /// Returns true if a worktree path is registered for [taskId].
  bool hasRegistration(String taskId) => _allowedPaths.containsKey(taskId);

  /// Returns the registered path for [taskId], or null.
  String? getPath(String taskId) => _allowedPaths[taskId];
}
