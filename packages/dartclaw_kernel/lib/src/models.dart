import 'execution_policy.dart';
import 'agent_definition.dart' show AgentWorkspace;

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

  /// A logical-agent session retained for diagnostics and maintenance.
  logicalAgent,

  /// A read-only or historical session retained for archival purposes.
  archive;

  /// Whether messages in this session belong to the conversation index.
  ///
  /// Internal execution sessions and archived sessions are excluded.
  bool get isChatFacing => switch (this) {
    main || channel || user => true,
    cron || task || logicalAgent || archive => false,
  };
}

/// Source of the current session title used to resolve automatic-title races.
enum SessionTitleProvenance {
  /// Immediate truncation shown before a generated title is available.
  automaticFallback,

  /// Validated title produced by the schema-bound title agent.
  automaticGenerated,

  /// Title explicitly supplied by an operator.
  manual,

  /// Title written by a non-interactive runtime lifecycle.
  system,
}

/// A top-level conversation container for exchanges between a user and an agent.
class Session {
  /// Unique identifier for this session.
  final String id;

  /// Human-readable title shown in UI surfaces, or `null` when unnamed.
  final String? title;

  /// Monotonic revision of [title].
  final int titleRevision;

  /// Authority that last wrote [title].
  final SessionTitleProvenance? titleProvenance;

  /// Whether the one automatic title request has been claimed.
  final bool automaticTitleAttempted;

  /// How this session was created and routed through the runtime.
  final SessionType type;

  /// Channel-specific routing key for sessions that originate from a channel.
  final String? channelKey;

  /// Optional provider override pinned to this session.
  final String? provider;

  /// Optional worker isolation profile pinned to this session.
  final String? securityProfile;

  /// Optional execution mode pinned to this session.
  ///
  /// Null on sessions written before execution mode became part of pinned
  /// routing; readers derive it from [securityProfile] and the deployment's
  /// container availability, then persist the derived value forward.
  final ExecutionMode? executionMode;

  /// Agent workspace ownership pinned when this session was created.
  ///
  /// Null keeps legacy and unconfigured sessions backward-readable without
  /// assigning them a workspace identity.
  final AgentWorkspace? workspace;

  /// When this session record was first created.
  final DateTime createdAt;

  /// When this session was last mutated.
  final DateTime updatedAt;

  /// When the owner moved this conversation out of the active inbox.
  ///
  /// This remains independent from archival [type], read state, and execution
  /// state. Null means the conversation is active.
  final DateTime? settledAt;

  /// Highest durable message cursor the owner has visibly read.
  final int readMessageCursor;

  /// Latest durable attention event the owner has marked read.
  final String? attentionReadEventId;

  /// Terminal attention event identities the owner has dismissed.
  final List<String> dismissedAttentionEventIds;

  /// Creates a session snapshot with immutable metadata.
  const new({
    required this.id,
    this.title,
    this.titleRevision = 0,
    this.titleProvenance,
    this.automaticTitleAttempted = false,
    this.type = SessionType.user,
    this.channelKey,
    this.provider,
    this.securityProfile,
    this.executionMode,
    this.workspace,
    required this.createdAt,
    required this.updatedAt,
    this.settledAt,
    this.readMessageCursor = 0,
    this.attentionReadEventId,
    this.dismissedAttentionEventIds = const [],
  });

  /// Serializes this session to a JSON-safe map.
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'titleRevision': titleRevision,
    if (titleProvenance != null) 'titleProvenance': titleProvenance!.name,
    if (automaticTitleAttempted) 'automaticTitleAttempted': true,
    'type': type.name,
    if (channelKey != null) 'channelKey': channelKey,
    if (provider != null) 'provider': provider,
    if (securityProfile != null) 'securityProfile': securityProfile,
    if (executionMode != null) 'executionMode': executionMode!.name,
    if (workspace != null) 'workspaceAgentId': workspace!.agentId,
    if (workspace != null) 'workspaceDir': workspace!.directory,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    if (settledAt != null) 'settledAt': settledAt!.toUtc().toIso8601String(),
    if (readMessageCursor > 0) 'readMessageCursor': readMessageCursor,
    if (attentionReadEventId != null) 'attentionReadEventId': attentionReadEventId,
    if (dismissedAttentionEventIds.isNotEmpty) 'dismissedAttentionEventIds': dismissedAttentionEventIds,
  };

  /// Reconstructs a [Session] from persisted JSON data.
  ///
  /// A missing legacy `type` defaults to [SessionType.user]. Throws
  /// [FormatException] when a present type is not a supported string value.
  factory fromJson(Map<String, dynamic> json) {
    final workspaceAgentId = json['workspaceAgentId'];
    final workspaceDir = json['workspaceDir'];
    if ((workspaceAgentId == null) != (workspaceDir == null) ||
        workspaceAgentId != null && (workspaceAgentId is! String || workspaceDir is! String)) {
      throw const FormatException('Session workspace ownership must contain workspaceAgentId and workspaceDir');
    }
    return Session(
      id: json['id'] as String,
      title: json['title'] as String?,
      titleRevision: json['titleRevision'] as int? ?? 0,
      titleProvenance: _parseTitleProvenance(json['titleProvenance']),
      automaticTitleAttempted: json['automaticTitleAttempted'] as bool? ?? false,
      type: _parseSessionType(json['type']),
      channelKey: json['channelKey'] as String?,
      provider: json['provider'] as String?,
      securityProfile: json['securityProfile'] as String?,
      executionMode: _parseExecutionMode(json['executionMode']),
      workspace: workspaceAgentId == null
          ? null
          : AgentWorkspace.pinned(agentId: workspaceAgentId as String, directory: workspaceDir as String),
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      settledAt: json['settledAt'] == null ? null : DateTime.parse(json['settledAt'] as String),
      readMessageCursor: json['readMessageCursor'] as int? ?? 0,
      attentionReadEventId: json['attentionReadEventId'] as String?,
      dismissedAttentionEventIds: (json['dismissedAttentionEventIds'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(growable: false),
    );
  }

  /// Returns a copy with selected fields replaced.
  Session copyWith({
    String? id,
    Object? title = _sessionFieldUnset,
    int? titleRevision,
    Object? titleProvenance = _sessionFieldUnset,
    bool? automaticTitleAttempted,
    SessionType? type,
    Object? channelKey = _sessionFieldUnset,
    Object? provider = _sessionFieldUnset,
    Object? securityProfile = _sessionFieldUnset,
    Object? executionMode = _sessionFieldUnset,
    Object? workspace = _sessionFieldUnset,
    DateTime? createdAt,
    DateTime? updatedAt,
    Object? settledAt = _sessionFieldUnset,
    int? readMessageCursor,
    Object? attentionReadEventId = _sessionFieldUnset,
    List<String>? dismissedAttentionEventIds,
  }) => Session(
    id: id ?? this.id,
    title: identical(title, _sessionFieldUnset) ? this.title : title as String?,
    titleRevision: titleRevision ?? this.titleRevision,
    titleProvenance: identical(titleProvenance, _sessionFieldUnset)
        ? this.titleProvenance
        : titleProvenance as SessionTitleProvenance?,
    automaticTitleAttempted: automaticTitleAttempted ?? this.automaticTitleAttempted,
    type: type ?? this.type,
    channelKey: identical(channelKey, _sessionFieldUnset) ? this.channelKey : channelKey as String?,
    provider: identical(provider, _sessionFieldUnset) ? this.provider : provider as String?,
    securityProfile: identical(securityProfile, _sessionFieldUnset) ? this.securityProfile : securityProfile as String?,
    executionMode: identical(executionMode, _sessionFieldUnset) ? this.executionMode : executionMode as ExecutionMode?,
    workspace: identical(workspace, _sessionFieldUnset) ? this.workspace : workspace as AgentWorkspace?,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    settledAt: identical(settledAt, _sessionFieldUnset) ? this.settledAt : settledAt as DateTime?,
    readMessageCursor: readMessageCursor ?? this.readMessageCursor,
    attentionReadEventId: identical(attentionReadEventId, _sessionFieldUnset)
        ? this.attentionReadEventId
        : attentionReadEventId as String?,
    dismissedAttentionEventIds: dismissedAttentionEventIds ?? this.dismissedAttentionEventIds,
  );

  static ExecutionMode? _parseExecutionMode(Object? value) {
    if (value == null) return null;
    final mode = value is String ? ExecutionMode.fromYaml(value) : null;
    if (mode == null) throw FormatException('Unknown session execution mode: $value');
    return mode;
  }

  static SessionType _parseSessionType(Object? value) {
    if (value == null) return SessionType.user;
    if (value case final String name) {
      final type = SessionType.values.asNameMap()[name];
      if (type != null) return type;
    }
    throw FormatException('Unknown session type: $value');
  }

  static SessionTitleProvenance? _parseTitleProvenance(Object? value) {
    if (value == null) return null;
    if (value case final String name) {
      final provenance = SessionTitleProvenance.values.asNameMap()[name];
      if (provenance != null) return provenance;
    }
    throw FormatException('Unknown session title provenance: $value');
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
  const new({
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
  factory fromJson(Map<String, dynamic> json) => Message(
    cursor: json['cursor'] as int,
    id: json['id'] as String,
    sessionId: json['sessionId'] as String,
    role: json['role'] as String,
    content: json['content'] as String,
    metadata: json['metadata'] as String?,
    createdAt: DateTime.parse(json['createdAt'] as String),
  );
}

/// A ranked result from a memory search query.
class MemorySearchResult {
  /// Maximum Unicode scalar count exposed by [snippet].
  static const maxSnippetCharacters = 240;

  /// Text snippet returned by the search backend.
  final String text;

  /// Source label associated with the matching memory entry.
  final String source;

  /// Optional category associated with the result.
  final String? category;

  /// Backend-specific relevance score for ranking matches.
  final double score;

  /// Canonical memory role, or the native source role for non-canonical results.
  final String role;

  /// Host-labelled source provenance suitable for tool responses.
  final String provenance;

  /// Stable source-of-record locator used by `memory_read`.
  final String locator;

  /// Canonical entry identity, omitted for native sources such as wiki pages.
  final String? entryId;

  /// Canonical entry revision, omitted for native sources such as wiki pages.
  final int? entryRevision;

  /// Creates an immutable memory search result value.
  const new({
    required this.text,
    required this.source,
    this.category,
    required this.score,
    this.role = 'memory',
    this.provenance = 'unknown',
    String? locator,
    this.entryId,
    this.entryRevision,
  }) : locator = locator ?? source;

  /// Creates a result backed by one canonical entry identity.
  factory canonical({
    required String text,
    required String source,
    String? category,
    required double score,
    required String role,
    required String provenance,
    required String locator,
    required String entryId,
    required int entryRevision,
  }) {
    if (!const {'topic', 'archive', 'observation', 'learning'}.contains(role)) {
      throw ArgumentError.value(role, 'role', 'must be a canonical searchable role');
    }
    if (locator != entryId || !_canonicalMemoryId.hasMatch(locator)) {
      throw ArgumentError.value(locator, 'locator', 'must equal the canonical entry UUID');
    }
    if (entryRevision < 1) throw ArgumentError.value(entryRevision, 'entryRevision', 'must be positive');
    return MemorySearchResult(
      text: text,
      source: source,
      category: category,
      score: score,
      role: role,
      provenance: provenance,
      locator: locator,
      entryId: entryId,
      entryRevision: entryRevision,
    );
  }

  /// Bounded result text returned by a search backend.
  String get snippet {
    final codePoints = text.runes.take(maxSnippetCharacters + 1).toList(growable: false);
    return codePoints.length <= maxSnippetCharacters
        ? text
        : String.fromCharCodes(codePoints.take(maxSnippetCharacters));
  }

  /// Builds the role-discriminated retrieval record exposed by memory tools.
  Map<String, Object?> toRetrievalJson() => {
    'role': role,
    'snippet': snippet,
    'provenance': provenance,
    'locator': locator,
    'score': score,
    if (entryId != null) 'entryId': entryId,
    if (entryRevision != null) 'entryRevision': entryRevision,
  };
}

final _canonicalMemoryId = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

/// Explains one bounded retrieval omission or failure without discarding healthy results.
final class MemorySearchDegradation {
  /// Creates structured degradation evidence for one retrieval layer.
  const new({
    required this.layer,
    required this.reason,
    this.locator,
    this.observed,
    this.limit,
    this.omittedCount = 0,
  });

  /// Retrieval layer whose coverage degraded.
  final String layer;

  /// Stable machine-readable failure or exhaustion reason.
  final String reason;

  /// Affected source locator, when known.
  final String? locator;

  /// Actual count or byte size, when known.
  final int? observed;

  /// Inclusive count or byte ceiling, when applicable.
  final int? limit;

  /// Known omitted sources; zero means the exact count is unavailable.
  final int omittedCount;

  /// Serializes the bounded failure evidence for tool and API responses.
  Map<String, Object?> toJson() => {
    'layer': layer,
    'reason': reason,
    if (locator != null) 'locator': locator,
    if (observed != null) 'observed': observed,
    if (limit != null) 'limit': limit,
    'omittedCount': omittedCount,
  };
}

/// Results and constituent degradation from one memory search request.
final class MemorySearchOutcome extends Iterable<MemorySearchResult> {
  /// Ranked results returned by the selected search path.
  final List<MemorySearchResult> results;

  /// Retrieval constituents that failed while other results survived.
  final List<String> degradedLayers;

  /// Structured reasons and limits for partial retrieval coverage.
  final List<MemorySearchDegradation> degradations;

  /// Canonical collection revision coherently observed by the search path.
  final int? canonicalRevision;

  /// Creates one search outcome.
  const new({
    required this.results,
    this.degradedLayers = const [],
    this.degradations = const [],
    this.canonicalRevision,
  });

  @override
  Iterator<MemorySearchResult> get iterator => results.iterator;
}
