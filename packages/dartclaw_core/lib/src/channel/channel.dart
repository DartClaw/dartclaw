import 'package:uuid/uuid.dart';

import '../runtime/channel_type.dart';

/// Normalized inbound message from any channel.
class ChannelMessage {
  /// Unique identifier assigned by the channel adapter.
  final String id;

  /// Channel transport that produced this message.
  final ChannelType channelType;

  /// Sender identifier normalized by the channel adapter.
  final String senderJid;

  /// Group identifier for group messages, or `null` for direct messages.
  final String? groupJid;

  /// Message body forwarded to the runtime.
  final String text;

  /// Timestamp when the source channel reported the message.
  final DateTime timestamp;

  /// Channel-specific identifiers explicitly mentioned in the message.
  final List<String> mentionedJids;

  /// Opaque channel-specific metadata preserved for downstream consumers.
  final Map<String, dynamic> metadata;

  /// Creates a normalized inbound channel message.
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

  /// Extracts a human-readable sender display name from channel-specific
  /// [metadata] keys.
  ///
  /// Checks in priority order:
  /// - `senderDisplayName` (Google Chat)
  /// - `pushname` (WhatsApp)
  /// - `sourceName` (Signal)
  ///
  /// Returns `null` if no display name is available.
  String? get senderDisplayName {
    final gchatName = metadata['senderDisplayName'];
    if (gchatName is String && gchatName.isNotEmpty) return gchatName;
    final waName = metadata['pushname'];
    if (waName is String && waName.isNotEmpty) return waName;
    final sigName = metadata['sourceName'];
    if (sigName is String && sigName.isNotEmpty) return sigName;
    return null;
  }
}

/// Outbound response to send via a channel.
class ChannelResponse {
  /// Text payload to deliver to the recipient.
  ///
  /// When [structuredPayload] is present, this should contain the preferred
  /// plain-text fallback for channels that cannot render structured content.
  final String text;

  /// Filesystem paths or logical handles for media attachments.
  final List<String> mediaAttachments;

  /// Opaque metadata preserved between formatting and delivery.
  final Map<String, dynamic> metadata;

  /// Optional channel-specific structured payload.
  ///
  /// Channels that support structured rendering can prefer this over [text].
  /// Other channels ignore it and continue sending [text]. Adapters may
  /// synthesize a minimal fallback when this is set but [text] is empty.
  final Map<String, dynamic>? structuredPayload;

  /// Message id this response should reply to, when the channel supports it.
  final String? replyToMessageId;

  /// Creates a channel response chunk ready for delivery.
  const ChannelResponse({
    required this.text,
    this.mediaAttachments = const [],
    this.metadata = const {},
    this.structuredPayload,
    this.replyToMessageId,
  });
}

/// Metadata key used to retain the originating inbound message id per response.
const sourceMessageIdMetadataKey = 'sourceMessageId';

/// Abstract base class for messaging channel integrations.
///
/// Concrete implementations (WhatsApp, Telegram, etc.) extend this class.
abstract class Channel {
  /// Stable runtime name for this channel implementation.
  String get name;

  /// Transport type handled by this channel.
  ChannelType get type;

  /// Starts any long-lived resources required to receive or send messages.
  Future<void> connect();

  /// Sends [response] to the given channel-specific recipient identifier.
  Future<void> sendMessage(String recipientJid, ChannelResponse response);

  /// Returns `true` when this channel is responsible for [jid].
  bool ownsJid(String jid);

  /// Releases resources and stops any long-lived channel connections.
  Future<void> disconnect();

  /// Format raw agent output for this channel's delivery requirements.
  /// Default: wrap in a single [ChannelResponse].
  List<ChannelResponse> formatResponse(String text) => [ChannelResponse(text: text)];
}
