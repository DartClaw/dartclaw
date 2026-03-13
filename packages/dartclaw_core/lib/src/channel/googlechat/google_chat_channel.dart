import 'package:logging/logging.dart';

import '../channel.dart';
import '../channel_manager.dart';
import '../dm_access.dart';
import '../whatsapp/mention_gating.dart';
import '../whatsapp/text_chunking.dart';
import 'google_chat_config.dart';
import 'google_chat_rest_client.dart';

class GoogleChatChannel extends Channel {
  static final _log = Logger('GoogleChatChannel');

  @override
  final String name = 'googlechat';

  @override
  final ChannelType type = ChannelType.googlechat;

  final GoogleChatConfig config;
  final GoogleChatRestClient restClient;
  final DmAccessController? dmAccess;
  final MentionGating? mentionGating;
  final ChannelManager? _channelManager;
  final Map<String, String> _pendingPlaceholders = {};

  GoogleChatChannel({
    required this.config,
    required this.restClient,
    ChannelManager? channelManager,
    this.dmAccess,
    this.mentionGating,
  }) : _channelManager = channelManager;

  ChannelManager? get channelManager => _channelManager;

  @override
  Future<void> connect() async {
    _log.info('Starting Google Chat channel');
    await restClient.testConnection();
    _log.info('Google Chat API credentials verified');
    _log.info('Google Chat channel connected');
  }

  @override
  Future<void> sendMessage(String recipientJid, ChannelResponse response) async {
    if (response.mediaAttachments.isNotEmpty) {
      _log.warning('Outbound Google Chat media is not supported in 0.8');
    }
    if (response.text.isEmpty) {
      return;
    }

    final turnId = response.metadata[sourceMessageIdMetadataKey] as String?;
    final placeholder = turnId == null ? null : _pendingPlaceholders.remove(_placeholderKey(recipientJid, turnId));
    if (placeholder != null) {
      final updated = await restClient.editMessage(placeholder, response.text);
      if (updated) {
        return;
      }
      _log.warning('Failed to replace typing placeholder for $recipientJid, falling back to new message');
    }

    await restClient.sendMessage(recipientJid, response.text);
  }

  void setPlaceholder({required String spaceName, required String turnId, required String messageName}) {
    _pendingPlaceholders[_placeholderKey(spaceName, turnId)] = messageName;
  }

  @override
  bool ownsJid(String jid) => jid.startsWith('spaces/');

  @override
  List<ChannelResponse> formatResponse(String text) {
    final chunks = chunkText(text, maxSize: 4000);
    return [for (final chunk in chunks) ChannelResponse(text: chunk)];
  }

  @override
  Future<void> disconnect() async {
    _log.info('Disconnecting Google Chat channel');
    await restClient.close();
    _pendingPlaceholders.clear();
    _log.info('Google Chat channel disconnected');
  }

  String _placeholderKey(String spaceName, String turnId) => '$spaceName::$turnId';
}
