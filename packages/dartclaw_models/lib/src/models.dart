/// Classification for how a session was created.
enum SessionType { main, channel, cron, user, task, archive }

/// A conversation session containing messages between user and agent.
class Session {
  final String id;
  final String? title;
  final SessionType type;
  final String? channelKey;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Session({
    required this.id,
    this.title,
    this.type = SessionType.user,
    this.channelKey,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'type': type.name,
    if (channelKey != null) 'channelKey': channelKey,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory Session.fromJson(Map<String, dynamic> json) => Session(
    id: json['id'] as String,
    title: json['title'] as String?,
    type: _parseSessionType(json['type']),
    channelKey: json['channelKey'] as String?,
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );

  Session copyWith({
    String? id,
    String? title,
    SessionType? type,
    String? channelKey,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => Session(
    id: id ?? this.id,
    title: title ?? this.title,
    type: type ?? this.type,
    channelKey: channelKey ?? this.channelKey,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  static SessionType _parseSessionType(Object? value) {
    if (value is String) {
      return SessionType.values.asNameMap()[value] ?? SessionType.user;
    }
    return SessionType.user; // backward compat default
  }
}

/// A single message in a session, with a cursor for crash-recovery resumption.
class Message {
  final int cursor;
  final String id;
  final String sessionId;
  final String role;
  final String content;
  final String? metadata;
  final DateTime createdAt;

  const Message({
    required this.cursor,
    required this.id,
    required this.sessionId,
    required this.role,
    required this.content,
    this.metadata,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'cursor': cursor,
    'id': id,
    'sessionId': sessionId,
    'role': role,
    'content': content,
    'metadata': metadata,
    'createdAt': createdAt.toIso8601String(),
  };

  factory Message.fromJson(Map<String, dynamic> json) => Message(
    cursor: json['cursor'] as int,
    id: json['id'] as String,
    sessionId: json['sessionId'] as String,
    role: json['role'] as String,
    content: json['content'] as String,
    metadata: json['metadata'] as String?,
    createdAt: DateTime.parse(json['createdAt'] as String),
  );
}

/// A chunk of text stored in the FTS5 memory index for semantic search.
class MemoryChunk {
  final int id;
  final String textContent;
  final String source;
  final String? category;
  final DateTime createdAt;

  const MemoryChunk({
    required this.id,
    required this.textContent,
    required this.source,
    this.category,
    required this.createdAt,
  });
}

/// A ranked result from a memory search query.
class MemorySearchResult {
  final String text;
  final String source;
  final String? category;
  final double score;

  const MemorySearchResult({required this.text, required this.source, this.category, required this.score});
}
