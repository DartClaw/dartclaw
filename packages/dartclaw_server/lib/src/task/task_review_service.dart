import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import 'merge_executor.dart';
import 'pr_creator.dart';
import 'remote_push_service.dart';
import 'task_event_recorder.dart';
import 'task_file_guard.dart';
import 'task_project_ref.dart';
import 'task_service.dart';
import 'worktree_manager.dart';

/// Callback to deliver push-back feedback as a new turn message.
///
/// Invoked by [TaskReviewService] after a `push_back` transitions a task
/// from `review` to `running`. Delivery is best-effort — a failed callback
/// does not roll back the state transition.
typedef PushBackFeedbackDelivery =
    Future<void> Function({required String taskId, required String sessionKey, required String feedback});

/// Result of a task review action.
sealed class ReviewResult {
  const ReviewResult();
}

/// Review action succeeded.
final class ReviewSuccess extends ReviewResult {
  final Task task;

  const ReviewSuccess(this.task);
}

/// Review action failed because the merge produced conflicts.
final class ReviewMergeConflict extends ReviewResult {
  final String taskId;
  final String taskTitle;
  final List<String> conflictingFiles;
  final String details;

  const ReviewMergeConflict({
    required this.taskId,
    required this.taskTitle,
    required this.conflictingFiles,
    required this.details,
  });
}

/// Review action failed because the task does not exist.
final class ReviewNotFound extends ReviewResult {
  final String taskId;

  const ReviewNotFound(this.taskId);
}

/// Review action failed because the task can no longer transition.
final class ReviewInvalidTransition extends ReviewResult {
  final String taskId;
  final TaskStatus oldStatus;
  final TaskStatus targetStatus;
  final TaskStatus currentStatus;

  const ReviewInvalidTransition({
    required this.taskId,
    required this.oldStatus,
    required this.targetStatus,
    required this.currentStatus,
  });

  String get message => 'Cannot transition from ${oldStatus.name} to ${targetStatus.name}';
}

/// Review action failed due to invalid input.
final class ReviewInvalidRequest extends ReviewResult {
  final String message;

  const ReviewInvalidRequest(this.message);
}

/// Review action failed during execution.
final class ReviewActionFailed extends ReviewResult {
  final String message;

  const ReviewActionFailed(this.message);
}

/// Shared lifecycle service for task review actions.
class TaskReviewService {
  static final _log = Logger('TaskReviewService');

  final TaskService _tasks;
  final WorktreeManager? _worktreeManager;
  final TaskFileGuard? _taskFileGuard;
  final MergeExecutor? _mergeExecutor;
  final RemotePushService? _remotePushService;
  final PrCreator? _prCreator;
  final ProjectService? _projectService;
  final String? _dataDir;
  final String _mergeStrategy;
  final String _baseRef;
  final PushBackFeedbackDelivery? _pushBackFeedbackDelivery;
  final TaskEventRecorder? _eventRecorder;
  final Map<String, Future<void>> _reviewLocks = <String, Future<void>>{};

  TaskReviewService({
    required TaskService tasks,
    WorktreeManager? worktreeManager,
    TaskFileGuard? taskFileGuard,
    MergeExecutor? mergeExecutor,
    RemotePushService? remotePushService,
    PrCreator? prCreator,
    ProjectService? projectService,
    String? dataDir,
    String mergeStrategy = 'squash',
    String baseRef = 'main',
    PushBackFeedbackDelivery? pushBackFeedbackDelivery,
    TaskEventRecorder? eventRecorder,
  }) : _tasks = tasks,
       _worktreeManager = worktreeManager,
       _taskFileGuard = taskFileGuard,
       _mergeExecutor = mergeExecutor,
       _remotePushService = remotePushService,
       _prCreator = prCreator,
       _projectService = projectService,
       _dataDir = dataDir,
       _mergeStrategy = mergeStrategy,
       _baseRef = baseRef,
       _pushBackFeedbackDelivery = pushBackFeedbackDelivery,
       _eventRecorder = eventRecorder;

  /// Builds a channel-facing review handler backed by this service.
  ChannelReviewHandler channelReviewHandler({String trigger = 'channel'}) {
    return (taskId, action, {String? comment}) => reviewForChannel(taskId, action, comment: comment, trigger: trigger);
  }

  /// Executes a review action for [taskId].
  Future<ReviewResult> review(String taskId, String action, {String? comment, String trigger = 'user'}) async {
    return _withTaskLock(taskId, () => _reviewUnlocked(taskId, action, comment: comment, trigger: trigger));
  }

  /// Executes a review action and maps the outcome to a channel response.
  Future<ChannelReviewResult> reviewForChannel(
    String taskId,
    String action, {
    String? comment,
    String trigger = 'channel',
  }) async {
    final result = await review(taskId, action, comment: comment, trigger: trigger);
    return switch (result) {
      ReviewSuccess(:final task) => ChannelReviewSuccess(taskTitle: task.title, action: action),
      ReviewMergeConflict(:final taskTitle) => ChannelReviewMergeConflict(taskTitle: taskTitle),
      ReviewNotFound(taskId: final missingTaskId) => ChannelReviewError(
        'No task found with ID ${_shortTaskId(missingTaskId)}.',
      ),
      ReviewInvalidTransition(taskId: final invalidTaskId, currentStatus: final currentStatus) => ChannelReviewError(
        'Task ${_shortTaskId(invalidTaskId)} is not in review (current status: ${currentStatus.name}).',
      ),
      ReviewInvalidRequest(:final message) => ChannelReviewError(message),
      ReviewActionFailed(:final message) => ChannelReviewError(message),
    };
  }

  Future<ReviewResult> _reviewUnlocked(String taskId, String action, {String? comment, required String trigger}) async {
    final targetStatus = switch (action) {
      'accept' => TaskStatus.accepted,
      'reject' => TaskStatus.rejected,
      'push_back' => TaskStatus.running,
      _ => null,
    };
    if (targetStatus == null) {
      return const ReviewInvalidRequest('action must be one of: accept, reject, push_back');
    }

    final trimmedComment = comment?.trim();
    if (targetStatus == TaskStatus.running &&
        action == 'push_back' &&
        (trimmedComment == null || trimmedComment.isEmpty)) {
      return const ReviewInvalidRequest('comment must not be empty for push_back');
    }

    Task? task;
    TaskStatus? oldStatus;

    try {
      task = await _tasks.get(taskId);
      if (task == null) {
        return ReviewNotFound(taskId);
      }

      oldStatus = task.status;
      if (!oldStatus.canTransitionTo(targetStatus)) {
        return ReviewInvalidTransition(
          taskId: taskId,
          oldStatus: oldStatus,
          targetStatus: targetStatus,
          currentStatus: oldStatus,
        );
      }

      if (targetStatus == TaskStatus.accepted && task.worktreeJson != null) {
        final isProjectBacked = taskTargetsExternalProject(task);

        if (isProjectBacked) {
          final earlyFailure = await _handleProjectAccept(task);
          if (earlyFailure != null) return earlyFailure;
          // null means push succeeded — continue to transition
        } else if (_mergeExecutor != null) {
          // Existing local merge flow (unchanged).
          final worktreeInfo = WorktreeInfo.fromJson(task.worktreeJson!);
          final strategy = _mergeStrategy == 'merge' ? MergeStrategy.merge : MergeStrategy.squash;
          final mergeResult = await _mergeExecutor.merge(
            branch: worktreeInfo.branch,
            baseRef: _baseRef,
            taskId: taskId,
            taskTitle: task.title,
            strategy: strategy,
          );
          if (mergeResult case MergeConflict(:final conflictingFiles, :final details)) {
            await _persistConflictArtifact(taskId, mergeResult);
            return ReviewMergeConflict(
              taskId: taskId,
              taskTitle: task.title,
              conflictingFiles: conflictingFiles,
              details: details,
            );
          }
        } else {
          return const ReviewActionFailed(
            'Merge infrastructure is not available. Use the web UI or configure merge support.',
          );
        }
      }

      final transitionTime = DateTime.now();
      final transitionConfig = (targetStatus == TaskStatus.running && action == 'push_back')
          ? _withPushBackComment(task.transition(targetStatus, now: transitionTime).configJson, trimmedComment!)
          : null;

      final updated = await _tasks.transition(
        taskId,
        targetStatus,
        now: transitionTime,
        configJson: transitionConfig,
        trigger: trigger,
      );

      // Record push-back event on the task timeline.
      if (targetStatus == TaskStatus.running && action == 'push_back' && trimmedComment != null) {
        _eventRecorder?.recordPushBack(taskId, comment: trimmedComment);
      }

      // Deliver push-back feedback as a new turn message to the task's session.
      if (targetStatus == TaskStatus.running && action == 'push_back' && trimmedComment != null) {
        final delivery = _pushBackFeedbackDelivery;
        if (delivery != null) {
          final sessionKey = _extractSessionKey(task);
          if (sessionKey != null) {
            try {
              await delivery(taskId: taskId, sessionKey: sessionKey, feedback: trimmedComment);
            } catch (error, stackTrace) {
              _log.warning('Failed to deliver push-back feedback for task $taskId', error, stackTrace);
              // Non-fatal — task is already transitioned. Feedback delivery is best-effort.
            }
          }
        }
      }

      // Project-backed accepts already cleaned up in _handleProjectAccept.
      final isProjectBackedAccept = targetStatus == TaskStatus.accepted && taskTargetsExternalProject(task);
      if (!isProjectBackedAccept &&
          (targetStatus == TaskStatus.accepted || targetStatus == TaskStatus.rejected) &&
          task.worktreeJson != null) {
        final cleanupProject = await _cleanupProjectForTask(task);
        await _cleanupWorktree(taskId, project: cleanupProject);
      }

      return ReviewSuccess(updated);
    } on ArgumentError {
      return ReviewNotFound(taskId);
    } on VersionConflictException {
      return const ReviewActionFailed('Task was modified concurrently. Please refresh and try again.');
    } on StateError {
      final currentTask = await _tasks.get(taskId);
      final previousStatus = oldStatus ?? currentTask?.status ?? TaskStatus.draft;
      return ReviewInvalidTransition(
        taskId: taskId,
        oldStatus: previousStatus,
        targetStatus: targetStatus,
        currentStatus: currentTask?.status ?? previousStatus,
      );
    } catch (error, stackTrace) {
      _log.warning('Unexpected failure while attempting to ${_displayAction(action)} task $taskId', error, stackTrace);
      return const ReviewActionFailed('Review action failed. Please try again or use the web UI.');
    }
  }

  /// Handles the accept flow for project-backed tasks (push to remote + optional PR).
  ///
  /// Returns null on success (caller continues to transition), or a [ReviewResult]
  /// on failure (task stays in review).
  Future<ReviewResult?> _handleProjectAccept(Task task) async {
    if (_remotePushService == null || _projectService == null) {
      return const ReviewActionFailed('Push infrastructure is not available.');
    }

    final projectId = taskProjectId(task);
    if (projectId == null) {
      return const ReviewActionFailed('Task is not bound to a project.');
    }

    final project = await _projectService.get(projectId);
    if (project == null) {
      return ReviewActionFailed('Project "$projectId" not found.');
    }

    final worktreeInfo = WorktreeInfo.fromJson(task.worktreeJson!);
    final branch = worktreeInfo.branch;

    final pushResult = await _remotePushService.push(project: project, branch: branch);

    switch (pushResult) {
      case PushSuccess():
        await _handlePostPushArtifact(task.id, project, branch, task);
        // Successful push — clean up worktree.
        await _cleanupWorktree(task.id, project: project);
        return null;

      case PushAuthFailure(:final details):
        await _persistPushErrorArtifact(task.id, 'Authentication failed: $details');
        return ReviewActionFailed('Failed to push branch: $details');

      case PushRejected(:final reason):
        await _persistPushErrorArtifact(task.id, 'Remote rejected push: $reason');
        return ReviewActionFailed('Remote rejected push: $reason');

      case PushError(:final message):
        await _persistPushErrorArtifact(task.id, 'Push failed: $message');
        return ReviewActionFailed('Failed to push branch: $message');
    }
  }

  /// Stores a PR URL, branch name, or instruction artifact after a successful push.
  Future<void> _handlePostPushArtifact(String taskId, Project project, String branch, Task task) async {
    final prCreator = _prCreator;

    if (project.pr.strategy == PrStrategy.githubPr && prCreator != null) {
      final prResult = await prCreator.create(project: project, task: task, branch: branch);
      switch (prResult) {
        case PrCreated(:final url):
          await _persistPrArtifact(taskId, 'Pull Request', ArtifactKind.pr, url, isFilePath: false);

        case PrGhNotFound(:final instructions):
          await _persistPrArtifact(taskId, 'PR Instructions', ArtifactKind.pr, instructions, isFilePath: true);

        case PrCreationFailed(:final error, :final details):
          // Push succeeded — PR creation is best-effort. Store a warning artifact.
          final content = 'PR creation warning: $error\n$details';
          await _persistPrArtifact(taskId, 'PR Creation Warning', ArtifactKind.pr, content, isFilePath: true);
      }
    } else {
      // branch-only strategy or no prCreator: store branch name.
      await _persistPrArtifact(taskId, 'Branch', ArtifactKind.pr, branch, isFilePath: false);
    }
  }

  /// Persists a push error artifact to the task's artifact directory.
  Future<void> _persistPushErrorArtifact(String taskId, String errorDetails) async {
    if (_dataDir == null) return;
    try {
      final artifactDir = Directory('$_dataDir/tasks/$taskId/artifacts');
      await artifactDir.create(recursive: true);
      final errorFile = File('${artifactDir.path}/push-error.txt');
      await errorFile.writeAsString(errorDetails);
      await _tasks.addArtifact(
        id: const Uuid().v4(),
        taskId: taskId,
        name: 'Push Error',
        kind: ArtifactKind.data,
        path: errorFile.path,
      );
    } catch (error) {
      _log.warning('Failed to persist push error artifact for task $taskId: $error');
    }
  }

  /// Persists a PR-related artifact.
  ///
  /// When [isFilePath] is true, writes [content] to a file and stores the path.
  /// When [isFilePath] is false, stores [content] directly as the artifact path
  /// (e.g. a PR URL or branch name).
  Future<void> _persistPrArtifact(
    String taskId,
    String name,
    ArtifactKind kind,
    String content, {
    required bool isFilePath,
  }) async {
    try {
      String artifactPath;

      if (isFilePath) {
        if (_dataDir == null) {
          _log.warning('Cannot persist PR artifact: dataDir not set');
          return;
        }
        final artifactDir = Directory('$_dataDir/tasks/$taskId/artifacts');
        await artifactDir.create(recursive: true);
        final safeName = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
        final file = File('${artifactDir.path}/$safeName.txt');
        await file.writeAsString(content);
        artifactPath = file.path;
      } else {
        // Content is a URL or branch name — store directly.
        artifactPath = content;
      }

      await _tasks.addArtifact(id: const Uuid().v4(), taskId: taskId, name: name, kind: kind, path: artifactPath);
    } catch (error) {
      _log.warning('Failed to persist PR artifact "$name" for task $taskId: $error');
    }
  }

  Future<T> _withTaskLock<T>(String taskId, Future<T> Function() action) async {
    final previous = _reviewLocks[taskId];
    final completer = Completer<void>();
    _reviewLocks[taskId] = completer.future;

    try {
      if (previous != null) {
        await previous;
      }
      return await action();
    } finally {
      if (!completer.isCompleted) {
        completer.complete();
      }
      if (identical(_reviewLocks[taskId], completer.future)) {
        final removedLock = _reviewLocks.remove(taskId);
        assert(removedLock == completer.future);
      }
    }
  }

  Future<void> _persistConflictArtifact(String taskId, MergeConflict conflict) async {
    if (_dataDir == null) {
      return;
    }

    try {
      final conflictDir = Directory('$_dataDir/tasks/$taskId/artifacts');
      await conflictDir.create(recursive: true);
      final conflictFile = File('${conflictDir.path}/conflict.json');
      await conflictFile.writeAsString(jsonEncode(conflict.toJson()));
      await _tasks.addArtifact(
        id: const Uuid().v4(),
        taskId: taskId,
        name: 'conflict.json',
        kind: ArtifactKind.data,
        path: conflictFile.path,
      );
    } catch (error) {
      _log.warning('Failed to persist conflict artifact for task $taskId: $error');
    }
  }

  String _displayAction(String action) => action == 'push_back' ? 'push back' : action;

  Map<String, dynamic> _withPushBackComment(Map<String, dynamic> configJson, String comment) {
    final updated = Map<String, dynamic>.from(configJson);
    final currentCount = updated['pushBackCount'];
    updated['pushBackCount'] = (currentCount is num ? currentCount.toInt() : 0) + 1;
    updated['pushBackComment'] = comment;
    return updated;
  }

  Future<void> _cleanupWorktree(String taskId, {Project? project}) async {
    try {
      await _worktreeManager?.cleanup(taskId, project: project);
    } catch (error) {
      _log.warning('Failed to cleanup worktree for task $taskId: $error');
    }
    _taskFileGuard?.deregister(taskId);
  }

  Future<Project?> _cleanupProjectForTask(Task task) async {
    final projectId = taskProjectId(task);
    if (projectId == null || projectId == '_local') {
      return null;
    }
    return _projectService?.get(projectId);
  }

  /// Extracts the session key from a task's [TaskOrigin] stored in [configJson].
  String? _extractSessionKey(Task task) {
    final origin = task.configJson['origin'];
    if (origin is! Map) return null;
    return origin['sessionKey'] as String?;
  }

  String _shortTaskId(String taskId) {
    final normalizedTaskId = taskId.replaceAll('-', '');
    if (normalizedTaskId.length <= 6) {
      return normalizedTaskId;
    }
    return normalizedTaskId.substring(0, 6);
  }
}
