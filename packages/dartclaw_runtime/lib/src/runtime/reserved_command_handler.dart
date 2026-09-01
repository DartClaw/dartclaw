import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_core/dartclaw_core.dart' as core show TurnManager;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:logging/logging.dart';

enum _ReservedChannelCommand { stop, pause, resume, bind, unbind }

_ReservedChannelCommand? _reservedChannelCommand(String text) {
  final lower = text.trim().toLowerCase();
  if (_isCommand(lower, '/stop') || lower == 'stop!') return _ReservedChannelCommand.stop;
  if (_isCommand(lower, '/pause')) return _ReservedChannelCommand.pause;
  if (_isCommand(lower, '/resume')) return _ReservedChannelCommand.resume;
  if (lower.startsWith('/bind ')) return _ReservedChannelCommand.bind;
  if (_isCommand(lower, '/unbind')) return _ReservedChannelCommand.unbind;
  return null;
}

/// Reports whether [text] is consumed before per-sender rate limiting and pause queueing.
bool isReservedChannelCommand(String text) => _reservedChannelCommand(text) != null;

/// Whether [lower] is exactly [command] or [command] followed by arguments.
///
/// A bare prefix match would admit `/statusreport …` as a reserved command,
/// which skips per-sender rate limiting and pause queueing.
bool _isCommand(String lower, String command) => lower == command || lower.startsWith('$command ');

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
    required core.TurnManager Function() turnManagerGetter,
    required TaskService taskService,
    required EventBus eventBus,
    required SseBroadcast sseBroadcast,
    required PauseController pauseController,
    required SessionService sessions,
    required ThreadBindingStore? threadBindingStore,
  }) async {
    final command = _reservedChannelCommand(message.text);
    if (command == null) return null;

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

    if (command == _ReservedChannelCommand.stop) {
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

    if (command == _ReservedChannelCommand.bind) {
      return _handleBind(
        message,
        channel,
        taskService: taskService,
        threadBindingStore: threadBindingStore,
        recipientId: recipientId,
      );
    }

    if (command == _ReservedChannelCommand.unbind) {
      return _handleUnbind(message, channel, threadBindingStore: threadBindingStore, recipientId: recipientId);
    }

    if (command == _ReservedChannelCommand.pause) {
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

    final task = await taskService.get(taskId);
    if (task == null) {
      await _sendResponse(channel, recipientId, 'Task $taskId not found.');
      return 'rejected';
    }
    if (task.status.terminal) {
      await _sendResponse(
        channel,
        recipientId,
        'Task ${task.id} is ${task.status.name} — cannot bind to a completed task.',
      );
      return 'rejected';
    }

    final channelType = message.channelType.name;
    final existing = threadBindingStore.lookupByThread(channelType, bindingKey);
    if (existing != null) {
      if (existing.taskId == task.id) {
        await _sendResponse(channel, recipientId, 'Already bound to task ${task.id}.');
        return 'executed';
      }
      await _sendResponse(channel, recipientId, 'Already bound to task ${existing.taskId} — /unbind first.');
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

    await _sendResponse(channel, recipientId, 'Bound to task ${task.id}. Messages here now route to the task session.');
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
      'Unbound from task ${existing.taskId}. Messages here return to normal routing.',
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

  /// Delivers collapsed pause queue messages by creating turns via [TurnManager].
  ///
  /// Each session in [collapsed] gets one turn with the concatenated text.
  /// Errors per session are logged and skipped — partial delivery is acceptable.
  static Future<void> drainPauseQueue({
    required Map<String, String> collapsed,
    required SessionService sessions,
    required core.TurnManager Function() turnManagerGetter,
  }) async {
    final turns = turnManagerGetter();
    for (final MapEntry(key: sessionKey, value: text) in collapsed.entries) {
      try {
        final session = await sessions.getOrCreateByKey(sessionKey, type: SessionType.channel);
        final messages = [
          {'role': 'user', 'content': text},
        ];
        await turns.startTurn(
          session.id,
          messages,
          source: 'pause-queue',
          isHumanInput: true,
          promptScope: PromptScope.primary,
        );
      } catch (e, st) {
        _log.warning('Failed to deliver paused messages for session $sessionKey', e, st);
      }
    }
  }
}
