import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';

import 'git_credential_env.dart';
import 'task_config_view.dart';
import 'worktree_manager.dart';

typedef WorkflowWorktreeFailureHandler =
    Future<void> Function(Task task, {required String errorSummary, required bool retryable});

const _workflowWorktreeTokenLength = 16;

/// Binds workflow-owned tasks to their shared or inline worktrees.
final class WorkflowWorktreeBinder {
  WorkflowWorktreeBinder({
    required WorktreeManager? worktreeManager,
    required SqliteWorkflowRunRepository? workflowRunRepository,
    required WorkflowWorktreeFailureHandler failTask,
  }) : _worktreeManager = worktreeManager,
       _workflowRunRepository = workflowRunRepository,
       _failTask = failTask;

  final WorktreeManager? _worktreeManager;
  final SqliteWorkflowRunRepository? _workflowRunRepository;
  final WorkflowWorktreeFailureHandler _failTask;
  final Map<String, WorktreeInfo> _workflowSharedWorktrees = {};
  final Map<String, WorkflowWorktreeBinding> _workflowSharedWorktreeBindings = {};
  final Map<String, Completer<WorktreeInfo>> _workflowSharedWorktreeWaiters = {};
  final Set<String> _workflowInlineBranchKeys = <String>{};

  void hydrateWorkflowSharedWorktreeBinding(WorkflowWorktreeBinding binding, {required String workflowRunId}) {
    if (binding.workflowRunId != workflowRunId) {
      throw StateError(
        'Workflow worktree binding run ID mismatch: '
        'persisted ${binding.workflowRunId}, requested $workflowRunId',
      );
    }
    _workflowSharedWorktreeBindings[binding.key] = binding;
    _workflowSharedWorktrees[binding.key] = WorktreeInfo(
      path: binding.path,
      branch: binding.branch,
      createdAt: DateTime.now(),
    );
  }

  Map<String, dynamic>? externalArtifactMount(Task task) => task.workflowStepExecution?.externalArtifactMountConfig;

  String? workflowWorkspaceDir(Task task) => task.agentExecution?.workspaceDir;

  Future<String?> workflowOwnedWorktreeKey(Task task) async {
    final workflowStepExecution = task.workflowStepExecution;
    final workflowRunId = workflowStepExecution?.workflowRunId;
    if (workflowRunId == null || workflowRunId.isEmpty) return null;
    final strategy = await workflowGitWorktreeMode(task);
    if (strategy == 'shared') return workflowRunId;
    if (strategy == 'per-map-item') {
      final iterIndex = workflowStepExecution?.mapIterationIndex;
      if (iterIndex is int) return '$workflowRunId:map:$iterIndex';
      return workflowRunId;
    }
    return null;
  }

  Future<String?> workflowOwnedWorktreeTaskId(Task task) async {
    final workflowStepExecution = task.workflowStepExecution;
    final workflowRunId = workflowStepExecution?.workflowRunId;
    if (workflowRunId == null || workflowRunId.isEmpty) return null;
    final strategy = await workflowGitWorktreeMode(task);
    final token = _workflowRunToken(workflowRunId);
    if (strategy == 'shared') return 'wf-$token';
    if (strategy == 'per-map-item') {
      final iterIndex = workflowStepExecution?.mapIterationIndex;
      if (iterIndex is int) return 'wf-$token-map-$iterIndex';
      return 'wf-$token';
    }
    return null;
  }

  Future<bool> workflowMapIterationOwnsBranch(Task task) async {
    if (await workflowGitWorktreeMode(task) != 'per-map-item') return false;
    return task.workflowStepExecution?.mapIterationIndex is int;
  }

  Future<String?> workflowGitWorktreeMode(Task task) async {
    final raw = task.workflowStepExecution?.git?['worktree'];
    return raw is String ? raw.trim() : null;
  }

  Future<bool> usesInlineProjectCheckout(Task task) async => await workflowGitWorktreeMode(task) == 'inline';

  Future<WorktreeInfo> resolveWorkflowSharedWorktree(
    Task task, {
    required String workflowWorktreeKey,
    required String workflowWorktreeTaskId,
    required Project? project,
    required bool createBranch,
    required String? baseRef,
  }) async {
    final existing = _workflowSharedWorktrees[workflowWorktreeKey];
    if (existing != null) {
      _assertWorkflowSharedBindingMatch(task, workflowWorktreeKey);
      return existing;
    }

    final pending = _workflowSharedWorktreeWaiters[workflowWorktreeKey];
    if (pending != null) {
      final info = await pending.future;
      _assertWorkflowSharedBindingMatch(task, workflowWorktreeKey);
      return info;
    }

    final completer = Completer<WorktreeInfo>();
    _workflowSharedWorktreeWaiters[workflowWorktreeKey] = completer;

    try {
      final alreadyCreated = _workflowSharedWorktrees[workflowWorktreeKey];
      if (alreadyCreated != null) {
        _assertWorkflowSharedBindingMatch(task, workflowWorktreeKey);
        completer.complete(alreadyCreated);
        return alreadyCreated;
      }

      final worktreeManager = _worktreeManager;
      if (worktreeManager == null) {
        throw StateError('Workflow-owned worktree requested without a WorktreeManager');
      }
      final worktreeProject = (project != null && project.id != '_local') ? project : null;
      final created = await worktreeManager.create(
        workflowWorktreeTaskId,
        project: worktreeProject,
        baseRef: baseRef,
        createBranch: createBranch,
        existingWorktreeJson: task.worktreeJson,
      );
      await _persistWorkflowSharedWorktreeBinding(task, workflowWorktreeKey, created);
      _workflowSharedWorktrees[workflowWorktreeKey] = created;
      completer.complete(created);
      return created;
    } catch (error, stackTrace) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
      rethrow;
    } finally {
      _workflowSharedWorktreeWaiters.remove(workflowWorktreeKey);
    }
  }

  Future<bool> ensureInlineWorkflowBranchCheckedOut(Task task, Project project, String branch) async {
    final key = '${project.id}:$branch';
    final isWorkflow = TaskConfigView(task).isWorkflowOrchestrated;
    final currentHead = await currentSymbolicHead(project.localPath, noSystemConfig: isWorkflow);
    if (currentHead == branch) {
      _workflowInlineBranchKeys.add(key);
      return true;
    }

    final status = await git(
      ['status', '--porcelain'],
      workingDirectory: project.localPath,
      noSystemConfig: isWorkflow,
    );
    if (status.exitCode != 0) {
      await _failTask(
        task,
        errorSummary: 'Failed to inspect project "${project.name}" before inline workflow checkout.',
        retryable: false,
      );
      return false;
    }
    final statusOutput = (status.stdout as String).trim();
    if (statusOutput.isNotEmpty && !_workflowInlineBranchKeys.contains(key)) {
      final dirtyEntries = statusOutput.split('\n').where((line) => line.trim().isNotEmpty).take(8).join(', ');
      final moreCount = statusOutput.split('\n').where((line) => line.trim().isNotEmpty).length - 8;
      final dirtySummary = moreCount > 0 ? '$dirtyEntries (+$moreCount more)' : dirtyEntries;
      await _failTask(
        task,
        errorSummary:
            'Workflow inline mode requires a clean checkout before switching project "${project.name}" '
            'to branch "$branch". Dirty entries: $dirtySummary',
        retryable: false,
      );
      return false;
    }

    final checkout = await git(['checkout', branch], workingDirectory: project.localPath, noSystemConfig: isWorkflow);
    if (checkout.exitCode != 0) {
      final stderr = (checkout.stderr as String).trim();
      final stdout = (checkout.stdout as String).trim();
      final detail = stderr.isNotEmpty ? stderr : stdout;
      await _failTask(
        task,
        errorSummary: 'Failed to switch project "${project.name}" to workflow branch "$branch": $detail',
        retryable: false,
      );
      return false;
    }

    _workflowInlineBranchKeys.add(key);
    return true;
  }

  Future<String?> currentSymbolicHead(String workingDirectory, {bool noSystemConfig = false}) async {
    try {
      final result = await git(
        ['symbolic-ref', '--quiet', '--short', 'HEAD'],
        workingDirectory: workingDirectory,
        noSystemConfig: noSystemConfig,
      );
      if (result.exitCode != 0) return null;
      final stdout = (result.stdout as String).trim();
      return stdout.isEmpty ? null : stdout;
    } catch (_) {
      return null;
    }
  }

  Future<ProcessResult> git(List<String> args, {required String workingDirectory, bool noSystemConfig = false}) {
    return SafeProcess.git(
      args,
      plan: const GitCredentialPlan.none(),
      workingDirectory: workingDirectory,
      noSystemConfig: noSystemConfig,
    );
  }

  void _assertWorkflowSharedBindingMatch(Task task, String workflowWorktreeKey) {
    final binding = _workflowSharedWorktreeBindings[workflowWorktreeKey];
    final taskWorkflowRunId = task.workflowRunId;
    if (binding == null || taskWorkflowRunId == null || taskWorkflowRunId.isEmpty) {
      return;
    }
    if (binding.workflowRunId != taskWorkflowRunId) {
      throw StateError(
        'Workflow worktree binding run ID mismatch: '
        'persisted ${binding.workflowRunId}, requested $taskWorkflowRunId',
      );
    }
  }

  Future<void> _persistWorkflowSharedWorktreeBinding(
    Task task,
    String workflowWorktreeKey,
    WorktreeInfo worktreeInfo,
  ) async {
    final repository = _workflowRunRepository;
    final workflowRunId = task.workflowRunId;
    if (repository == null || workflowRunId == null || workflowRunId.isEmpty) {
      return;
    }

    final binding = WorkflowWorktreeBinding(
      key: workflowWorktreeKey,
      path: worktreeInfo.path,
      branch: worktreeInfo.branch,
      workflowRunId: workflowRunId,
    );
    await repository.setWorktreeBinding(workflowRunId, binding);
    _workflowSharedWorktreeBindings[workflowWorktreeKey] = binding;
  }
}

String _workflowRunToken(String workflowRunId) {
  final digest = sha256.convert(utf8.encode(workflowRunId)).toString();
  return digest.substring(0, _workflowWorktreeTokenLength);
}
