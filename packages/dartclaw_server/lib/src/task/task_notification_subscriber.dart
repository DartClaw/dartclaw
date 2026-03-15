import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:logging/logging.dart';

/// Sends channel notifications for channel-originated task status changes.
class TaskNotificationSubscriber {
  static final _log = Logger('TaskNotificationSubscriber');

  final TaskService _tasks;
  final ChannelManager _channelManager;
  final ChatCardBuilder _googleChatCardBuilder;
  StreamSubscription<TaskStatusChangedEvent>? _subscription;

  TaskNotificationSubscriber({
    required TaskService tasks,
    required ChannelManager channelManager,
    ChatCardBuilder? googleChatCardBuilder,
  }) : _tasks = tasks,
       _channelManager = channelManager,
       _googleChatCardBuilder = googleChatCardBuilder ?? const ChatCardBuilder();

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
