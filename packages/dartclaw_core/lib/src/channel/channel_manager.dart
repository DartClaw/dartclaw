import 'package:logging/logging.dart';

import 'package:dartclaw_models/dartclaw_models.dart';
import 'channel.dart';
import 'channel_config.dart';
import 'message_queue.dart';
import '../config/live_scope_config.dart';
import '../config/session_scope_config.dart';

/// Manages channel registration, lifecycle, and inbound message routing.
class ChannelManager {
  static final _log = Logger('ChannelManager');

  final MessageQueue queue;
  final ChannelConfig config;
  final LiveScopeConfig liveScopeConfig;
  final List<Channel> _channels = [];

  ChannelManager({required this.queue, required this.config, LiveScopeConfig? liveScopeConfig})
    : liveScopeConfig = liveScopeConfig ?? LiveScopeConfig(const SessionScopeConfig.defaults());

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
    final channel = _findOwningChannel(message.senderJid);
    if (channel == null) {
      _log.warning('No channel owns JID "${message.senderJid}" — dropping message ${message.id}');
      return;
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
      // resolved.groupScope is guaranteed non-null by forChannel()'s ?? fallback
      return switch (resolved.groupScope!) {
        GroupScope.shared => SessionKey.groupShared(channelType: channelType, groupId: message.groupJid!),
        GroupScope.perMember => SessionKey.groupPerMember(
          channelType: channelType,
          groupId: message.groupJid!,
          peerId: message.senderJid,
        ),
      };
    }

    // resolved.dmScope is guaranteed non-null by forChannel()'s ?? fallback
    return switch (resolved.dmScope!) {
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

  Channel? _findOwningChannel(String jid) {
    for (final channel in _channels) {
      if (channel.ownsJid(jid)) return channel;
    }
    return null;
  }
}
