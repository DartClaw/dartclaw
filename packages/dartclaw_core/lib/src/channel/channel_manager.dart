import 'dart:async';

import 'package:dartclaw_models/dartclaw_models.dart'
    show ChannelConfig, DmScope, GroupScope, SessionKey, SessionScopeConfig;
import 'package:logging/logging.dart';

import '../scoping/live_scope_config.dart';
import 'channel.dart';
import 'channel_task_bridge.dart';
import 'message_queue.dart';
import 'recipient_resolver.dart';

/// Manages channel registration, lifecycle, and inbound message routing.
///
/// All task-related message processing (task triggers, review commands,
/// recipient resolution) is delegated to [ChannelTaskBridge]. When no bridge
/// is wired, all messages fall through directly to the session queue.
class ChannelManager {
  static final _log = Logger('ChannelManager');

  final MessageQueue queue;
  final ChannelConfig config;
  final LiveScopeConfig liveScopeConfig;
  final ChannelTaskBridge? _taskBridge;
  final List<Channel> _channels = [];

  // Pause state callbacks — injected from PauseController in dartclaw_server.
  // Using callbacks keeps dartclaw_core free of server dependencies.
  final bool Function()? _isPaused;
  final bool Function(ChannelMessage, Channel, String)? _enqueueForPause;
  final String Function()? _pausedByName;

  ChannelManager({
    required this.queue,
    required this.config,
    LiveScopeConfig? liveScopeConfig,
    ChannelTaskBridge? taskBridge,

    /// Returns `true` if the agent is currently paused.
    bool Function()? isPaused,

    /// Enqueues a message during pause. Returns `true` if queued, `false` if queue full.
    bool Function(ChannelMessage, Channel, String)? enqueueForPause,

    /// Returns the name of the admin who initiated the pause (for acknowledgment).
    String Function()? pausedByName,
    // Deprecated task-related parameters kept for API compatibility.
    // They are silently ignored — wire a ChannelTaskBridge instead.
    @Deprecated('Wire a ChannelTaskBridge via taskBridge instead') dynamic taskCreator,
    @Deprecated('Wire a ChannelTaskBridge via taskBridge instead') dynamic taskLister,
    @Deprecated('Wire a ChannelTaskBridge via taskBridge instead') dynamic reviewCommandParser,
    @Deprecated('Wire a ChannelTaskBridge via taskBridge instead') dynamic reviewHandler,
    @Deprecated('Wire a ChannelTaskBridge via taskBridge instead') dynamic triggerParser,
    @Deprecated('Wire a ChannelTaskBridge via taskBridge instead') dynamic eventBus,
    @Deprecated('Wire a ChannelTaskBridge via taskBridge instead') dynamic taskTriggerConfigs,
  }) : liveScopeConfig = liveScopeConfig ?? LiveScopeConfig(const SessionScopeConfig.defaults()),
       _taskBridge = taskBridge,
       _isPaused = isPaused,
       _enqueueForPause = enqueueForPause,
       _pausedByName = pausedByName;

  List<Channel> get channels => List.unmodifiable(_channels);

  void registerChannel(Channel channel) {
    _channels.add(channel);
    _log.info('Registered channel: ${channel.name} (${channel.type})');
  }

  /// Route an inbound message to the appropriate session via the queue.
  ///
  /// If a [ChannelTaskBridge] is wired, it is consulted first. When the bridge
  /// handles the message (returns `true`), routing stops. Otherwise, the message
  /// is enqueued for normal session processing.
  ///
  /// Drops the message with a warning if no registered channel owns the sender JID.
  void handleInboundMessage(ChannelMessage message) {
    final channel = _findOwningChannel(message);
    if (channel == null) {
      _log.warning('No channel owns JID "${message.senderJid}" — dropping message ${message.id}');
      return;
    }

    final taskBridge = _taskBridge;
    if (taskBridge != null) {
      final sessionKey = deriveSessionKey(message);
      final boundThreadBinding = taskBridge.lookupThreadBinding(message);
      final routedSessionKey = boundThreadBinding?.sessionKey ?? sessionKey;

      // Reserved commands must still run while paused; all other inbound
      // traffic is queued with its resolved route context preserved.
      if (!taskBridge.isReservedCommand(message.text) && _enqueueDuringPause(message, channel, routedSessionKey)) {
        return;
      }

      unawaited(
        taskBridge
            .tryHandle(
              message,
              channel,
              sessionKey: sessionKey,
              enqueue: queue.enqueue,
              boundThreadBinding: boundThreadBinding,
              boundTaskId: boundThreadBinding?.taskId,
            )
            .then((handled) {
              if (handled) return;
              queue.enqueue(message, channel, routedSessionKey);
            }),
      );
      return;
    }

    final sessionKey = deriveSessionKey(message);
    if (_enqueueDuringPause(message, channel, sessionKey)) return;
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

  /// Intercept a message during pause. Returns `true` if the message was consumed.
  ///
  /// When pause callbacks are not wired (`_isPaused == null`), always returns `false`
  /// for backward compatibility.
  bool _enqueueDuringPause(ChannelMessage message, Channel channel, String sessionKey) {
    final isPaused = _isPaused;
    if (isPaused == null || !isPaused()) return false;

    final enqueueForPause = _enqueueForPause;
    final adminName = _pausedByName?.call() ?? 'admin';
    final queued = enqueueForPause?.call(message, channel, sessionKey) ?? false;
    _sendPauseAcknowledgment(message, channel, queued: queued, adminName: adminName);
    return true;
  }

  void _sendPauseAcknowledgment(
    ChannelMessage message,
    Channel channel, {
    required bool queued,
    required String adminName,
  }) {
    final recipientId = resolveRecipientId(message);
    final text = queued
        ? 'Agent is paused by $adminName. Your message has been queued and will be delivered on resume.'
        : 'Agent is paused. Queue is full — message could not be queued.';
    channel.sendMessage(recipientId, ChannelResponse(text: text)).catchError((Object e) {
      _log.warning('Failed to send pause acknowledgment to ${message.senderJid}', e);
    });
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
}
