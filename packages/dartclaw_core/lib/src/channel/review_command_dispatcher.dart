import 'package:logging/logging.dart';

import '../task/task.dart';
import '../task/task_status.dart';
import 'channel.dart';
import 'recipient_resolver.dart';
import 'review_command_parser.dart';
import 'task_creator.dart';
import 'task_trigger_evaluator.dart';
import 'thread_binding.dart';

/// Dispatches review commands (accept/reject/push back) to the review handler.
///
/// Resolves the target task from thread bindings, explicit IDs, or the single
/// task in review. Sends response messages back through the channel.
class ReviewCommandDispatcher {
  static final _log = Logger('ReviewCommandDispatcher');

  final ReviewCommandParser _reviewCommandParser;
  final ChannelReviewHandler _reviewHandler;
  final TaskLister _taskLister;
  final TaskTriggerEvaluator _taskTriggerEvaluator;
  final Future<void> Function(
    Channel channel,
    String recipientId,
    ChannelResponse response, {
    required String failureMessage,
  })
  _sendBestEffort;

  ReviewCommandDispatcher({
    required ReviewCommandParser reviewCommandParser,
    required ChannelReviewHandler reviewHandler,
    required TaskLister taskLister,
    required TaskTriggerEvaluator taskTriggerEvaluator,
    required Future<void> Function(
      Channel channel,
      String recipientId,
      ChannelResponse response, {
      required String failureMessage,
    })
    sendBestEffort,
  }) : _reviewCommandParser = reviewCommandParser,
       _reviewHandler = reviewHandler,
       _taskLister = taskLister,
       _taskTriggerEvaluator = taskTriggerEvaluator,
       _sendBestEffort = sendBestEffort;

  /// Attempts to handle [message] as a review command.
  ///
  /// Returns `true` if the message was consumed as a review command.
  Future<bool> tryHandle(
    ChannelMessage message,
    Channel channel, {
    String? boundTaskId,
    ThreadBinding? threadBinding,
    String? sourceMessageId,
  }) async {
    final reviewCommand = _reviewCommandParser.parse(message.text);
    if (reviewCommand == null) {
      return false;
    }

    final implicitTaskId = threadBinding?.taskId ?? boundTaskId;
    final effectiveCommand = reviewCommand.taskId == null && implicitTaskId != null
        ? ReviewCommand(action: reviewCommand.action, taskId: implicitTaskId, comment: reviewCommand.comment)
        : reviewCommand;

    if (effectiveCommand.taskId != null) {
      final tasksInReview = await _taskLister(status: TaskStatus.review);
      await _handleReviewCommand(
        message,
        channel,
        effectiveCommand,
        tasksInReview: tasksInReview,
        sourceMessageId: sourceMessageId,
      );
      return true;
    }

    final tasksInReview = await _taskLister(status: TaskStatus.review);
    if (tasksInReview.isEmpty) {
      return false;
    }

    await _handleReviewCommand(
      message,
      channel,
      effectiveCommand,
      tasksInReview: tasksInReview,
      sourceMessageId: sourceMessageId,
    );
    return true;
  }

  Future<void> _handleReviewCommand(
    ChannelMessage message,
    Channel channel,
    ReviewCommand command, {
    required List<Task> tasksInReview,
    required String? sourceMessageId,
  }) async {
    final recipientId = resolveRecipientId(message);

    try {
      final resolvedTask = await _resolveReviewTask(
        command,
        tasksInReview: tasksInReview,
        channel: channel,
        recipientId: recipientId,
        sourceMessageId: sourceMessageId,
      );
      if (resolvedTask == null) {
        return;
      }

      final result = await _reviewHandler(resolvedTask.id, command.action, comment: command.comment);
      switch (result) {
        case ChannelReviewSuccess(:final taskTitle, :final action):
          final verb = switch (action) {
            'accept' => 'accepted',
            'reject' => 'rejected',
            'push_back' => 'pushed back with feedback',
            _ => action,
          };
          await _sendTaskResponse(
            channel,
            recipientId,
            "Task '$taskTitle' $verb.",
            sourceMessageId: sourceMessageId,
            failureMessage: 'Failed to send review confirmation',
          );
        case ChannelReviewMergeConflict(:final taskTitle):
          await _sendTaskResponse(
            channel,
            recipientId,
            "Task '$taskTitle' has merge conflicts. Review in web UI.",
            sourceMessageId: sourceMessageId,
            failureMessage: 'Failed to send review merge conflict response',
          );
        case ChannelReviewError(:final message):
          await _sendTaskResponse(
            channel,
            recipientId,
            _sanitizeReviewErrorMessage(message),
            sourceMessageId: sourceMessageId,
            failureMessage: 'Failed to send review error response',
          );
      }
    } catch (error, stackTrace) {
      _log.severe('Failed to review task from inbound channel message ${message.id}', error, stackTrace);
      await _sendTaskResponse(
        channel,
        recipientId,
        'Could not review task -- service unavailable.',
        sourceMessageId: sourceMessageId,
        failureMessage: 'Failed to send review failure response',
      );
    }
  }

  Future<Task?> _resolveReviewTask(
    ReviewCommand command, {
    required List<Task> tasksInReview,
    required Channel channel,
    required String recipientId,
    required String? sourceMessageId,
  }) async {
    final requestedId = command.taskId;
    if (requestedId == null) {
      if (tasksInReview.length == 1) {
        return tasksInReview.single;
      }
      await _sendMultipleTasksInReview(
        channel,
        recipientId,
        command.action,
        tasksInReview,
        sourceMessageId: sourceMessageId,
      );
      return null;
    }

    final reviewMatches = _taskTriggerEvaluator.matchingTasks(tasksInReview, requestedId);
    if (reviewMatches.length == 1) {
      return reviewMatches.single;
    }
    if (reviewMatches.length > 1) {
      await _sendTaskResponse(
        channel,
        recipientId,
        'Multiple tasks match ID $requestedId:\n'
        '${_taskTriggerEvaluator.formatTaskListing(reviewMatches)}\n'
        "Reply '${command.action} <id>' to specify.",
        sourceMessageId: sourceMessageId,
        failureMessage: 'Failed to send review disambiguation response',
      );
      return null;
    }

    final allMatches = _taskTriggerEvaluator.matchingTasks(await _taskLister(), requestedId);
    if (allMatches.isEmpty) {
      await _sendTaskResponse(
        channel,
        recipientId,
        'No task found with ID $requestedId.',
        sourceMessageId: sourceMessageId,
        failureMessage: 'Failed to send review missing-task response',
      );
      return null;
    }
    if (allMatches.length > 1) {
      await _sendTaskResponse(
        channel,
        recipientId,
        'Multiple tasks match ID $requestedId:\n'
        '${_taskTriggerEvaluator.formatTaskListing(allMatches, includeStatus: true)}\n'
        "Reply '${command.action} <id>' to specify.",
        sourceMessageId: sourceMessageId,
        failureMessage: 'Failed to send review disambiguation response',
      );
      return null;
    }

    final matchedTask = allMatches.single;
    await _sendTaskResponse(
      channel,
      recipientId,
      'Task $requestedId is not in review (current status: ${matchedTask.status.name}).',
      sourceMessageId: sourceMessageId,
      failureMessage: 'Failed to send review invalid-state response',
    );
    return null;
  }

  Future<void> _sendMultipleTasksInReview(
    Channel channel,
    String recipientId,
    String action,
    List<Task> tasks, {
    required String? sourceMessageId,
  }) {
    return _sendTaskResponse(
      channel,
      recipientId,
      'Multiple tasks in review:\n${_taskTriggerEvaluator.formatTaskListing(tasks)}\nReply '
      "'$action <id>' to specify.",
      sourceMessageId: sourceMessageId,
      failureMessage: 'Failed to send review disambiguation response',
    );
  }

  Future<void> _sendTaskResponse(
    Channel channel,
    String recipientId,
    String text, {
    required String? sourceMessageId,
    required String failureMessage,
  }) {
    return _sendBestEffort(
      channel,
      recipientId,
      _taskTriggerEvaluator.taskTriggerResponse(text, sourceMessageId: sourceMessageId),
      failureMessage: failureMessage,
    );
  }

  String _sanitizeReviewErrorMessage(String message) {
    final trimmed = message.trim();
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('could not accept task:') ||
        lower.startsWith('could not reject task:') ||
        lower.startsWith('could not push back task:')) {
      return 'Review action failed. Please try again or use the web UI.';
    }
    return trimmed;
  }
}
