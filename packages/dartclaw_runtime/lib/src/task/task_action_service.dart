import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';

import 'task_file_guard.dart';
import 'task_project_ref.dart';
import 'task_review_service.dart';
import 'task_service.dart';
import 'worktree_cleanup.dart';
import 'worktree_manager.dart';

sealed class TaskActionResult {
  const new();
}

final class TaskActionSuccess extends TaskActionResult {
  const new(this.task);
  final Task task;
}

final class TaskActionRefused extends TaskActionResult {
  const new({required this.statusCode, required this.code, required this.message, this.details = const {}});
  final int statusCode;
  final String code;
  final String message;
  final Map<String, Object?> details;
  String? get field => details['field'] as String?;
}

/// The shared authority for task lifecycle actions exposed by the API and web UI.
final class TaskActionService {
  new({
    required this.tasks,
    required this.reviewService,
    this.turns,
    this.worktreeManager,
    this.taskFileGuard,
    this.projectService,
  });

  final TaskService tasks;
  final TaskReviewService reviewService;
  final TurnManager? turns;
  final WorktreeManager? worktreeManager;
  final TaskFileGuard? taskFileGuard;
  final ProjectService? projectService;

  Future<TaskActionResult> start(String taskId) =>
      _transition(taskId, TaskStatus.queued, 'INVALID_TRANSITION', 'user', 'start task');

  Future<TaskActionResult> checkout(String taskId) =>
      _transition(taskId, TaskStatus.running, 'CHECKOUT_CONFLICT', 'system', 'checkout task');

  Future<TaskActionResult> cancel(String taskId) async {
    try {
      final task = await tasks.get(taskId);
      final result = await _transition(taskId, TaskStatus.cancelled, 'INVALID_TRANSITION', 'user', 'cancel task');
      if (result is! TaskActionSuccess) return result;

      if (task?.worktreeJson != null) {
        final cleanupProject = await _cleanupProjectForTask(task);
        await cleanupWorktree(worktreeManager, taskFileGuard, taskId, project: cleanupProject);
      }
      if (task?.sessionId != null && task?.status == TaskStatus.running) {
        await turns?.cancelTurn(task!.sessionId!);
      }
      return result;
    } catch (_) {
      return const TaskActionRefused(statusCode: 500, code: 'INTERNAL_ERROR', message: 'Failed to cancel task');
    }
  }

  Future<TaskActionResult> review(String taskId, Map<String, dynamic> input) async {
    try {
      final actionTypeError = _validateStringFieldType(input, 'action');
      if (actionTypeError != null) return actionTypeError;
      final commentTypeError = _validateStringFieldType(input, 'comment');
      if (commentTypeError != null) return commentTypeError;

      final action = input['action'] as String? ?? '';
      final comment = input['comment'] as String?;
      final result = await reviewService.review(taskId, action, comment: comment, trigger: 'user');
      return switch (result) {
        ReviewSuccess(:final task) => TaskActionSuccess(task),
        ReviewMergeConflict(:final conflictingFiles, :final details) => TaskActionRefused(
          statusCode: 409,
          code: 'MERGE_CONFLICT',
          message: 'Merge conflict detected',
          details: {'conflictingFiles': conflictingFiles, 'details': details},
        ),
        ReviewNotFound() => const TaskActionRefused(statusCode: 404, code: 'TASK_NOT_FOUND', message: 'Task not found'),
        ReviewInvalidTransition(:final taskId, :final oldStatus, :final targetStatus, :final currentStatus) =>
          TaskActionRefused(
            statusCode: 409,
            code: 'INVALID_TRANSITION',
            message: 'Cannot transition from ${oldStatus.name} to ${targetStatus.name}',
            details: {'currentStatus': currentStatus.name, 'taskId': taskId},
          ),
        ReviewInvalidRequest(:final message, :final field) => TaskActionRefused(
          statusCode: 400,
          code: 'INVALID_INPUT',
          message: message,
          details: {'field': field},
        ),
        ReviewActionFailed(:final message) => TaskActionRefused(
          statusCode: 500,
          code: 'INTERNAL_ERROR',
          message: _sanitizeReviewFailureMessage(message),
        ),
      };
    } catch (_) {
      return const TaskActionRefused(statusCode: 500, code: 'INTERNAL_ERROR', message: 'Failed to review task');
    }
  }

  Future<TaskActionResult> _transition(
    String taskId,
    TaskStatus targetStatus,
    String errorCode,
    String trigger,
    String actionLabel,
  ) async {
    try {
      final task = await tasks.get(taskId);
      if (task == null) return _notFound;

      final oldStatus = task.status;
      try {
        return TaskActionSuccess(await tasks.transition(taskId, targetStatus, trigger: trigger));
      } on ArgumentError {
        return _notFound;
      } on VersionConflictException catch (error) {
        return TaskActionRefused(
          statusCode: 409,
          code: 'VERSION_CONFLICT',
          message: 'Task was modified concurrently. Refresh and retry.',
          details: {'currentVersion': error.currentVersion},
        );
      } on StateError {
        final current = await tasks.get(taskId);
        return TaskActionRefused(
          statusCode: 409,
          code: errorCode,
          message: 'Cannot transition from ${oldStatus.name} to ${targetStatus.name}',
          details: {'currentStatus': current?.status.name ?? task.status.name},
        );
      }
    } catch (_) {
      return TaskActionRefused(statusCode: 500, code: 'INTERNAL_ERROR', message: 'Failed to $actionLabel');
    }
  }

  Future<Project?> _cleanupProjectForTask(Task? task) async {
    if (task == null || projectService == null) return null;
    final projectId = taskProjectId(task);
    if (projectId == null || projectId == '_local') return null;
    return projectService!.get(projectId);
  }
}

const _notFound = TaskActionRefused(statusCode: 404, code: 'TASK_NOT_FOUND', message: 'Task not found');

TaskActionRefused? _validateStringFieldType(Map<String, dynamic> body, String field) {
  if (!body.containsKey(field)) return null;
  final value = body[field];
  if (value == null || value is String) return null;
  return TaskActionRefused(
    statusCode: 400,
    code: 'INVALID_INPUT',
    message: '$field must be a string',
    details: {'field': field},
  );
}

String _sanitizeReviewFailureMessage(String message) {
  final trimmed = message.trim();
  final lower = trimmed.toLowerCase();
  if (lower.startsWith('could not accept task:') ||
      lower.startsWith('could not reject task:') ||
      lower.startsWith('could not push back task:')) {
    return 'Review action failed. Please try again or use the web UI.';
  }
  return trimmed;
}
