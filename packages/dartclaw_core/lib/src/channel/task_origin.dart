/// Tracks the originating channel for a channel-triggered task.
///
/// Stored under `task.configJson['origin']` at task creation time.
class TaskOrigin {
  final String channelType;
  final String sessionKey;
  final String recipientId;
  final String? contactId;
  final String? sourceMessageId;

  /// Human-readable display name extracted from channel sender metadata.
  ///
  /// Source varies by channel: `displayName` (Google Chat), `pushname`
  /// (WhatsApp), `sourceName` (Signal).
  final String? senderDisplayName;

  /// Stable sender identifier from the originating channel.
  ///
  /// Mirrors [contactId] but retained separately so future callers have an
  /// explicit, named attribution field to render.
  final String? senderId;

  /// URL of the sender's avatar image, if available from the channel.
  ///
  /// Currently populated only for Google Chat (sender `avatarUrl`).
  final String? senderAvatarUrl;

  const TaskOrigin({
    required this.channelType,
    required this.sessionKey,
    required this.recipientId,
    this.contactId,
    this.sourceMessageId,
    this.senderDisplayName,
    this.senderId,
    this.senderAvatarUrl,
  });

  Map<String, dynamic> toJson() => {
    'channelType': channelType,
    'sessionKey': sessionKey,
    'recipientId': recipientId,
    if (contactId != null) 'contactId': contactId,
    if (sourceMessageId != null) 'sourceMessageId': sourceMessageId,
    if (senderDisplayName != null) 'senderDisplayName': senderDisplayName,
    if (senderId != null) 'senderId': senderId,
    if (senderAvatarUrl != null) 'senderAvatarUrl': senderAvatarUrl,
  };

  factory TaskOrigin.fromJson(Map<String, dynamic> json) => TaskOrigin(
    channelType: json['channelType'] as String,
    sessionKey: json['sessionKey'] as String,
    recipientId: json['recipientId'] as String,
    contactId: json['contactId'] as String?,
    sourceMessageId: json['sourceMessageId'] as String?,
    senderDisplayName: json['senderDisplayName'] as String?,
    senderId: json['senderId'] as String?,
    senderAvatarUrl: json['senderAvatarUrl'] as String?,
  );

  static TaskOrigin? fromConfigJson(Map<String, dynamic> configJson) {
    final origin = configJson['origin'];
    if (origin is! Map) {
      return null;
    }

    try {
      return TaskOrigin.fromJson(Map<String, dynamic>.from(origin));
    } on Object {
      return null;
    }
  }
}
