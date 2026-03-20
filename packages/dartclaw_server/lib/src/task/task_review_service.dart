// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import 'merge_executor.dart';
import 'task_event_helpers.dart';
import 'task_file_guard.dart';
import 'task_service.dart';
import 'worktree_manager.dart';

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
  final EventBus _eventBus;
  final WorktreeManager? _worktreeManager;
  final TaskFileGuard? _taskFileGuard;
  final MergeExecutor? _mergeExecutor;
  final String? _dataDir;
  final String _mergeStrategy;
  final String _baseRef;
  final Map<String, Future<void>> _reviewLocks = <String, Future<void>>{};

  TaskReviewService({
    required TaskService tasks,
    required EventBus eventBus,
    WorktreeManager? worktreeManager,
    TaskFileGuard? taskFileGuard,
    MergeExecutor? mergeExecutor,
    String? dataDir,
    String mergeStrategy = 'squash',
    String baseRef = 'main',
  }) : _tasks = tasks,
       _eventBus = eventBus,
       _worktreeManager = worktreeManager,
       _taskFileGuard = taskFileGuard,
       _mergeExecutor = mergeExecutor,
       _dataDir = dataDir,
       _mergeStrategy = mergeStrategy,
       _baseRef = baseRef;

  /// Builds a channel-facing review handler backed by this service.
  ChannelReviewHandler channelReviewHandler({String trigger = 'channel'}) {
    return (taskId, action) => reviewForChannel(taskId, action, trigger: trigger);
  }

  /// Executes a review action for [taskId].
  Future<ReviewResult> review(String taskId, String action, {String? comment, String trigger = 'user'}) async {
    return _withTaskLock(taskId, () => _reviewUnlocked(taskId, action, comment: comment, trigger: trigger));
  }

  /// Executes a review action and maps the outcome to a channel response.
  Future<ChannelReviewResult> reviewForChannel(String taskId, String action, {String trigger = 'channel'}) async {
    final result = await review(taskId, action, trigger: trigger);
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
      'push_back' => TaskStatus.queued,
      _ => null,
    };
    if (targetStatus == null) {
      return const ReviewInvalidRequest('action must be one of: accept, reject, push_back');
    }

    final trimmedComment = comment?.trim();
    if (targetStatus == TaskStatus.queued && (trimmedComment == null || trimmedComment.isEmpty)) {
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

      if (targetStatus == TaskStatus.accepted && task.worktreeJson != null && _mergeExecutor == null) {
        return const ReviewActionFailed(
          'Merge infrastructure is not available. Use the web UI or configure merge support.',
        );
      }

      if (targetStatus == TaskStatus.accepted && task.worktreeJson != null && _mergeExecutor != null) {
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
      }

      final transitionTime = DateTime.now();
      final transitionConfig = targetStatus == TaskStatus.queued
          ? _withPushBackComment(task.transition(targetStatus, now: transitionTime).configJson, trimmedComment!)
          : null;

      final updated = await _tasks.transition(taskId, targetStatus, now: transitionTime, configJson: transitionConfig);

      await fireTaskLifecycleEvents(
        tasks: _tasks,
        eventBus: _eventBus,
        taskId: taskId,
        oldStatus: oldStatus,
        newStatus: updated.status,
        trigger: trigger,
      );

      if ((targetStatus == TaskStatus.accepted || targetStatus == TaskStatus.rejected) && task.worktreeJson != null) {
        await _cleanupWorktree(taskId);
      }

      return ReviewSuccess(updated);
    } on ArgumentError {
      return ReviewNotFound(taskId);
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

  Map<String, dynamic> _withPushBackComment(Map<String, dynamic> configJson, String comment) =>
      Map<String, dynamic>.from(configJson)..['pushBackComment'] = comment;

  Future<void> _cleanupWorktree(String taskId) async {
    try {
      await _worktreeManager?.cleanup(taskId);
    } catch (error) {
      _log.warning('Failed to cleanup worktree for task $taskId: $error');
    }
    _taskFileGuard?.deregister(taskId);
  }

  String _shortTaskId(String taskId) {
    final normalizedTaskId = taskId.replaceAll('-', '');
    if (normalizedTaskId.length <= 6) {
      return normalizedTaskId;
    }
    return normalizedTaskId.substring(0, 6);
  }
}
