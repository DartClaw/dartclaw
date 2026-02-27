import 'package:uuid/uuid.dart';

enum ChannelType { web, whatsapp }

/// Normalized inbound message from any channel.
class ChannelMessage {
  final String id;
  final ChannelType channelType;
  final String senderJid;
  final String? groupJid;
  final String text;
  final DateTime timestamp;
  final List<String> mentionedJids;
  final Map<String, dynamic> metadata;

  ChannelMessage({
    String? id,
    required this.channelType,
    required this.senderJid,
    this.groupJid,
    required this.text,
    DateTime? timestamp,
    this.mentionedJids = const [],
    this.metadata = const {},
  }) : id = id ?? const Uuid().v4(),
       timestamp = timestamp ?? DateTime.now();
}

/// Outbound response to send via a channel.
class ChannelResponse {
  final String text;
  final List<String> mediaAttachments;
  final Map<String, dynamic> metadata;

  const ChannelResponse({required this.text, this.mediaAttachments = const [], this.metadata = const {}});
}

/// Abstract base class for messaging channel integrations.
///
/// Concrete implementations (WhatsApp, Telegram, etc.) extend this class.
abstract class Channel {
  String get name;
  ChannelType get type;

  Future<void> connect();
  Future<void> sendMessage(String recipientJid, ChannelResponse response);
  bool ownsJid(String jid);
  Future<void> disconnect();
}
