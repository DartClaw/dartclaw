import 'dart:convert';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import '../emergency/emergency_stop_handler.dart';
import '../governance/budget_enforcer.dart';
import '../governance/pause_controller.dart';
import '../task/task_service.dart';

/// Handles parsed Google Chat slash commands.
class SlashCommandHandler {
  static final _log = Logger('SlashCommandHandler');
  static final _uuid = Uuid();

  final TaskService? _taskService;
  final SessionService? _sessionService;
  final ChannelManager? _channelManager;
  final BudgetEnforcer? _budgetEnforcer;
  final PauseController? _pauseController;
  final Future<EmergencyStopResult> Function(String stoppedBy)? _onEmergencyStop;
  final bool Function(String senderId)? _isAdmin;
  final Future<void> Function(Map<String, String>)? _onDrain;
  final ChatCardBuilder _cardBuilder;
  final TaskTriggerParser _taskTriggerParser;
  final TaskTriggerConfig _taskTriggerConfig;
  final HtmlEscape _htmlEscape;

  SlashCommandHandler({
    TaskService? taskService,
    SessionService? sessionService,
    // eventBus is accepted for API compatibility but events are now fired by TaskService.
    @Deprecated('Events are now centralized in TaskService. Pass eventBus to TaskService instead.') EventBus? eventBus,
    ChannelManager? channelManager,
    BudgetEnforcer? budgetEnforcer,
    PauseController? pauseController,
    Future<EmergencyStopResult> Function(String stoppedBy)? onEmergencyStop,
    bool Function(String senderId)? isAdmin,

    /// Called with `sessionKey → collapsedText` map when /resume drains the queue.
    Future<void> Function(Map<String, String>)? onDrain,
    ChatCardBuilder? cardBuilder,
    TaskTriggerParser? taskTriggerParser,
    String defaultTaskType = TaskTriggerConfig.defaultDefaultType,
    bool autoStartTasks = true,
  }) : _taskService = taskService,
       _sessionService = sessionService,
       _channelManager = channelManager,
       _budgetEnforcer = budgetEnforcer,
       _pauseController = pauseController,
       _onEmergencyStop = onEmergencyStop,
       _isAdmin = isAdmin,
       _onDrain = onDrain,
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
    String? senderDisplayName,
    String? spaceType,
    String? sourceMessageId,
  }) async {
    switch (command.name) {
      case 'new':
        return _handleNew(
          command.arguments,
          spaceName: spaceName,
          senderJid: senderJid,
          senderDisplayName: senderDisplayName,
          spaceType: spaceType,
          sourceMessageId: sourceMessageId,
        );
      case 'reset':
        return _handleReset(spaceName: spaceName, senderJid: senderJid, spaceType: spaceType);
      case 'status':
        return _handleStatus();
      case 'pause':
        return _handlePause(senderJid: senderJid, senderDisplayName: senderDisplayName);
      case 'resume':
        return _handleResume(senderJid: senderJid);
      case 'stop':
        return _handleStop(senderJid: senderJid, senderDisplayName: senderDisplayName);
      default:
        return _unknownCommand();
    }
  }

  Future<Map<String, dynamic>> _handleNew(
    String arguments, {
    required String spaceName,
    required String senderJid,
    String? senderDisplayName,
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
      senderDisplayName: senderDisplayName,
      senderId: senderJid,
    );

    try {
      final task = await taskService.create(
        id: _uuid.v4(),
        title: trigger.description,
        description: trigger.description,
        type: trigger.type,
        autoStart: trigger.autoStart,
        createdBy: senderDisplayName,
        configJson: {'origin': origin.toJson()},
        trigger: 'slash_command',
      );

      final statusWord = task.status == TaskStatus.draft ? 'drafted' : 'created';
      final queuedNote = task.status == TaskStatus.queued ? ' -- Queued (will start when a slot opens)' : '';
      return _cardBuilder.taskNotification(
        taskId: task.id,
        title: 'Task $statusWord: ${task.title}$queuedNote',
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

    // Pause state — insert first when paused (highest visibility).
    final pauseController = _pauseController;
    if (pauseController != null && pauseController.isPaused) {
      sections.add({
        'header': 'Agent Status',
        'widgets': [
          {
            'decoratedText': {
              'topLabel': 'PAUSED',
              'text': '<font color="#FFA500"><b>Paused by ${pauseController.pausedBy ?? 'admin'}</b></font>',
              'wrapText': true,
            },
          },
          {
            'decoratedText': {
              'topLabel': 'Queue',
              'text': '${pauseController.queueDepth} message${pauseController.queueDepth == 1 ? '' : 's'} queued',
            },
          },
        ],
      });
    }

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

    final budgetEnforcer = _budgetEnforcer;
    if (budgetEnforcer != null) {
      final budgetStatus = await budgetEnforcer.status();
      if (budgetStatus.enabled) {
        final String pctText;
        if (budgetStatus.percentage >= 100) {
          pctText = '<font color="#FF0000"><b>EXHAUSTED (${budgetStatus.percentage}%)</b></font>';
        } else if (budgetStatus.percentage >= 80) {
          pctText = '<font color="#FFA500"><b>${budgetStatus.percentage}% used</b></font>';
        } else {
          pctText = '${budgetStatus.percentage}% used';
        }
        final actionText = budgetStatus.action == BudgetAction.block ? 'Block new turns' : 'Warn only';
        sections.add({
          'header': 'Token Budget',
          'widgets': [
            {
              'decoratedText': {
                'topLabel': 'Daily Usage',
                'text': '$pctText — ${budgetStatus.tokensUsed}/${budgetStatus.budget} tokens',
                'wrapText': true,
              },
            },
            {
              'decoratedText': {'topLabel': 'Action at Limit', 'text': actionText},
            },
          ],
        });
      }
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

  Future<Map<String, dynamic>> _handlePause({required String senderJid, String? senderDisplayName}) async {
    final pauseController = _pauseController;
    if (pauseController == null) {
      return _cardBuilder.errorNotification(
        title: 'Service Unavailable',
        errorSummary: 'Pause/resume is not configured.',
      );
    }

    if (!(_isAdmin?.call(senderJid) ?? true)) {
      return _cardBuilder.errorNotification(
        title: 'Permission Denied',
        errorSummary: 'Only admin senders can pause the agent.',
      );
    }

    final adminName = senderDisplayName ?? senderJid;
    final wasNewlyPaused = pauseController.pause(adminName);
    if (!wasNewlyPaused) {
      return _cardBuilder.confirmationCard(
        title: 'Already Paused',
        message: 'Agent is already paused by ${pauseController.pausedBy ?? adminName}.',
      );
    }

    return _cardBuilder.confirmationCard(
      title: 'Agent Paused',
      message: 'Agent paused by $adminName. Incoming messages will be queued. Use /resume to continue.',
    );
  }

  Future<Map<String, dynamic>> _handleResume({required String senderJid}) async {
    final pauseController = _pauseController;
    if (pauseController == null) {
      return _cardBuilder.errorNotification(
        title: 'Service Unavailable',
        errorSummary: 'Pause/resume is not configured.',
      );
    }

    if (!(_isAdmin?.call(senderJid) ?? true)) {
      return _cardBuilder.errorNotification(
        title: 'Permission Denied',
        errorSummary: 'Only admin senders can resume the agent.',
      );
    }

    if (!pauseController.isPaused) {
      return _cardBuilder.confirmationCard(title: 'Not Paused', message: 'Agent is not paused.');
    }

    final queueDepth = pauseController.queueDepth;
    final collapsed = pauseController.drain();
    if (collapsed != null && collapsed.isNotEmpty) {
      try {
        await _onDrain?.call(collapsed);
      } catch (e, st) {
        _log.warning('Failed to drain pause queue on /resume', e, st);
      }
    }

    final sessionCount = collapsed?.length ?? 0;
    final message = queueDepth == 0
        ? 'Agent resumed. No messages were queued while paused.'
        : 'Agent resumed. $queueDepth queued message${queueDepth == 1 ? '' : 's'} '
              'from $sessionCount session${sessionCount == 1 ? '' : 's'} delivered.';

    return _cardBuilder.confirmationCard(title: 'Agent Resumed', message: message);
  }

  Future<Map<String, dynamic>> _handleStop({required String senderJid, String? senderDisplayName}) async {
    final onEmergencyStop = _onEmergencyStop;
    if (onEmergencyStop == null) {
      return _cardBuilder.errorNotification(
        title: 'Service Unavailable',
        errorSummary: 'Emergency stop is not configured.',
      );
    }

    if (!(_isAdmin?.call(senderJid) ?? true)) {
      return _cardBuilder.errorNotification(
        title: 'Permission Denied',
        errorSummary: 'Only admin senders can stop the agent.',
      );
    }

    final trimmedName = senderDisplayName?.trim();
    final stoppedBy = (trimmedName != null && trimmedName.isNotEmpty) ? trimmedName : senderJid;
    final result = await onEmergencyStop(stoppedBy);
    final message = result.hadActivity
        ? 'All activity stopped by $stoppedBy. '
              '${result.turnsCancelled} turn${result.turnsCancelled == 1 ? '' : 's'} cancelled, '
              '${result.tasksCancelled} task${result.tasksCancelled == 1 ? '' : 's'} cancelled.'
        : 'No active tasks or turns to stop.';

    return _cardBuilder.confirmationCard(title: 'Emergency Stop', message: message);
  }

  Map<String, dynamic> _unknownCommand() {
    return _cardBuilder.errorNotification(
      title: 'Unknown Command',
      errorSummary: 'Unknown command. Available: /new, /reset, /status, /stop, /pause, /resume',
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
