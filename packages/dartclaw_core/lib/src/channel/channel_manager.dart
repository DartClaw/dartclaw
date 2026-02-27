import 'package:logging/logging.dart';

import 'channel.dart';
import 'channel_config.dart';
import 'message_queue.dart';

/// Manages channel registration, lifecycle, and inbound message routing.
class ChannelManager {
  static final _log = Logger('ChannelManager');

  final MessageQueue queue;
  final ChannelConfig config;
  final List<Channel> _channels = [];

  ChannelManager({required this.queue, required this.config});

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
  /// DM: `agent:main:per-peer:<encodedSenderJid>`
  /// Group: `agent:main:per-channel-peer:<channelType>:<encodedGroupJid>:<encodedSenderJid>`
  static String deriveSessionKey(ChannelMessage message) {
    final sender = Uri.encodeComponent(message.senderJid);
    if (message.groupJid != null) {
      final group = Uri.encodeComponent(message.groupJid!);
      return 'agent:main:per-channel-peer:${message.channelType.name}:$group:$sender';
    }
    return 'agent:main:per-peer:$sender';
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
