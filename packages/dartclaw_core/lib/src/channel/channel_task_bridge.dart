import 'dart:async';

import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import '../runtime/channel_type.dart';
import '../task/task.dart';
import '../task/task_status.dart';
import '../utils/sliding_window_rate_limiter.dart';
import 'channel.dart';
import 'recipient_resolver.dart';
import 'review_command_parser.dart';
import 'task_creator.dart';
import 'task_origin.dart';
import 'task_trigger_config.dart';
import 'task_trigger_parser.dart';
import 'thread_binding.dart';

/// Callback for handling reserved commands such as `/stop`, `/status`, etc.
///
/// Returns a non-null response key when the command was handled (consumed).
/// Returns null when the message is not a recognized reserved command.
/// The handler is responsible for sending any response to the channel.
typedef ReservedCommandHandler = Future<String?> Function(ChannelMessage message, Channel channel);

/// Handles task-related message processing for channel inbound messages.
///
/// Extracted from [ChannelManager] to separate task workflow concerns from
/// channel lifecycle and message routing.
///
/// Receives injected callbacks for task creation, listing, and review handling.
/// It is a stateless coordinator — all state lives in the injected services.
class ChannelTaskBridge {
  static final _log = Logger('ChannelTaskBridge');

  final ReservedCommandHandler? _reservedCommandHandler;
  final TaskCreator? _taskCreator;
  final TaskLister? _taskLister;
  final ReviewCommandParser? _reviewCommandParser;
  final ChannelReviewHandler? _reviewHandler;
  final TaskTriggerParser? _triggerParser;
  final Map<ChannelType, TaskTriggerConfig> _taskTriggerConfigs;
  final SlidingWindowRateLimiter? _perSenderRateLimiter;
  final bool Function(String senderId)? _isAdmin;
  final bool Function(String text)? _isReservedCommand;
  final ThreadBindingStore? _threadBindings;
  final bool _threadBindingEnabled;

  ChannelTaskBridge({
    ReservedCommandHandler? reservedCommandHandler,
    TaskCreator? taskCreator,
    TaskLister? taskLister,
    ReviewCommandParser? reviewCommandParser,
    ChannelReviewHandler? reviewHandler,
    TaskTriggerParser? triggerParser,
    Map<ChannelType, TaskTriggerConfig> taskTriggerConfigs = const {},
    SlidingWindowRateLimiter? perSenderRateLimiter,
    bool Function(String senderId)? isAdmin,
    bool Function(String text)? isReservedCommand,
    ThreadBindingStore? threadBindings,
    bool threadBindingEnabled = false,
  }) : _reservedCommandHandler = reservedCommandHandler,
       _taskCreator = taskCreator,
       _taskLister = taskLister,
       _reviewCommandParser = reviewCommandParser,
       _reviewHandler = reviewHandler,
       _triggerParser = triggerParser,
       _taskTriggerConfigs = Map.unmodifiable(taskTriggerConfigs),
       _perSenderRateLimiter = perSenderRateLimiter,
       _isAdmin = isAdmin,
       _isReservedCommand = isReservedCommand,
       _threadBindings = threadBindings,
       _threadBindingEnabled = threadBindingEnabled;

  /// Returns `true` when [text] is recognized as a reserved command.
  ///
  /// Used by [ChannelManager] to let reserved commands bypass pause handling
  /// while still queueing all other inbound traffic during a pause window.
  bool isReservedCommand(String text) => _isReservedCommand?.call(text) ?? false;

  /// Returns the current thread binding for [message], if any.
  ///
  /// Lookup is gated by `features.thread_binding.enabled` and only applies to
  /// channels that attach a thread identifier to [ChannelMessage.metadata].
  ThreadBinding? lookupThreadBinding(ChannelMessage message) {
    if (!_threadBindingEnabled) return null;
    final threadBindings = _threadBindings;
    if (threadBindings == null) return null;

    final threadId = extractThreadId(message);
    if (threadId == null) return null;

    return threadBindings.lookupByThread(message.channelType.name, threadId);
  }

  /// Attempt to handle [message] as a task-related command.
  ///
  /// Routing precedence:
  ///   0. Reserved commands (/stop, /status) — highest priority, before rate limiting
  ///   1. Thread binding resolution — capture bound task/session context when thread binding is enabled
  ///   2. Per-sender rate limit check
  ///   3. Review commands (/accept, /reject, push back) with implicit bound-task targeting
  ///   4. Bound-thread routing to the resolved task session
  ///   5. Task triggers
  ///
  /// [enqueue] is an optional callback for routing messages to a session
  /// directly. Required for thread binding routing (step 1). When `null`,
  /// thread binding check is skipped.
  ///
  /// Returns `true` if the message was consumed (reserved command handled,
  /// thread binding routed, review command dispatched, task trigger processed,
  /// or an error response sent back to the sender). Returns `false` if the
  /// message is not task-related and should fall through to normal session
  /// routing via the queue.
  Future<bool> tryHandle(
    ChannelMessage message,
    Channel channel, {
    required String sessionKey,
    void Function(ChannelMessage, Channel, String)? enqueue,
    String? boundTaskId,
    ThreadBinding? boundThreadBinding,
  }) async {
    // 0. Reserved command check — highest priority, before rate limiting.
    // This ensures /stop and similar commands always work regardless of rate
    // limit state.
    final reservedHandler = _reservedCommandHandler;
    if (reservedHandler != null) {
      final response = await reservedHandler(message, channel);
      if (response != null) {
        return true; // consumed
      }
    }

    final threadBinding = boundThreadBinding ?? lookupThreadBinding(message);

    // 2. Per-sender rate limit check — before review commands and task triggers.
    // Exempt: admin senders, review commands (/accept, /reject, push back),
    // and reserved commands (/status, /stop).
    final rateLimiter = _perSenderRateLimiter;
    if (rateLimiter != null) {
      final senderId = message.senderJid;
      final isAdmin = _isAdmin?.call(senderId) ?? false;
      final isReserved = _isReservedCommand?.call(message.text) ?? false;
      final isReviewCmd = _reviewCommandParser?.parse(message.text) != null;
      if (!isAdmin && !isReserved && !isReviewCmd) {
        if (!rateLimiter.check(senderId)) {
          await _sendRateLimitRejection(message, channel);
          return true; // consumed — dropped
        }
      }
    }

    // 3. Review command check.
    final reviewCommandParser = _reviewCommandParser;
    final taskLister = _taskLister;
    final reviewHandler = _reviewHandler;
    if (reviewCommandParser != null && taskLister != null && reviewHandler != null) {
      final reviewCommand = reviewCommandParser.parse(message.text);
      if (reviewCommand != null) {
        // When routed via a thread binding, use the bound task ID implicitly
        // if the user did not supply an explicit task ID.
        final implicitTaskId = threadBinding?.taskId ?? boundTaskId;
        final effectiveCommand = (reviewCommand.taskId == null && implicitTaskId != null)
            ? ReviewCommand(action: reviewCommand.action, taskId: implicitTaskId, comment: reviewCommand.comment)
            : reviewCommand;

        // When the effective command has a resolved task ID (from binding or
        // explicit), commit directly to review dispatch — skip the
        // "no tasks in review" fallthrough.
        if (effectiveCommand.taskId != null) {
          final tasksInReview = await taskLister(status: TaskStatus.review);
          await _handleReviewCommand(message, channel, effectiveCommand, tasksInReview: tasksInReview);
          return true;
        }

        // No task ID — check if there are tasks in review before committing.
        // A bare "accept" with nothing in review should fall through to normal routing.
        final tasksInReview = await taskLister(status: TaskStatus.review);
        if (tasksInReview.isEmpty) {
          return false;
        }
        await _handleReviewCommand(message, channel, effectiveCommand, tasksInReview: tasksInReview);
        return true;
      }
    }

    // 4. Bound-thread routing — only after rate limits and implicit review
    // handling have had a chance to inspect the message.
    if (threadBinding != null && enqueue != null) {
      final threadBindings = _threadBindings;
      final threadId = extractThreadId(message);
      if (threadBindings != null && threadId != null) {
        unawaited(threadBindings.updateLastActivity(message.channelType.name, threadId, DateTime.now()));
      }
      enqueue(message, channel, threadBinding.sessionKey);
      return true;
    }

    // 5. Task trigger check.
    final triggerConfig = _taskTriggerConfigs[channel.type];
    final triggerParser = _triggerParser;
    if (triggerParser != null && triggerConfig != null && triggerConfig.enabled) {
      final trigger = triggerParser.parse(message.text, triggerConfig, emptyDescriptionError: true);
      if (trigger != null) {
        await _handleTaskTrigger(message, channel, trigger, sessionKey: sessionKey);
        return true;
      }
    }

    return false;
  }

  Future<void> _handleTaskTrigger(
    ChannelMessage message,
    Channel channel,
    TaskTriggerResult trigger, {
    required String sessionKey,
  }) async {
    final recipientId = resolveRecipientId(message);
    final sourceMessageId = _resolveSourceMessageId(message);

    if (trigger.description.isEmpty) {
      await _sendBestEffort(
        channel,
        recipientId,
        _taskTriggerResponse('Could not create task -- description required.', sourceMessageId: sourceMessageId),
        failureMessage: 'Failed to send empty-description task trigger response',
      );
      return;
    }

    final taskCreator = _taskCreator;
    if (taskCreator == null) {
      await _sendBestEffort(
        channel,
        recipientId,
        _taskTriggerResponse('Could not create task -- service unavailable.', sourceMessageId: sourceMessageId),
        failureMessage: 'Failed to send task service unavailable response',
      );
      return;
    }

    final senderDisplayName = message.senderDisplayName;
    final senderAvatarUrl = message.metadata['senderAvatarUrl'] as String?;
    final origin = TaskOrigin(
      channelType: channel.type.name,
      sessionKey: sessionKey,
      recipientId: recipientId,
      contactId: message.senderJid,
      sourceMessageId: sourceMessageId,
      senderDisplayName: senderDisplayName,
      senderId: message.senderJid,
      senderAvatarUrl: senderAvatarUrl,
    );

    try {
      final task = await taskCreator(
        id: const Uuid().v4(),
        title: trigger.description,
        description: trigger.description,
        type: trigger.type,
        autoStart: trigger.autoStart,
        createdBy: senderDisplayName,
        configJson: {'origin': origin.toJson()},
        trigger: 'channel',
      );

      final statusWord = task.status == TaskStatus.draft ? 'drafted' : 'created';
      await _sendBestEffort(
        channel,
        recipientId,
        _taskTriggerResponse(
          'Task $statusWord: ${task.title} [${task.type.name}] -- ID: ${_shortTaskId(task.id)}',
          sourceMessageId: sourceMessageId,
        ),
        failureMessage: 'Failed to send task creation acknowledgement for ${task.id}',
      );
    } catch (error, stackTrace) {
      _log.severe('Failed to create task from inbound channel message ${message.id}', error, stackTrace);
      await _sendBestEffort(
        channel,
        recipientId,
        _taskTriggerResponse('Could not create task -- service unavailable.', sourceMessageId: sourceMessageId),
        failureMessage: 'Failed to send task creation failure response',
      );
    }
  }

  Future<void> _handleReviewCommand(
    ChannelMessage message,
    Channel channel,
    ReviewCommand command, {
    required List<Task> tasksInReview,
  }) async {
    final recipientId = resolveRecipientId(message);
    final sourceMessageId = _resolveSourceMessageId(message);
    // Both are guaranteed non-null when this method is called (checked in tryHandle).
    final taskLister = _taskLister!;
    final reviewHandler = _reviewHandler!;

    try {
      Task? resolvedTask;
      if (command.taskId case final String requestedId) {
        final reviewMatches = _matchingTasks(tasksInReview, requestedId);
        if (reviewMatches.length == 1) {
          resolvedTask = reviewMatches.single;
        } else if (reviewMatches.length > 1) {
          await _sendBestEffort(
            channel,
            recipientId,
            _taskTriggerResponse(
              'Multiple tasks match ID $requestedId:\n'
              '${_formatTaskListing(reviewMatches)}\n'
              "Reply '${command.action} <id>' to specify.",
              sourceMessageId: sourceMessageId,
            ),
            failureMessage: 'Failed to send review disambiguation response',
          );
          return;
        } else {
          final allMatches = _matchingTasks(await taskLister(), requestedId);
          if (allMatches.isEmpty) {
            await _sendBestEffort(
              channel,
              recipientId,
              _taskTriggerResponse('No task found with ID $requestedId.', sourceMessageId: sourceMessageId),
              failureMessage: 'Failed to send review missing-task response',
            );
            return;
          }

          if (allMatches.length > 1) {
            await _sendBestEffort(
              channel,
              recipientId,
              _taskTriggerResponse(
                'Multiple tasks match ID $requestedId:\n'
                '${_formatTaskListing(allMatches, includeStatus: true)}\n'
                "Reply '${command.action} <id>' to specify.",
                sourceMessageId: sourceMessageId,
              ),
              failureMessage: 'Failed to send review disambiguation response',
            );
            return;
          }

          final matchedTask = allMatches.single;
          await _sendBestEffort(
            channel,
            recipientId,
            _taskTriggerResponse(
              'Task $requestedId is not in review (current status: ${matchedTask.status.name}).',
              sourceMessageId: sourceMessageId,
            ),
            failureMessage: 'Failed to send review invalid-state response',
          );
          return;
        }
      } else if (tasksInReview.length == 1) {
        resolvedTask = tasksInReview.single;
      } else {
        await _sendBestEffort(
          channel,
          recipientId,
          _taskTriggerResponse(
            'Multiple tasks in review:\n'
            '${_formatTaskListing(tasksInReview)}\n'
            "Reply '${command.action} <id>' to specify.",
            sourceMessageId: sourceMessageId,
          ),
          failureMessage: 'Failed to send review disambiguation response',
        );
        return;
      }

      final result = await reviewHandler(resolvedTask.id, command.action, comment: command.comment);
      switch (result) {
        case ChannelReviewSuccess(:final taskTitle, :final action):
          final verb = switch (action) {
            'accept' => 'accepted',
            'reject' => 'rejected',
            'push_back' => 'pushed back with feedback',
            _ => action,
          };
          await _sendBestEffort(
            channel,
            recipientId,
            _taskTriggerResponse("Task '$taskTitle' $verb.", sourceMessageId: sourceMessageId),
            failureMessage: 'Failed to send review confirmation',
          );
        case ChannelReviewMergeConflict(:final taskTitle):
          await _sendBestEffort(
            channel,
            recipientId,
            _taskTriggerResponse(
              "Task '$taskTitle' has merge conflicts. Review in web UI.",
              sourceMessageId: sourceMessageId,
            ),
            failureMessage: 'Failed to send review merge conflict response',
          );
        case ChannelReviewError(:final message):
          await _sendBestEffort(
            channel,
            recipientId,
            _taskTriggerResponse(_sanitizeReviewErrorMessage(message), sourceMessageId: sourceMessageId),
            failureMessage: 'Failed to send review error response',
          );
      }
    } catch (error, stackTrace) {
      _log.severe('Failed to review task from inbound channel message ${message.id}', error, stackTrace);
      await _sendBestEffort(
        channel,
        recipientId,
        _taskTriggerResponse('Could not review task -- service unavailable.', sourceMessageId: sourceMessageId),
        failureMessage: 'Failed to send review failure response',
      );
    }
  }

  // ---- Private helpers ----

  String? _resolveSourceMessageId(ChannelMessage message) {
    final metadataSourceMessageId = message.metadata[sourceMessageIdMetadataKey];
    if (metadataSourceMessageId is String && metadataSourceMessageId.isNotEmpty) {
      return metadataSourceMessageId;
    }
    return message.id.isEmpty ? null : message.id;
  }

  String _shortTaskId(String taskId) {
    final normalizedTaskId = _normalizedTaskId(taskId);
    if (normalizedTaskId.length <= 6) {
      return normalizedTaskId;
    }
    return normalizedTaskId.substring(0, 6);
  }

  String _normalizedTaskId(String taskId) => taskId.replaceAll('-', '').toLowerCase();

  List<Task> _matchingTasks(Iterable<Task> tasks, String requestedId) {
    final normalizedRequestedId = _normalizedTaskId(requestedId);
    if (normalizedRequestedId.isEmpty) {
      return const [];
    }
    return tasks.where((task) => _normalizedTaskId(task.id).startsWith(normalizedRequestedId)).toList();
  }

  String _formatTaskListing(Iterable<Task> tasks, {bool includeStatus = false}) {
    final taskList = tasks.toList(growable: false);
    final displayIds = _displayTaskIds(taskList);
    return taskList
        .map((task) {
          final label = '${displayIds[task.id]}: ${task.title}';
          if (!includeStatus) {
            return label;
          }
          return '$label (${task.status.name})';
        })
        .join('\n');
  }

  Map<String, String> _displayTaskIds(List<Task> tasks) {
    final normalizedIds = {for (final task in tasks) task.id: _normalizedTaskId(task.id)};
    final displayIds = <String, String>{};

    for (final task in tasks) {
      final normalizedTaskId = normalizedIds[task.id]!;
      var prefixLength = normalizedTaskId.length < 6 ? normalizedTaskId.length : 6;
      while (prefixLength < normalizedTaskId.length) {
        final prefix = normalizedTaskId.substring(0, prefixLength);
        final hasCollision = tasks.any((candidate) {
          if (candidate.id == task.id) {
            return false;
          }
          return normalizedIds[candidate.id]!.startsWith(prefix);
        });
        if (!hasCollision) {
          break;
        }
        prefixLength += 1;
      }
      displayIds[task.id] = normalizedTaskId.substring(0, prefixLength);
    }

    return displayIds;
  }

  ChannelResponse _taskTriggerResponse(String text, {String? sourceMessageId}) {
    if (sourceMessageId == null) {
      return ChannelResponse(text: text);
    }
    return ChannelResponse(text: text, metadata: {sourceMessageIdMetadataKey: sourceMessageId});
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

  Future<void> _sendRateLimitRejection(ChannelMessage message, Channel channel) async {
    final recipientId = resolveRecipientId(message);
    await _sendBestEffort(
      channel,
      recipientId,
      ChannelResponse(text: "You're sending messages too fast. Please wait before trying again."),
      failureMessage: 'Failed to send rate limit rejection',
    );
  }

  Future<void> _sendBestEffort(
    Channel channel,
    String recipientId,
    ChannelResponse response, {
    required String failureMessage,
  }) async {
    try {
      await channel.sendMessage(recipientId, response);
    } catch (error, stackTrace) {
      _log.warning(failureMessage, error, stackTrace);
    }
  }

}
