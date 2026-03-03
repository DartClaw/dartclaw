import 'dart:async';

import 'package:logging/logging.dart';

import '../channel.dart';
import '../channel_manager.dart';
import '../whatsapp/text_chunking.dart';
import 'signal_cli_manager.dart';
import 'signal_config.dart';
import 'signal_dm_access.dart';

/// Signal channel implementation via signal-cli subprocess.
class SignalChannel extends Channel {
  static final _log = Logger('SignalChannel');

  @override
  final String name = 'signal';
  @override
  final ChannelType type = ChannelType.signal;

  final SignalCliManager sidecar;
  final SignalConfig config;
  final SignalDmAccessController dmAccess;
  final SignalMentionGating mentionGating;
  final ChannelManager? _channelManager;
  StreamSubscription<Map<String, dynamic>>? _eventSub;

  SignalChannel({
    required this.sidecar,
    required this.config,
    required this.dmAccess,
    required this.mentionGating,
    ChannelManager? channelManager,
  }) : _channelManager = channelManager;

  @override
  Future<void> connect() async {
    await sidecar.start();
    // Subscribe to SSE events from signal-cli daemon
    _eventSub = sidecar.events.listen(_handleEvent);
  }

  @override
  Future<void> sendMessage(String recipientId, ChannelResponse response) async {
    if (!sidecar.isRunning) return;

    if (response.text.isNotEmpty) {
      try {
        await sidecar.sendMessage(recipientId, response.text);
      } catch (e) {
        _log.warning('Failed to send text to $recipientId', e);
        rethrow;
      }
    }
  }

  @override
  bool ownsJid(String jid) {
    // Signal identifiers are phone numbers (E.164 format, starting with +)
    return jid.startsWith('+') && !jid.contains('@');
  }

  @override
  List<ChannelResponse> formatResponse(String text) {
    final chunks = chunkText(text, maxSize: config.maxChunkSize);
    return [for (final chunk in chunks) ChannelResponse(text: chunk)];
  }

  @override
  Future<void> disconnect() async {
    await _eventSub?.cancel();
    _eventSub = null;
    await sidecar.stop();
  }

  /// Handle an inbound SSE event from signal-cli daemon.
  void _handleEvent(Map<String, dynamic> payload) {
    try {
      final message = _parseEnvelope(payload);
      if (message == null) return;

      // DM access control
      if (message.groupJid == null && !dmAccess.isAllowed(message.senderJid)) {
        _log.fine('DM from unapproved sender ${message.senderJid} — dropping');
        return;
      }

      // Group access control
      if (message.groupJid != null) {
        switch (config.groupAccess) {
          case SignalGroupAccessMode.disabled:
            _log.fine('Group message from ${message.groupJid} — group access disabled');
            return;
          case SignalGroupAccessMode.allowlist:
            if (!config.groupAllowlist.contains(message.groupJid)) {
              _log.fine('Group ${message.groupJid} not in allowlist — dropping');
              return;
            }
          case SignalGroupAccessMode.open:
            break;
        }
      }

      // Mention gating (groups only)
      if (!mentionGating.shouldProcess(message)) {
        _log.fine('Group message without mention — ignoring');
        return;
      }

      _channelManager?.handleInboundMessage(message);
    } catch (e, st) {
      _log.warning('Failed to handle Signal event', e, st);
    }
  }

  /// Parse signal-cli envelope.
  ///
  /// Expected format:
  /// ```json
  /// {
  ///   "envelope": {
  ///     "source": "+1234567890",
  ///     "sourceName": "Alice",
  ///     "dataMessage": {
  ///       "message": "Hello",
  ///       "groupInfo": { "groupId": "base64..." }
  ///     }
  ///   }
  /// }
  /// ```
  ChannelMessage? _parseEnvelope(Map<String, dynamic> raw) {
    final envelope = raw['envelope'] as Map<String, dynamic>?;
    if (envelope == null) return null;

    final source = envelope['source'] as String?;
    if (source == null || source.isEmpty) return null;

    final dataMessage = envelope['dataMessage'] as Map<String, dynamic>?;
    if (dataMessage == null) return null;

    final text = dataMessage['message'] as String?;
    if (text == null || text.isEmpty) return null;

    // Group detection
    String? groupId;
    final groupInfo = dataMessage['groupInfo'] as Map<String, dynamic>?;
    if (groupInfo != null) {
      groupId = groupInfo['groupId'] as String?;
    }

    return ChannelMessage(
      channelType: ChannelType.signal,
      senderJid: source,
      groupJid: groupId,
      text: text,
      mentionedJids: const [],
      metadata: {if (envelope['sourceName'] != null) 'sourceName': envelope['sourceName']},
    );
  }
}
