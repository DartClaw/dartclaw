import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import 'package:dartclaw_models/dartclaw_models.dart' show ChannelType;

import '../scoping/group_config_resolver.dart';
import '../task/task.dart';
import '../task/task_status.dart';
import 'channel.dart';
import 'recipient_resolver.dart';
import 'task_creator.dart';
import 'task_origin.dart';
import 'task_trigger_config.dart';
import 'task_trigger_parser.dart';

/// Extracted task-trigger workflow for [ChannelTaskBridge].
class TaskTriggerEvaluator {
  static final _log = Logger('TaskTriggerEvaluator');

  final TaskCreator? _taskCreator;
  final TaskTriggerParser? _triggerParser;
  final Map<ChannelType, TaskTriggerConfig> _taskTriggerConfigs;
  final GroupConfigResolver? Function()? _groupConfigResolverGetter;
  final Future<void> Function(
    Channel channel,
    String recipientId,
    ChannelResponse response, {
    required String failureMessage,
  })
  _sendBestEffort;

  TaskTriggerEvaluator({
    TaskCreator? taskCreator,
    TaskTriggerParser? triggerParser,
    Map<ChannelType, TaskTriggerConfig> taskTriggerConfigs = const {},
    GroupConfigResolver? Function()? groupConfigResolverGetter,
    required Future<void> Function(
      Channel channel,
      String recipientId,
      ChannelResponse response, {
      required String failureMessage,
    })
    sendBestEffort,
  }) : _taskCreator = taskCreator,
       _triggerParser = triggerParser,
       _taskTriggerConfigs = Map.unmodifiable(taskTriggerConfigs),
       _groupConfigResolverGetter = groupConfigResolverGetter,
       _sendBestEffort = sendBestEffort;

  /// Returns task ids whose normalized form matches [requestedId].
  List<Task> matchingTasks(Iterable<Task> tasks, String requestedId) {
    final normalizedRequestedId = _normalizedTaskId(requestedId);
    if (normalizedRequestedId.isEmpty) {
      return const [];
    }
    return tasks.where((task) => _normalizedTaskId(task.id).startsWith(normalizedRequestedId)).toList();
  }

  /// Formats a list of tasks for channel responses.
  String formatTaskListing(Iterable<Task> tasks, {bool includeStatus = false}) {
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

  /// Builds a response that preserves the source inbound message id, if any.
  ChannelResponse taskTriggerResponse(String text, {String? sourceMessageId}) {
    if (sourceMessageId == null) {
      return ChannelResponse(text: text);
    }
    return ChannelResponse(text: text, metadata: {sourceMessageIdMetadataKey: sourceMessageId});
  }

  /// Attempts to handle [message] as a task-creation trigger.
  Future<bool> tryHandleTaskTrigger(
    ChannelMessage message,
    Channel channel, {
    required String sessionKey,
    String? sourceMessageId,
  }) async {
    final triggerConfig = _taskTriggerConfigs[channel.type];
    final triggerParser = _triggerParser;
    if (triggerParser == null || triggerConfig == null || !triggerConfig.enabled) {
      return false;
    }

    final trigger = triggerParser.parse(message.text, triggerConfig, emptyDescriptionError: true);
    if (trigger == null) {
      return false;
    }

    await _handleTaskTrigger(message, channel, trigger, sessionKey: sessionKey, sourceMessageId: sourceMessageId);
    return true;
  }

  Future<void> _handleTaskTrigger(
    ChannelMessage message,
    Channel channel,
    TaskTriggerResult trigger, {
    required String sessionKey,
    String? sourceMessageId,
  }) async {
    final recipientId = resolveRecipientId(message);

    if (trigger.description.isEmpty) {
      await _sendBestEffort(
        channel,
        recipientId,
        taskTriggerResponse('Could not create task -- description required.', sourceMessageId: sourceMessageId),
        failureMessage: 'Failed to send empty-description task trigger response',
      );
      return;
    }

    final taskCreator = _taskCreator;
    if (taskCreator == null) {
      await _sendBestEffort(
        channel,
        recipientId,
        taskTriggerResponse('Could not create task -- service unavailable.', sourceMessageId: sourceMessageId),
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
    final providerHint = switch (message.metadata['provider']) {
      final String provider when provider.trim().isNotEmpty => provider.trim(),
      _ => null,
    };

    String? resolvedProjectId;
    final groupJid = message.groupJid;
    final resolver = _groupConfigResolverGetter?.call();
    if (groupJid != null && resolver != null) {
      final entry = resolver.resolve(channel.type, groupJid);
      resolvedProjectId = entry?.project;
    }

    try {
      final configJson = <String, dynamic>{'origin': origin.toJson()};
      if (providerHint != null) {
        configJson['provider'] = providerHint;
      }

      final task = await taskCreator(
        id: const Uuid().v4(),
        title: trigger.description,
        description: trigger.description,
        type: trigger.type,
        autoStart: trigger.autoStart,
        createdBy: senderDisplayName,
        projectId: resolvedProjectId,
        configJson: configJson,
        trigger: 'channel',
      );

      final statusWord = task.status == TaskStatus.draft ? 'drafted' : 'created';
      final queuedNote = task.status == TaskStatus.queued ? ' -- Queued (will start when a slot opens)' : '';
      await _sendBestEffort(
        channel,
        recipientId,
        taskTriggerResponse(
          'Task $statusWord: ${task.title} [${task.type.name}] -- ID: ${_shortTaskId(task.id)}$queuedNote',
          sourceMessageId: sourceMessageId,
        ),
        failureMessage: 'Failed to send task creation acknowledgement for ${task.id}',
      );
    } catch (error, stackTrace) {
      _log.severe('Failed to create task from inbound channel message ${message.id}', error, stackTrace);
      await _sendBestEffort(
        channel,
        recipientId,
        taskTriggerResponse('Could not create task -- service unavailable.', sourceMessageId: sourceMessageId),
        failureMessage: 'Failed to send task creation failure response',
      );
    }
  }

  String _shortTaskId(String taskId) {
    final normalizedTaskId = _normalizedTaskId(taskId);
    if (normalizedTaskId.length <= 6) {
      return normalizedTaskId;
    }
    return normalizedTaskId.substring(0, 6);
  }

  String _normalizedTaskId(String taskId) => taskId.replaceAll('-', '').toLowerCase();

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
}
