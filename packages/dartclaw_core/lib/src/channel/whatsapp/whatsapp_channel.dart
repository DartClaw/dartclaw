import 'package:logging/logging.dart';

import '../channel.dart';
import '../channel_manager.dart';
import 'dm_access.dart';
import 'gowa_manager.dart';
import 'mention_gating.dart';
import 'response_formatter.dart';
import 'whatsapp_config.dart';

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
  final String _workspaceDir;
  final String _model;
  final String _agentName;

  bool _disabled = false;

  WhatsAppChannel({
    required this.gowa,
    required this.config,
    required this.dmAccess,
    required this.mentionGating,
    ChannelManager? channelManager,
    required String workspaceDir,
    String model = 'Claude',
    String agentName = 'DartClaw',
  }) : _channelManager = channelManager,
       _workspaceDir = workspaceDir,
       _model = model,
       _agentName = agentName;

  @override
  Future<void> connect() async {
    if (_disabled) {
      _log.warning('WhatsApp channel is disabled — skipping connect');
      return;
    }
    await gowa.start();
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
  bool ownsJid(String jid) {
    // WhatsApp JIDs end with @s.whatsapp.net (individual) or @g.us (group)
    return jid.endsWith('@s.whatsapp.net') || jid.endsWith('@g.us');
  }

  @override
  Future<void> disconnect() async {
    await gowa.stop();
  }

  /// Handle an inbound webhook payload from GOWA.
  ///
  /// Normalizes to ChannelMessage, applies DM access + mention gating,
  /// then forwards to ChannelManager.
  void handleWebhook(Map<String, dynamic> payload) {
    if (_disabled) return;

    try {
      final message = _parseWebhookPayload(payload);
      if (message == null) return;

      // DM access control
      if (message.groupJid == null && !dmAccess.isAllowed(message.senderJid)) {
        _log.fine('DM from unapproved sender ${message.senderJid} — dropping');
        return;
      }

      // Group access control
      if (message.groupJid != null) {
        switch (config.groupAccess) {
          case GroupAccessMode.disabled:
            return;
          case GroupAccessMode.allowlist:
            if (!config.groupAllowlist.contains(message.groupJid)) return;
          case GroupAccessMode.open:
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
      _log.warning('Failed to handle webhook payload', e, st);
    }
  }

  /// Format an agent response for WhatsApp delivery.
  List<ChannelResponse> formatAgentResponse(String agentOutput) {
    return formatResponse(
      agentOutput,
      model: _model,
      agentName: _agentName,
      maxChunkSize: config.maxChunkSize,
      workspaceDir: _workspaceDir,
    );
  }

  ChannelMessage? _parseWebhookPayload(Map<String, dynamic> payload) {
    final senderJid = payload['jid'] as String?;
    final text = payload['message'] as String?;
    if (senderJid == null || text == null || text.isEmpty) return null;

    final isGroup = payload['is_group'] as bool? ?? false;
    final groupJid = isGroup ? (payload['group_jid'] as String?) : null;

    // Parse mentioned JIDs
    final mentionedRaw = payload['mentioned_jids'];
    final mentionedJids = mentionedRaw is List ? mentionedRaw.whereType<String>().toList() : <String>[];

    return ChannelMessage(
      channelType: ChannelType.whatsapp,
      senderJid: senderJid,
      groupJid: groupJid,
      text: text,
      mentionedJids: mentionedJids,
      metadata: {
        if (payload['pushname'] != null) 'pushname': payload['pushname'],
        if (payload['quoted_message_sender'] != null) 'quotedMessageSender': payload['quoted_message_sender'],
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
