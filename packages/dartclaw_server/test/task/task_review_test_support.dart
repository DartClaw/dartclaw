// Shared support doubles for the task-review suites (the task_review_service
// unit tests and the channel-review integration test). These git-port and
// worktree collaborators are dartclaw_server-owned, so they live package-local
// rather than in the dartclaw_testing barrel.
//
// The trio MergeExecutor/WorktreeManager/TaskFileGuard travels together across
// the review tests; RemotePushService/PrCreator round out the project-backed
// review path.
import 'package:dartclaw_config/dartclaw_config.dart' show Project;
import 'package:dartclaw_core/dartclaw_core.dart' show Task;
import 'package:dartclaw_server/dartclaw_server.dart'
    show
        MergeExecutor,
        MergeResult,
        MergeStrategy,
        PrCreationResult,
        PrCreator,
        PushResult,
        RemotePushService,
        TaskFileGuard,
        WorktreeManager;

/// Records [merge] invocations and returns a pre-configured [result].
class RecordingMergeExecutor extends MergeExecutor {
  RecordingMergeExecutor({required this.result}) : super(projectDir: '.');

  final MergeResult result;
  int callCount = 0;

  @override
  Future<MergeResult> merge({
    required String branch,
    required String baseRef,
    required String taskId,
    required String taskTitle,
    String? expectedBaseSha,
    MergeStrategy? strategy,
  }) async {
    callCount += 1;
    return result;
  }
}

/// Records the task ids (and their project ids) whose worktrees were cleaned up.
class RecordingWorktreeManager extends WorktreeManager {
  RecordingWorktreeManager() : super(dataDir: '/tmp', projectDir: '/tmp');

  final List<String> cleanedTaskIds = [];
  final List<String?> cleanedProjectIds = [];

  @override
  Future<void> cleanup(String taskId, {Project? project}) async {
    cleanedTaskIds.add(taskId);
    cleanedProjectIds.add(project?.id);
  }
}

/// Records the task ids deregistered from the file-access guard while preserving
/// the real guard's deregistration behaviour.
class RecordingTaskFileGuard extends TaskFileGuard {
  final List<String> deregisteredTaskIds = [];

  @override
  void deregister(String taskId) {
    deregisteredTaskIds.add(taskId);
    super.deregister(taskId);
  }
}

/// Records [push] calls and returns a pre-configured [result].
class FakeRemotePushService extends RemotePushService {
  FakeRemotePushService({required this.result});

  final PushResult result;
  int callCount = 0;

  @override
  Future<PushResult> push({required Project project, required String branch}) async {
    callCount++;
    return result;
  }
}

/// Returns a pre-configured [result] from [create].
class FakePrCreator extends PrCreator {
  FakePrCreator({required this.result});

  final PrCreationResult result;

  @override
  Future<PrCreationResult> create({required Project project, required Task task, required String branch}) async =>
      result;
}
