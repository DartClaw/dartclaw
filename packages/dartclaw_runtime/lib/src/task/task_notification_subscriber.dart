import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:logging/logging.dart';

import 'channel_notification_delivery.dart';
import 'task_service.dart';

/// Sends channel notifications for channel-originated task status changes.
///
/// A channel that declares [Channel.threadedNotifications] renders the
/// notification natively and, given [threadBindings], threads a task's
/// notifications; every other channel gets one plain send.
class TaskNotificationSubscriber {
  static final _log = Logger('TaskNotificationSubscriber');

  final TaskService _tasks;
  final ChannelManager _channelManager;
  final ChannelNotificationDelivery _delivery = ChannelNotificationDelivery();
  final ThreadBindingStore? _threadBindings;

  /// Public base URL used to link a review-ready task, or `null` when the
  /// deployment declares none and the notification can only name the
  /// conversational path.
  final String? _baseUrl;
  StreamSubscription<TaskStatusChangedEvent>? _subscription;

  /// [threadBindings] is the store task binding is enabled with, `null` while it is off.
  new({
    required TaskService tasks,
    required ChannelManager channelManager,
    ThreadBindingStore? threadBindings,
    String? baseUrl,
  }) : _baseUrl = baseUrl,
       _tasks = tasks,
       _channelManager = channelManager,
       _threadBindings = threadBindings;

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
    try {
      await _notify(event);
    } finally {
      if (event.newStatus.terminal) _delivery.forget('task ${event.taskId}');
    }
  }

  Future<void> _notify(TaskStatusChangedEvent event) async {
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

    final notification = ChannelNotification(
      kind: ChannelNotificationKind.task,
      id: task.id,
      text: text,
      title: task.title,
      status: event.newStatus.name,
      body: task.description,
      error: _errorSummary(task),
      requestedBy: task.createdBy,
      createdAt: task.createdAt,
      updatedAt: event.timestamp,
      reviewActions: event.newStatus == TaskStatus.review,
    );
    final subject = 'task ${task.id}';
    final threads = channel.threadedNotifications;
    if (threads == null) {
      await _delivery.sendPlain(channel, origin.recipientId, notification, subject: subject);
      return;
    }

    final response = threads.render(notification);
    final threadBindings = _threadBindings;
    if (threadBindings == null) {
      await _delivery.sendRendered(channel, origin.recipientId, response, notification: notification, subject: subject);
      return;
    }

    if (_isInitialNotification(event)) {
      final post = await _delivery.sendInNewThread(
        channel,
        threads,
        origin.recipientId,
        response,
        notification: notification,
        threadKey: 'task-${task.id}',
        subject: subject,
      );
      if (post != null) await _bindTaskThread(threadBindings, origin, task, post);
      return;
    }

    final binding = threadBindings.lookupByTask(task.id).where((b) => b.channelType == origin.channelType).firstOrNull;
    if (binding == null) {
      await _delivery.sendRendered(channel, origin.recipientId, response, notification: notification, subject: subject);
      return;
    }
    await _delivery.sendInThread(
      channel,
      threads,
      origin.recipientId,
      response,
      notification: notification,
      threadId: binding.threadId,
      subject: subject,
    );
  }

  Future<void> _bindTaskThread(
    ThreadBindingStore threadBindings,
    TaskOrigin origin,
    Task task,
    ThreadedPost post,
  ) async {
    final now = DateTime.now();
    try {
      await threadBindings.create(
        ThreadBinding.task(
          channelType: origin.channelType,
          threadId: post.threadId,
          taskId: task.id,
          sessionKey: origin.sessionKey,
          createdAt: now,
          lastActivity: now,
        ),
      );
    } catch (error, stackTrace) {
      _log.warning('Failed to create thread binding for task ${task.id} thread ${post.threadId}', error, stackTrace);
    }
  }

  bool _isInitialNotification(TaskStatusChangedEvent event) =>
      event.oldStatus == TaskStatus.queued && event.newStatus == TaskStatus.running;

  bool _isNotifiable(TaskStatusChangedEvent event) => switch ((event.oldStatus, event.newStatus)) {
    (TaskStatus.queued, TaskStatus.running) => true,
    (TaskStatus.running, TaskStatus.review) => true,
    (TaskStatus.review, TaskStatus.accepted) => true,
    (TaskStatus.review, TaskStatus.rejected) => true,
    (TaskStatus.running, TaskStatus.failed) => true,
    _ => false,
  };

  /// Names the task and both ways to act on it.
  ///
  /// A channel without an interactive card had no call to action once the
  /// host-side accept/reject grammar was removed — the notification announced
  /// work and left the reader with nowhere to go. Neither route named here is a
  /// grammar: the host parses no reply, and "tell me" reaches the agent, which
  /// decides for itself whether to call the review tool.
  String _reviewReadyMessage(Task task) {
    final url = publicPageUrl(_baseUrl, '/tasks/${task.id}');
    final where = url == null ? 'Review it in the web UI' : 'Review it at $url';
    return "Task '${task.title}' needs review. $where, or tell me here to accept or reject it.";
  }

  String? _notificationText(Task task, TaskStatusChangedEvent event) => switch ((event.oldStatus, event.newStatus)) {
    (TaskStatus.queued, TaskStatus.running) => "Task '${task.title}' is now running.",
    (TaskStatus.running, TaskStatus.review) => _reviewReadyMessage(task),
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
