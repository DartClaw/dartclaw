import 'dart:async';

import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import 'package:dartclaw_models/dartclaw_models.dart';
import 'channel.dart';
import 'channel_config.dart';
import 'message_queue.dart';
import 'review_command_parser.dart';
import 'task_origin.dart';
import 'task_trigger_config.dart';
import 'task_trigger_parser.dart';
import '../config/live_scope_config.dart';
import '../config/session_scope_config.dart';
import '../events/dartclaw_event.dart';
import '../events/event_bus.dart';
import '../task/task.dart';
import '../task/task_service.dart';
import '../task/task_status.dart';

/// Manages channel registration, lifecycle, and inbound message routing.
class ChannelManager {
  static final _log = Logger('ChannelManager');

  final MessageQueue queue;
  final ChannelConfig config;
  final LiveScopeConfig liveScopeConfig;
  final TaskService? _taskService;
  final ReviewCommandParser? _reviewCommandParser;
  final ChannelReviewHandler? _reviewHandler;
  final TaskTriggerParser? _triggerParser;
  final EventBus? _eventBus;
  final Map<ChannelType, TaskTriggerConfig> _taskTriggerConfigs;
  final List<Channel> _channels = [];

  ChannelManager({
    required this.queue,
    required this.config,
    LiveScopeConfig? liveScopeConfig,
    TaskService? taskService,
    ReviewCommandParser? reviewCommandParser,
    ChannelReviewHandler? reviewHandler,
    TaskTriggerParser? triggerParser,
    EventBus? eventBus,
    Map<ChannelType, TaskTriggerConfig> taskTriggerConfigs = const {},
  }) : liveScopeConfig = liveScopeConfig ?? LiveScopeConfig(const SessionScopeConfig.defaults()),
       _taskService = taskService,
       _reviewCommandParser = reviewCommandParser,
       _reviewHandler = reviewHandler,
       _triggerParser = triggerParser,
       _eventBus = eventBus,
       _taskTriggerConfigs = Map.unmodifiable(taskTriggerConfigs);

  List<Channel> get channels => List.unmodifiable(_channels);

  void registerChannel(Channel channel) {
    _channels.add(channel);
    _log.info('Registered channel: ${channel.name} (${channel.type})');
  }

  /// Route an inbound message to the appropriate session via the queue.
  ///
  /// Derives a session key from the sender/group JIDs and enqueues.
  /// Drops the message with a warning if no registered channel owns the sender JID.
  void handleInboundMessage(ChannelMessage message) {
    final channel = _findOwningChannel(message);
    if (channel == null) {
      _log.warning('No channel owns JID "${message.senderJid}" — dropping message ${message.id}');
      return;
    }

    final reviewCommandParser = _reviewCommandParser;
    if (reviewCommandParser != null && _reviewHandler != null && _taskService != null) {
      final reviewCommand = reviewCommandParser.parse(message.text);
      if (reviewCommand != null) {
        unawaited(_handleReviewCommand(message, channel, reviewCommand));
        return;
      }
    }

    final triggerConfig = _taskTriggerConfigs[channel.type];
    final triggerParser = _triggerParser;
    if (triggerParser != null && triggerConfig != null && triggerConfig.enabled) {
      final trigger = triggerParser.parse(message.text, triggerConfig, emptyDescriptionError: true);
      if (trigger != null) {
        unawaited(_handleTaskTrigger(message, channel, trigger));
        return;
      }
    }

    final sessionKey = deriveSessionKey(message);
    queue.enqueue(message, channel, sessionKey);
  }

  /// Derive a deterministic session key from a channel message.
  ///
  /// Uses the current live scope config to select the appropriate [SessionKey] factory.
  /// Per-channel overrides are resolved via [SessionScopeConfig.forChannel].
  String deriveSessionKey(ChannelMessage message) {
    final channelType = message.channelType.name;
    final resolved = liveScopeConfig.current.forChannel(channelType);

    if (message.groupJid != null) {
      final groupScope = resolved.groupScope ?? liveScopeConfig.current.groupScope;
      return switch (groupScope) {
        GroupScope.shared => SessionKey.groupShared(channelType: channelType, groupId: message.groupJid!),
        GroupScope.perMember => SessionKey.groupPerMember(
          channelType: channelType,
          groupId: message.groupJid!,
          peerId: message.senderJid,
        ),
      };
    }

    final dmScope = resolved.dmScope ?? liveScopeConfig.current.dmScope;
    return switch (dmScope) {
      DmScope.shared => SessionKey.dmShared(),
      DmScope.perContact => SessionKey.dmPerContact(peerId: message.senderJid),
      DmScope.perChannelContact => SessionKey.dmPerChannelContact(channelType: channelType, peerId: message.senderJid),
    };
  }

  /// Connect all registered channels.
  Future<void> connectAll() async {
    for (final channel in _channels) {
      try {
        await channel.connect();
        _log.info('Connected channel: ${channel.name}');
      } catch (e, st) {
        _log.severe('Failed to connect channel ${channel.name}', e, st);
      }
    }
  }

  /// Disconnect all registered channels.
  Future<void> disconnectAll() async {
    for (final channel in _channels) {
      try {
        await channel.disconnect();
        _log.info('Disconnected channel: ${channel.name}');
      } catch (e, st) {
        _log.warning('Failed to disconnect channel ${channel.name}', e, st);
      }
    }
  }

  /// Disconnect all channels and dispose the queue.
  Future<void> dispose() async {
    await disconnectAll();
    queue.dispose();
  }

  Channel? _findOwningChannel(ChannelMessage message) {
    final candidates = <String>[
      message.senderJid,
      if (message.groupJid != null) message.groupJid!,
      if (message.metadata['spaceName'] case final String spaceName) spaceName,
    ];

    for (final channel in _channels) {
      for (final jid in candidates) {
        if (channel.ownsJid(jid)) return channel;
      }
    }
    return null;
  }

  Future<void> _handleTaskTrigger(ChannelMessage message, Channel channel, TaskTriggerResult trigger) async {
    final recipientId = _resolveRecipientId(message);
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

    final taskService = _taskService;
    if (taskService == null) {
      await _sendBestEffort(
        channel,
        recipientId,
        _taskTriggerResponse('Could not create task -- service unavailable.', sourceMessageId: sourceMessageId),
        failureMessage: 'Failed to send task service unavailable response',
      );
      return;
    }

    final sessionKey = deriveSessionKey(message);
    final origin = TaskOrigin(
      channelType: channel.type.name,
      sessionKey: sessionKey,
      recipientId: recipientId,
      contactId: message.senderJid,
      sourceMessageId: sourceMessageId,
    );

    try {
      final task = await taskService.create(
        id: const Uuid().v4(),
        title: trigger.description,
        description: trigger.description,
        type: trigger.type,
        autoStart: trigger.autoStart,
        configJson: {'origin': origin.toJson()},
      );

      _eventBus?.fire(
        TaskStatusChangedEvent(
          taskId: task.id,
          oldStatus: TaskStatus.draft,
          newStatus: task.status,
          trigger: 'channel',
          timestamp: DateTime.now(),
        ),
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

  Future<void> _handleReviewCommand(ChannelMessage message, Channel channel, ReviewCommand command) async {
    final recipientId = _resolveRecipientId(message);
    final sourceMessageId = _resolveSourceMessageId(message);
    final taskService = _taskService;
    final reviewHandler = _reviewHandler;
    if (taskService == null || reviewHandler == null) {
      _enqueueMessage(message, channel);
      return;
    }

    try {
      final tasksInReview = await taskService.list(status: TaskStatus.review);
      if (tasksInReview.isEmpty && command.taskId == null) {
        _enqueueMessage(message, channel);
        return;
      }

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
          final allMatches = _matchingTasks(await taskService.list(), requestedId);
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

      final result = await reviewHandler(resolvedTask.id, command.action);
      switch (result) {
        case ChannelReviewSuccess(:final taskTitle, :final action):
          final verb = action == 'accept' ? 'accepted' : 'rejected';
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

  String _resolveRecipientId(ChannelMessage message) {
    final metadataRecipient = message.metadata['spaceName'];
    if (metadataRecipient is String && metadataRecipient.isNotEmpty) {
      return metadataRecipient;
    }
    return message.groupJid ?? message.senderJid;
  }

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

  void _enqueueMessage(ChannelMessage message, Channel channel) {
    final sessionKey = deriveSessionKey(message);
    queue.enqueue(message, channel, sessionKey);
  }

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
