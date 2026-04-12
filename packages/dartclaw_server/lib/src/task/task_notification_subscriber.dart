import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:logging/logging.dart';

import 'task_service.dart';

/// Sends channel notifications for channel-originated task status changes.
class TaskNotificationSubscriber {
  static final _log = Logger('TaskNotificationSubscriber');

  final TaskService _tasks;
  final ChannelManager _channelManager;
  final ChatCardBuilder _googleChatCardBuilder;
  final ThreadBindingStore? _threadBindings;
  final bool _threadBindingEnabled;
  StreamSubscription<TaskStatusChangedEvent>? _subscription;

  TaskNotificationSubscriber({
    required TaskService tasks,
    required ChannelManager channelManager,
    ChatCardBuilder? googleChatCardBuilder,
    ThreadBindingStore? threadBindings,
    bool threadBindingEnabled = false,
  }) : _tasks = tasks,
       _channelManager = channelManager,
       _googleChatCardBuilder = googleChatCardBuilder ?? const ChatCardBuilder(),
       _threadBindings = threadBindings,
       _threadBindingEnabled = threadBindingEnabled;

  void subscribe(EventBus eventBus) {
    _subscription ??= eventBus.on<TaskStatusChangedEvent>().listen((event) {
      unawaited(_onTaskStatusChanged(event));
    });
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  Future<void> _onTaskStatusChanged(TaskStatusChangedEvent event) async {
    if (!_isNotifiable(event)) {
      return;
    }

    final task = await _tasks.get(event.taskId);
    if (task == null) {
      _log.warning('Task ${event.taskId} not found while preparing channel notification');
      return;
    }

    final origin = TaskOrigin.fromConfigJson(task.configJson);
    if (origin == null) {
      return;
    }

    final channelType = ChannelType.values.asNameMap()[origin.channelType];
    if (channelType == null) {
      _log.warning('Unknown channel type "${origin.channelType}" on task ${task.id}');
      return;
    }

    final channel = _channelManager.channels.where((candidate) => candidate.type == channelType).firstOrNull;
    if (channel == null) {
      _log.warning('No registered channel found for ${origin.channelType} while notifying task ${task.id}');
      return;
    }

    final text = _notificationText(task, event);
    if (text == null) {
      return;
    }

    final response = _buildNotificationResponse(channelType: channelType, task: task, event: event, fallbackText: text);

    // For Google Chat with thread binding: send in a new or existing thread and
    // create a thread binding on the initial notification.
    if (_threadBindingEnabled && channelType == ChannelType.googlechat && channel is GoogleChatChannel) {
      final threadKey = 'task-${task.id}';

      if (_isInitialNotification(event)) {
        // First notification: send in a new thread and capture the thread name.
        final threadName = await channel.sendMessageWithThread(origin.recipientId, response, threadKey: threadKey);
        if (threadName != null) {
          final threadBindings = _threadBindings;
          if (threadBindings != null) {
            final now = DateTime.now();
            try {
              await threadBindings.create(
                ThreadBinding(
                  channelType: origin.channelType,
                  threadId: threadName,
                  taskId: task.id,
                  sessionKey: origin.sessionKey,
                  createdAt: now,
                  lastActivity: now,
                ),
              );
            } catch (error, stackTrace) {
              _log.warning('Failed to create thread binding for task ${task.id} thread $threadName', error, stackTrace);
            }
          }
        } else {
          _log.warning('Thread send returned null thread name for task ${task.id} — binding not created');
        }
        return;
      }

      // Subsequent notifications: send to the existing thread if bound.
      final existingBindings = _threadBindings?.lookupByTask(task.id) ?? const <ThreadBinding>[];
      if (existingBindings.isNotEmpty) {
        await channel.sendMessageWithThread(origin.recipientId, response, threadKey: threadKey);
        return;
      }
    }

    // Default: send without thread.
    try {
      await channel.sendMessage(origin.recipientId, response);
    } catch (error, stackTrace) {
      _log.warning(
        'Failed to notify ${origin.channelType} recipient ${origin.recipientId} for task ${task.id}',
        error,
        stackTrace,
      );
    }
  }

  bool _isInitialNotification(TaskStatusChangedEvent event) =>
      event.oldStatus == TaskStatus.queued && event.newStatus == TaskStatus.running;

  ChannelResponse _buildNotificationResponse({
    required ChannelType channelType,
    required Task task,
    required TaskStatusChangedEvent event,
    required String fallbackText,
  }) {
    if (channelType != ChannelType.googlechat) {
      return ChannelResponse(text: fallbackText);
    }

    try {
      return ChannelResponse(
        text: fallbackText,
        structuredPayload: _googleChatCardBuilder.taskNotification(
          taskId: task.id,
          title: task.title,
          status: event.newStatus.name,
          description: task.description,
          errorSummary: _errorSummary(task),
          requestedBy: task.createdBy,
          createdAt: task.createdAt,
          updatedAt: event.timestamp,
          includeReviewButtons: event.newStatus == TaskStatus.review,
        ),
      );
    } catch (error, stackTrace) {
      _log.warning('Failed to build Google Chat card for task ${task.id}', error, stackTrace);
      return ChannelResponse(text: fallbackText);
    }
  }

  bool _isNotifiable(TaskStatusChangedEvent event) => switch ((event.oldStatus, event.newStatus)) {
    (TaskStatus.queued, TaskStatus.running) => true,
    (TaskStatus.running, TaskStatus.review) => true,
    (TaskStatus.review, TaskStatus.accepted) => true,
    (TaskStatus.review, TaskStatus.rejected) => true,
    (TaskStatus.running, TaskStatus.failed) => true,
    _ => false,
  };

  String? _notificationText(Task task, TaskStatusChangedEvent event) => switch ((event.oldStatus, event.newStatus)) {
    (TaskStatus.queued, TaskStatus.running) => "Task '${task.title}' is now running.",
    (TaskStatus.running, TaskStatus.review) => "Task '${task.title}' needs review. Reply 'accept' or 'reject'.",
    (TaskStatus.review, TaskStatus.accepted) =>
      task.worktreeJson == null ? "Task '${task.title}' accepted." : "Task '${task.title}' accepted. Changes merged.",
    (TaskStatus.review, TaskStatus.rejected) => "Task '${task.title}' rejected. Changes discarded.",
    (TaskStatus.running, TaskStatus.failed) => _failedMessage(task),
    _ => null,
  };

  String _failedMessage(Task task) {
    final summary = _errorSummary(task);
    if (summary != null) {
      final suffix = RegExp(r'[.!?]$').hasMatch(summary) ? '' : '.';
      return "Task '${task.title}' failed: $summary$suffix";
    }
    return "Task '${task.title}' failed.";
  }

  String? _errorSummary(Task task) {
    final rawSummary = task.configJson['errorSummary'];
    if (rawSummary is String && rawSummary.trim().isNotEmpty) {
      return rawSummary.trim();
    }
    return null;
  }
}
