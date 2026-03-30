import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:logging/logging.dart';

/// Handles reserved channel commands: `/stop`, `/pause`, `/resume`, `/bind`, `/unbind`.
class ReservedCommandHandler {
  static final _log = Logger('ReservedCommandHandler');

  /// Handles reserved commands.
  ///
  /// Returns a non-null string when the command was consumed (handled or
  /// rejected). Returns null when the message is not a recognized reserved command.
  static Future<String?> handle(
    ChannelMessage message,
    Channel channel, {
    required GovernanceConfig governance,
    required TurnManager Function() turnManagerGetter,
    required TaskService taskService,
    required EventBus eventBus,
    required SseBroadcast sseBroadcast,
    required PauseController pauseController,
    required SessionService sessions,
    required ThreadBindingStore? threadBindingStore,
  }) async {
    final lower = message.text.trim().toLowerCase();

    final isStop = lower == '/stop' || lower.startsWith('/stop ') || lower == 'stop!';
    final isPause = lower.startsWith('/pause');
    final isResume = lower.startsWith('/resume');
    final isBind = lower.startsWith('/bind ');
    final isUnbind = lower == '/unbind' || lower.startsWith('/unbind ');

    if (!isStop && !isPause && !isResume && !isBind && !isUnbind) return null;

    final senderId = message.senderJid;
    final senderName = message.senderDisplayName ?? senderId;
    final recipientId = resolveRecipientId(message);

    // Admin check — same for all reserved commands.
    if (!governance.isAdmin(senderId)) {
      try {
        await channel.sendMessage(recipientId, ChannelResponse(text: 'Only admin senders can use this command.'));
      } catch (e) {
        _log.warning('Failed to send reserved command rejection to $senderId', e);
      }
      return 'rejected';
    }

    if (isStop) {
      final stopHandler = EmergencyStopHandler(
        turnManager: turnManagerGetter(),
        taskService: taskService,
        eventBus: eventBus,
        sseBroadcast: sseBroadcast,
      );
      final result = await stopHandler.execute(stoppedBy: senderName);

      final turnCount = result.turnsCancelled;
      final taskCount = result.tasksCancelled;
      final responseText = result.hadActivity
          ? 'All activity stopped by $senderName. '
                '$turnCount turn${turnCount == 1 ? '' : 's'} cancelled, '
                '$taskCount task${taskCount == 1 ? '' : 's'} cancelled.'
          : 'No active tasks or turns to stop.';

      try {
        await channel.sendMessage(recipientId, ChannelResponse(text: responseText));
      } catch (e) {
        _log.warning('Failed to send stop confirmation to $senderId', e);
      }
      return 'executed';
    }

    if (isBind) {
      return _handleBind(
        message,
        channel,
        taskService: taskService,
        threadBindingStore: threadBindingStore,
        recipientId: recipientId,
      );
    }

    if (isUnbind) {
      return _handleUnbind(message, channel, threadBindingStore: threadBindingStore, recipientId: recipientId);
    }

    if (isPause) {
      final wasNewlyPaused = pauseController.pause(senderName);
      final responseText = wasNewlyPaused
          ? 'Agent paused by $senderName. Incoming messages will be queued. Send /resume to continue.'
          : 'Agent is already paused by ${pauseController.pausedBy ?? senderName}.';
      try {
        await channel.sendMessage(recipientId, ChannelResponse(text: responseText));
      } catch (e) {
        _log.warning('Failed to send pause confirmation to $senderId', e);
      }
      return 'executed';
    }

    // isResume
    if (!pauseController.isPaused) {
      try {
        await channel.sendMessage(recipientId, ChannelResponse(text: 'Agent is not paused.'));
      } catch (e) {
        _log.warning('Failed to send resume response to $senderId', e);
      }
      return 'executed';
    }

    final queueDepth = pauseController.queueDepth;
    final collapsed = pauseController.drain();
    if (collapsed != null && collapsed.isNotEmpty) {
      await drainPauseQueue(collapsed: collapsed, sessions: sessions, turnManagerGetter: turnManagerGetter);
    }

    final sessionCount = collapsed?.length ?? 0;
    final responseText = queueDepth == 0
        ? 'Agent resumed by $senderName. No messages were queued.'
        : 'Agent resumed by $senderName. $queueDepth queued message${queueDepth == 1 ? '' : 's'} '
              'from $sessionCount session${sessionCount == 1 ? '' : 's'} delivered.';
    try {
      await channel.sendMessage(recipientId, ChannelResponse(text: responseText));
    } catch (e) {
      _log.warning('Failed to send resume confirmation to $senderId', e);
    }
    return 'executed';
  }

  static Future<String> _handleBind(
    ChannelMessage message,
    Channel channel, {
    required TaskService taskService,
    required ThreadBindingStore? threadBindingStore,
    required String recipientId,
  }) async {
    if (threadBindingStore == null) {
      await _sendResponse(
        channel,
        recipientId,
        'Thread binding is not enabled. Set features.thread_binding.enabled: true.',
      );
      return 'rejected';
    }

    final parts = message.text.trim().split(RegExp(r'\s+'));
    if (parts.length < 2 || parts[1].trim().isEmpty) {
      await _sendResponse(channel, recipientId, 'Usage: /bind <taskId>');
      return 'rejected';
    }
    final taskId = parts[1].trim();

    final bindingKey = _extractBindingKey(message);
    if (bindingKey == null) {
      await _sendResponse(channel, recipientId, 'Cannot bind — this message is not in a thread or group.');
      return 'rejected';
    }

    final matches = (await taskService.list()).where((task) => task.id.startsWith(taskId)).toList(growable: false);
    if (matches.isEmpty) {
      await _sendResponse(channel, recipientId, 'Task $taskId not found.');
      return 'rejected';
    }
    if (matches.length > 1) {
      await _sendResponse(
        channel,
        recipientId,
        'Task prefix $taskId is ambiguous. Matches: ${matches.take(3).map((task) => _shortTaskId(task.id)).join(', ')}.',
      );
      return 'rejected';
    }
    final task = matches.single;
    if (task.status.terminal) {
      await _sendResponse(
        channel,
        recipientId,
        'Task $taskId is ${task.status.name} — cannot bind to a completed task.',
      );
      return 'rejected';
    }

    final channelType = message.channelType.name;
    final existing = threadBindingStore.lookupByThread(channelType, bindingKey);
    if (existing != null) {
      if (existing.taskId == task.id) {
        await _sendResponse(channel, recipientId, 'Already bound to task ${_shortTaskId(task.id)}.');
        return 'executed';
      }
      await _sendResponse(
        channel,
        recipientId,
        'Already bound to task ${_shortTaskId(existing.taskId)} — /unbind first.',
      );
      return 'rejected';
    }

    final now = DateTime.now();
    await threadBindingStore.create(
      ThreadBinding(
        channelType: channelType,
        threadId: bindingKey,
        taskId: task.id,
        sessionKey: task.sessionId ?? SessionKey.taskSession(taskId: task.id),
        createdAt: now,
        lastActivity: now,
      ),
    );

    await _sendResponse(
      channel,
      recipientId,
      'Bound to task ${_shortTaskId(task.id)}. Messages here now route to the task session.',
    );
    return 'executed';
  }

  static Future<String> _handleUnbind(
    ChannelMessage message,
    Channel channel, {
    required ThreadBindingStore? threadBindingStore,
    required String recipientId,
  }) async {
    if (threadBindingStore == null) {
      await _sendResponse(channel, recipientId, 'Thread binding is not enabled.');
      return 'rejected';
    }

    final bindingKey = _extractBindingKey(message);
    if (bindingKey == null) {
      await _sendResponse(channel, recipientId, 'Cannot unbind — this message is not in a thread or group.');
      return 'rejected';
    }

    final existing = threadBindingStore.lookupByThread(message.channelType.name, bindingKey);
    if (existing == null) {
      await _sendResponse(channel, recipientId, 'No binding found for this thread/group.');
      return 'executed';
    }

    await threadBindingStore.delete(message.channelType.name, bindingKey);
    await _sendResponse(
      channel,
      recipientId,
      'Unbound from task ${_shortTaskId(existing.taskId)}. Messages here return to normal routing.',
    );
    return 'executed';
  }

  static String? _extractBindingKey(ChannelMessage message) {
    final threadId = extractThreadId(message);
    if (threadId != null) return threadId;
    final groupJid = message.groupJid;
    if (groupJid != null && groupJid.isNotEmpty) return groupJid;
    return null;
  }

  static Future<void> _sendResponse(Channel channel, String recipientId, String text) async {
    try {
      await channel.sendMessage(recipientId, ChannelResponse(text: text));
    } catch (e) {
      _log.warning('Failed to send reserved command response to $recipientId', e);
    }
  }

  static String _shortTaskId(String taskId) {
    if (taskId.length <= 8) return taskId;
    return taskId.substring(0, 8);
  }

  /// Delivers collapsed pause queue messages by creating turns via [TurnManager].
  ///
  /// Each session in [collapsed] gets one turn with the concatenated text.
  /// Errors per session are logged and skipped — partial delivery is acceptable.
  static Future<void> drainPauseQueue({
    required Map<String, String> collapsed,
    required SessionService sessions,
    required TurnManager Function() turnManagerGetter,
  }) async {
    final turns = turnManagerGetter();
    for (final MapEntry(key: sessionKey, value: text) in collapsed.entries) {
      try {
        final session = await sessions.getOrCreateByKey(sessionKey, type: SessionType.channel);
        final messages = [
          {'role': 'user', 'content': text},
        ];
        await turns.startTurn(session.id, messages, source: 'pause-queue', isHumanInput: true);
      } catch (e, st) {
        _log.warning('Failed to deliver paused messages for session $sessionKey', e, st);
      }
    }
  }
}
