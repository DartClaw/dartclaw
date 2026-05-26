import 'package:dartclaw_config/dartclaw_config.dart' show Project;
import 'package:logging/logging.dart';

import 'task_file_guard.dart';
import 'worktree_manager.dart';

final _log = Logger('WorktreeCleanup');

/// Cleans up the worktree and file guard for [taskId].
///
/// Swallows [WorktreeManager.cleanup] exceptions (logged at WARNING) so
/// callers never crash on cleanup. Deregisters the guard regardless of
/// whether the worktree removal succeeded.
Future<void> cleanupWorktree(WorktreeManager? mgr, TaskFileGuard? guard, String taskId, {Project? project}) async {
  try {
    await mgr?.cleanup(taskId, project: project);
  } catch (e) {
    _log.warning('Failed to cleanup worktree for task $taskId: $e');
  }
  guard?.deregister(taskId);
}
