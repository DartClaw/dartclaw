const _sessionFieldUnset = Object();

/// Classification for how a [Session] was created.
enum SessionType {
  /// A long-lived primary session created by the runtime itself.
  main,

  /// A session derived from an inbound channel message.
  channel,

  /// A session started by a scheduled task or cron trigger.
  cron,

  /// A user-initiated interactive session such as web or CLI chat.
  user,

  /// A session associated with a tracked task execution.
  task,

  /// A read-only or historical session retained for archival purposes.
  archive,
}

/// A top-level conversation container for exchanges between a user and an agent.
class Session {
  /// Unique identifier for this session.
  final String id;

  /// Human-readable title shown in UI surfaces, or `null` when unnamed.
  final String? title;

  /// How this session was created and routed through the runtime.
  final SessionType type;

  /// Channel-specific routing key for sessions that originate from a channel.
  final String? channelKey;

  /// Optional provider override pinned to this session.
  final String? provider;

  /// When this session record was first created.
  final DateTime createdAt;

  /// When this session was last mutated.
  final DateTime updatedAt;

  /// Creates a session snapshot with immutable metadata.
  const Session({
    required this.id,
    this.title,
    this.type = SessionType.user,
    this.channelKey,
    this.provider,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Serializes this session to a JSON-safe map.
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'type': type.name,
    if (channelKey != null) 'channelKey': channelKey,
    if (provider != null) 'provider': provider,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  /// Reconstructs a [Session] from persisted JSON data.
  factory Session.fromJson(Map<String, dynamic> json) => Session(
    id: json['id'] as String,
    title: json['title'] as String?,
    type: _parseSessionType(json['type']),
    channelKey: json['channelKey'] as String?,
    provider: json['provider'] as String?,
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );

  /// Returns a copy with selected fields replaced.
  Session copyWith({
    String? id,
    Object? title = _sessionFieldUnset,
    SessionType? type,
    Object? channelKey = _sessionFieldUnset,
    Object? provider = _sessionFieldUnset,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => Session(
    id: id ?? this.id,
    title: identical(title, _sessionFieldUnset) ? this.title : title as String?,
    type: type ?? this.type,
    channelKey: identical(channelKey, _sessionFieldUnset) ? this.channelKey : channelKey as String?,
    provider: identical(provider, _sessionFieldUnset) ? this.provider : provider as String?,
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

/// A single persisted message within a [Session].
class Message {
  /// Monotonic message cursor used for stable ordering and resume points.
  final int cursor;

  /// Unique identifier for this message.
  final String id;

  /// Identifier of the parent [Session].
  final String sessionId;

  /// Author role such as `user`, `assistant`, or `system`.
  final String role;

  /// Message body text as stored in session history.
  final String content;

  /// Optional serialized metadata associated with the message.
  final String? metadata;

  /// When the message was created.
  final DateTime createdAt;

  /// Creates an immutable message record.
  const Message({
    required this.cursor,
    required this.id,
    required this.sessionId,
    required this.role,
    required this.content,
    this.metadata,
    required this.createdAt,
  });

  /// Serializes this message to a JSON-safe map.
  Map<String, dynamic> toJson() => {
    'cursor': cursor,
    'id': id,
    'sessionId': sessionId,
    'role': role,
    'content': content,
    'metadata': metadata,
    'createdAt': createdAt.toIso8601String(),
  };

  /// Reconstructs a [Message] from persisted JSON data.
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
  /// SQLite row identifier for this chunk.
  final int id;

  /// Indexed text content used for lexical and semantic search.
  final String textContent;

  /// Source label describing where this chunk came from.
  final String source;

  /// Optional category used for grouping or filtering results.
  final String? category;

  /// When this chunk was created in storage.
  final DateTime createdAt;

  /// Creates an immutable memory chunk snapshot.
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
  /// Text snippet returned by the search backend.
  final String text;

  /// Source label associated with the matching memory entry.
  final String source;

  /// Optional category associated with the result.
  final String? category;

  /// Backend-specific relevance score for ranking matches.
  final double score;

  /// Creates an immutable memory search result value.
  const MemorySearchResult({required this.text, required this.source, this.category, required this.score});
}
