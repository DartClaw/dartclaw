import 'dart:io';

// Shared support doubles for the task-review suites (the task_review_service
// unit tests and the channel-review integration test). These git-port and
// worktree collaborators are dartclaw_runtime-owned, so they live package-local
// rather than in the dartclaw_testing barrel.
//
// The trio MergeExecutor/WorktreeManager/TaskFileGuard travels together across
// the review tests; RemotePushService/PrCreator round out the project-backed
// review path.
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show Task;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowPullRequest;
import 'package:dartclaw_runtime/dartclaw_runtime.dart'
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
  new({required this.result}) : super(projectDir: '.');

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
  new() : super(dataDir: '/tmp', projectDir: '/tmp');

  final List<String> cleanedTaskIds = [];
  final List<String?> cleanedProjectIds = [];
  final List<bool> forceDeleteBranches = [];

  @override
  Future<void> cleanup(String taskId, {Project? project, bool forceDeleteBranch = false}) async {
    cleanedTaskIds.add(taskId);
    cleanedProjectIds.add(project?.id);
    forceDeleteBranches.add(forceDeleteBranch);
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
  new({required this.result});

  final PushResult result;
  int callCount = 0;

  @override
  Future<PushResult> push({
    required Project project,
    required String branch,
    String? sourceRevision,
    String? expectedDestination,
  }) async {
    callCount++;
    return result;
  }
}

/// Returns a pre-configured [result] from [create].
class FakePrCreator extends PrCreator {
  new({required this.result});

  final PrCreationResult result;

  @override
  Future<PrCreationResult> create({
    required Project project,
    required Task task,
    required String branch,
    String? notes,
    WorkflowPullRequest? pullRequest,
  }) async => result;
}

Future<File> installMarkerGitHook(
  String worktreePath, {
  String hooksPath = '.husky',
  String hookName = 'pre-commit',
}) async {
  final hook = File('$worktreePath/$hooksPath/$hookName')..parent.createSync(recursive: true);
  hook.writeAsStringSync('#!/bin/sh\nprintf ran > $hookName-ran\n');
  final mode = await Process.run('chmod', ['+x', hook.path]);
  if (mode.exitCode != 0) throw StateError('Cannot make fixture hook executable: ${mode.stderr}');
  final config = await runGit(['config', 'core.hooksPath', hooksPath], workingDirectory: worktreePath);
  if (config.exitCode != 0) throw StateError('Cannot configure fixture hook: ${config.stderr}');
  return File('$worktreePath/$hookName-ran');
}
