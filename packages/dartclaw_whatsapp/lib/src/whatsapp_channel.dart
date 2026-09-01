import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:logging/logging.dart';

import 'package:dartclaw_core/dartclaw_core.dart';

import 'gowa_manager.dart';
import 'response_formatter.dart' as fmt;
import 'whatsapp_config.dart';

/// Extracts an E.164-style phone number from a WhatsApp JID.
///
/// Returns `null` for absent or non-numeric values such as GOWA device UUIDs.
String? jidToPhone(String? jid) {
  if (jid == null) return null;
  final number = jid.split('@').first.split(':').first;
  if (!RegExp(r'^\d+$').hasMatch(number)) return null;
  return '+$number';
}

/// WhatsApp channel implementation via GOWA sidecar.
class WhatsAppChannel extends Channel {
  static final _log = Logger('WhatsAppChannel');

  @override
  final String name = 'whatsapp';
  @override
  final ChannelType type = ChannelType.whatsapp;

  final GowaManager gowa;
  final WhatsAppConfig config;
  final DmAccessController dmAccess;
  final MentionGating mentionGating;
  final ChannelManager? _channelManager;
  final String _model;
  final String _agentName;
  late final TypingLeaseTracker _typing = TypingLeaseTracker(
    send: gowa.sendChatPresence,
    canSend: () => !_disabled,
    log: _log,
  );

  bool _disabled = false;

  new({
    required this.gowa,
    required this.config,
    required this.dmAccess,
    required this.mentionGating,
    ChannelManager? channelManager,
    String model = 'Claude',
    String agentName = 'DartClaw',
  }) : _channelManager = channelManager,
       _model = model,
       _agentName = agentName;

  @override
  Future<void> connect() async {
    if (_disabled) {
      _log.warning('WhatsApp channel is disabled — skipping connect');
      return;
    }
    await gowa.start();
    _typing.resume();

    // Retrieve own JID from GOWA status for mention gating
    try {
      final status = await gowa.status();
      final deviceId = status.deviceId;
      if (deviceId != null && deviceId.isNotEmpty) {
        mentionGating.ownJid = deviceId;
        _log.info('WhatsApp own JID: $deviceId');
      }
    } catch (e) {
      _log.warning('Could not retrieve own JID from GOWA', e);
    }
  }

  @override
  Future<void> sendMessage(String recipientJid, ChannelResponse response) async {
    if (_disabled) return;

    // Send media attachments first
    for (final path in response.mediaAttachments) {
      try {
        await gowa.sendMedia(recipientJid, path);
      } catch (e) {
        _log.warning('Failed to send media $path to $recipientJid', e);
      }
    }

    // Send text
    if (response.text.isNotEmpty) {
      try {
        await gowa.sendText(recipientJid, response.text);
      } catch (e) {
        _log.warning('Failed to send text to $recipientJid', e);
        _checkBanSignals(e);
        rethrow;
      }
    }
  }

  @override
  Future<void> startTyping(String recipientJid) => _typing.start(recipientJid);

  @override
  Future<void> stopTyping(String recipientJid) => _typing.stop(recipientJid);

  @override
  bool ownsJid(String jid) {
    // WhatsApp JIDs end with @s.whatsapp.net (individual) or @g.us (group)
    return jid.endsWith('@s.whatsapp.net') || jid.endsWith('@g.us');
  }

  @override
  Future<void> disconnect() async {
    await _typing.shutdown();
    await gowa.reset();
  }

  /// Handle an inbound webhook payload from GOWA.
  ///
  /// Normalizes to ChannelMessage, runs the shared [ChannelInboundGate],
  /// then forwards to ChannelManager.
  void handleWebhook(Map<String, dynamic> payload) {
    if (_disabled) return;

    try {
      final message = _parseWebhookPayload(payload);
      if (message == null) return;

      final decision = ChannelInboundGate.evaluate(
        message,
        dmAccess: dmAccess,
        mentionGating: mentionGating,
        groupAccess: config.groupAccess,
        groupAllowlist: config.groupIds,
      );
      switch (decision) {
        case ChannelInboundDecision.admitted:
          break;
        case ChannelInboundDecision.dmPairingRequired:
          final displayName = message.metadata['pushname'] as String?;
          final pairing = dmAccess.createPairing(message.senderJid, displayName: displayName);
          if (pairing != null) {
            _log.info('Pairing request created for ${message.senderJid}');
          } else {
            _log.warning('Max pending pairings reached — dropping message from ${message.senderJid}');
          }
          return;
        case ChannelInboundDecision.dmDenied:
          _log.fine('DM from unapproved sender ${message.senderJid} — dropping');
          return;
        case ChannelInboundDecision.groupAccessDisabled:
        case ChannelInboundDecision.groupNotAllowlisted:
          return;
        case ChannelInboundDecision.mentionRequired:
          _log.fine('Group message without mention — ignoring');
          return;
      }

      _channelManager?.handleInboundMessage(message);
    } catch (e, st) {
      _log.warning('Failed to handle webhook payload', e, st);
    }
  }

  @override
  List<ChannelResponse> formatResponse(String text) {
    return fmt.formatResponse(text, model: _model, agentName: _agentName, maxChunkSize: config.maxChunkSize);
  }

  /// Parse GOWA v8 webhook envelope: `{event, device_id, payload: {...}}`.
  ChannelMessage? _parseWebhookPayload(Map<String, dynamic> envelope) {
    // Only process 'message' events
    final event = envelope['event'] as String?;
    if (event != 'message') return null;

    final inner = envelope['payload'] as Map<String, dynamic>?;
    if (inner == null) return null;

    // Skip own outgoing messages
    if (inner['is_from_me'] == true) return null;

    final senderJid = inner['from'] as String?;
    final text = inner['body'] as String?;
    if (senderJid == null || text == null || text.isEmpty) return null;

    final chatId = inner['chat_id'] as String?;
    final isGroup = chatId != null && chatId.endsWith('@g.us');
    final groupJid = isGroup ? chatId : null;

    return ChannelMessage(
      channelType: ChannelType.whatsapp,
      senderJid: senderJid,
      groupJid: groupJid,
      text: text,
      mentionedJids: const [],
      metadata: {
        if (inner['from_name'] != null) 'pushname': inner['from_name'],
        if (inner['replied_to_id'] != null) 'repliedToId': inner['replied_to_id'],
      },
    );
  }

  void _checkBanSignals(Object error) {
    final msg = error.toString().toLowerCase();
    if (msg.contains('banned') || msg.contains('restricted') || msg.contains('account at risk')) {
      _log.severe('WhatsApp account ban/restriction detected — disabling channel');
      _disabled = true;
    }
  }
}
