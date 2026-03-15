import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

/// Handles parsed Google Chat slash commands.
class SlashCommandHandler {
  static final _log = Logger('SlashCommandHandler');
  static final _uuid = Uuid();

  final TaskService? _taskService;
  final SessionService? _sessionService;
  final EventBus? _eventBus;
  final ChannelManager? _channelManager;
  final ChatCardBuilder _cardBuilder;
  final TaskTriggerParser _taskTriggerParser;
  final TaskTriggerConfig _taskTriggerConfig;
  final HtmlEscape _htmlEscape;

  SlashCommandHandler({
    TaskService? taskService,
    SessionService? sessionService,
    EventBus? eventBus,
    ChannelManager? channelManager,
    ChatCardBuilder? cardBuilder,
    TaskTriggerParser? taskTriggerParser,
    String defaultTaskType = TaskTriggerConfig.defaultDefaultType,
    bool autoStartTasks = true,
  }) : _taskService = taskService,
       _sessionService = sessionService,
       _eventBus = eventBus,
       _channelManager = channelManager,
       _cardBuilder = cardBuilder ?? const ChatCardBuilder(),
       _taskTriggerParser = taskTriggerParser ?? const TaskTriggerParser(),
       _taskTriggerConfig = TaskTriggerConfig(
         enabled: true,
         defaultType: _normalizedDefaultTaskType(defaultTaskType),
         autoStart: autoStartTasks,
       ),
       _htmlEscape = const HtmlEscape(HtmlEscapeMode.element);

  /// Executes [command] and returns a Cards v2 webhook response payload.
  Future<Map<String, dynamic>> handle(
    SlashCommand command, {
    required String spaceName,
    required String senderJid,
    String? spaceType,
    String? sourceMessageId,
  }) async {
    switch (command.name) {
      case 'new':
        return _handleNew(
          command.arguments,
          spaceName: spaceName,
          senderJid: senderJid,
          spaceType: spaceType,
          sourceMessageId: sourceMessageId,
        );
      case 'reset':
        return _handleReset(spaceName: spaceName, senderJid: senderJid, spaceType: spaceType);
      case 'status':
        return _handleStatus();
      default:
        return _unknownCommand();
    }
  }

  Future<Map<String, dynamic>> _handleNew(
    String arguments, {
    required String spaceName,
    required String senderJid,
    String? spaceType,
    String? sourceMessageId,
  }) async {
    final taskService = _taskService;
    if (taskService == null) {
      return _cardBuilder.errorNotification(
        title: 'Service Unavailable',
        errorSummary: 'Could not create task -- task service is not available.',
      );
    }

    final trigger = _taskTriggerParser.parse(
      '${TaskTriggerConfig.defaultPrefix} $arguments',
      _taskTriggerConfig,
      emptyDescriptionError: true,
    );
    if (trigger == null || trigger.description.isEmpty) {
      return _cardBuilder.errorNotification(
        title: 'Missing Description',
        errorSummary: 'Usage: /new [<type>:] <description>',
      );
    }

    final origin = TaskOrigin(
      channelType: ChannelType.googlechat.name,
      sessionKey: _deriveSessionKey(spaceName: spaceName, senderJid: senderJid, spaceType: spaceType),
      recipientId: spaceName,
      contactId: senderJid,
      sourceMessageId: sourceMessageId,
    );

    try {
      final task = await taskService.create(
        id: _uuid.v4(),
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
          trigger: 'slash_command',
          timestamp: DateTime.now(),
        ),
      );

      final statusWord = task.status == TaskStatus.draft ? 'drafted' : 'created';
      return _cardBuilder.taskNotification(
        taskId: task.id,
        title: 'Task $statusWord: ${task.title}',
        status: task.status.name,
        description: task.description,
        createdAt: task.createdAt,
      );
    } catch (error, stackTrace) {
      _log.warning('Failed to create task from /new command', error, stackTrace);
      return _cardBuilder.errorNotification(
        title: 'Task Creation Failed',
        errorSummary: 'Could not create task -- service unavailable.',
      );
    }
  }

  Future<Map<String, dynamic>> _handleReset({
    required String spaceName,
    required String senderJid,
    String? spaceType,
  }) async {
    final sessionService = _sessionService;
    if (sessionService == null) {
      return _cardBuilder.errorNotification(
        title: 'Service Unavailable',
        errorSummary: 'Could not reset session -- session service is not available.',
      );
    }

    final sessionKey = _deriveSessionKey(spaceName: spaceName, senderJid: senderJid, spaceType: spaceType);

    try {
      final session = await _findActiveSessionByKey(sessionKey);
      if (session == null) {
        return _cardBuilder.confirmationCard(title: 'Session Reset', message: 'No active session to reset.');
      }

      await sessionService.updateSessionType(session.id, SessionType.archive);
      return _cardBuilder.confirmationCard(
        title: 'Session Reset',
        message: 'Session archived. Your next message will start a fresh session.',
      );
    } catch (error, stackTrace) {
      _log.warning('Failed to archive Google Chat session for key $sessionKey', error, stackTrace);
      return _cardBuilder.errorNotification(
        title: 'Session Reset Failed',
        errorSummary: 'Could not reset session -- service unavailable.',
      );
    }
  }

  Future<Map<String, dynamic>> _handleStatus() async {
    final sections = <Map<String, dynamic>>[];

    final taskService = _taskService;
    if (taskService != null) {
      final tasks = await taskService.list();
      final activeTasks = tasks.where((task) => !task.status.terminal).toList();
      if (activeTasks.isEmpty) {
        sections.add({
          'header': 'Active Tasks (0)',
          'widgets': [
            {
              'textParagraph': {'text': 'No active tasks.'},
            },
          ],
        });
      } else {
        final taskWidgets = <Map<String, dynamic>>[];
        for (final task in activeTasks.take(10)) {
          taskWidgets.add({
            'decoratedText': {
              'topLabel': _statusLabel(task.status),
              'text': _htmlEscape.convert(task.title),
              'wrapText': true,
            },
          });
        }
        if (activeTasks.length > 10) {
          taskWidgets.add({
            'textParagraph': {'text': '... and ${activeTasks.length - 10} more'},
          });
        }
        sections.add({'header': 'Active Tasks (${activeTasks.length})', 'widgets': taskWidgets});
      }
    }

    final sessionService = _sessionService;
    if (sessionService != null) {
      final sessions = await sessionService.listSessions();
      final activeCount = sessions.where((session) => session.type != SessionType.archive).length;
      sections.add({
        'header': 'Sessions',
        'widgets': [
          {
            'decoratedText': {
              'topLabel': 'Active',
              'text': '$activeCount active session${activeCount == 1 ? '' : 's'}',
            },
          },
        ],
      });
    }

    if (sections.isEmpty) {
      return _cardBuilder.confirmationCard(title: 'Status', message: 'No services available.');
    }

    return {
      'cardsV2': [
        {
          'cardId': 'status',
          'card': {
            'header': {'title': 'DartClaw Status', 'subtitle': 'Current overview'},
            'sections': sections,
          },
        },
      ],
    };
  }

  Map<String, dynamic> _unknownCommand() {
    return _cardBuilder.errorNotification(
      title: 'Unknown Command',
      errorSummary: 'Unknown command. Available: /new, /reset, /status',
    );
  }

  String _deriveSessionKey({required String spaceName, required String senderJid, String? spaceType}) {
    final channelManager = _channelManager;
    if (channelManager != null) {
      return channelManager.deriveSessionKey(
        ChannelMessage(
          channelType: ChannelType.googlechat,
          senderJid: senderJid,
          groupJid: spaceType == 'DM' ? null : spaceName,
          text: '',
          metadata: {'spaceName': spaceName},
        ),
      );
    }

    if (spaceType == 'DM') {
      return SessionKey.dmPerChannelContact(channelType: ChannelType.googlechat.name, peerId: senderJid);
    }
    return SessionKey.groupShared(channelType: ChannelType.googlechat.name, groupId: spaceName);
  }

  Future<Session?> _findActiveSessionByKey(String sessionKey) async {
    final sessionService = _sessionService;
    if (sessionService == null) {
      return null;
    }

    final sessions = await sessionService.listSessions();
    for (final session in sessions) {
      if (session.channelKey == sessionKey && session.type != SessionType.archive) {
        return session;
      }
    }
    return null;
  }

  String _statusLabel(TaskStatus status) => switch (status) {
    TaskStatus.draft => 'Draft',
    TaskStatus.queued => 'Queued',
    TaskStatus.running => 'Running',
    TaskStatus.interrupted => 'Interrupted',
    TaskStatus.review => 'Needs Review',
    TaskStatus.accepted => 'Accepted',
    TaskStatus.rejected => 'Rejected',
    TaskStatus.cancelled => 'Cancelled',
    TaskStatus.failed => 'Failed',
  };

  static String _normalizedDefaultTaskType(String defaultTaskType) {
    final normalized = TaskTriggerConfig.normalizeDefaultType(defaultTaskType);
    return normalized.isEmpty ? TaskTriggerConfig.defaultDefaultType : normalized;
  }
}
