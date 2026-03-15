/// Tracks the originating channel for a channel-triggered task.
///
/// Stored under `task.configJson['origin']` at task creation time.
class TaskOrigin {
  final String channelType;
  final String sessionKey;
  final String recipientId;
  final String? contactId;
  final String? sourceMessageId;

  const TaskOrigin({
    required this.channelType,
    required this.sessionKey,
    required this.recipientId,
    this.contactId,
    this.sourceMessageId,
  });

  Map<String, dynamic> toJson() => {
    'channelType': channelType,
    'sessionKey': sessionKey,
    'recipientId': recipientId,
    if (contactId != null) 'contactId': contactId,
    if (sourceMessageId != null) 'sourceMessageId': sourceMessageId,
  };

  factory TaskOrigin.fromJson(Map<String, dynamic> json) => TaskOrigin(
    channelType: json['channelType'] as String,
    sessionKey: json['sessionKey'] as String,
    recipientId: json['recipientId'] as String,
    contactId: json['contactId'] as String?,
    sourceMessageId: json['sourceMessageId'] as String?,
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
