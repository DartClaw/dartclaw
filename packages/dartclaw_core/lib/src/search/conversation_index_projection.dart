import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import '../storage/message_service.dart';
import '../storage/session_service.dart';

/// Counts produced while projecting the authoritative conversation corpus.
final class ConversationProjectionResult {
  /// Creates projection counts.
  const new({required this.messageCount, required this.sessionCount});

  /// Number of indexed messages.
  final int messageCount;

  /// Number of chat-facing sessions containing indexed messages.
  final int sessionCount;
}

/// Maps authoritative session NDJSON messages into the conversation index.
final class ConversationIndexProjection {
  /// Creates a projection over the session and message stores.
  new({
    required this.sessions,
    required this.messages,
    this.userId = 'owner',
    this.configuredPrincipals = const {'owner'},
  });

  /// Session metadata authority.
  final SessionService sessions;

  /// Message NDJSON authority.
  final MessageService messages;

  /// Fallback scope for sessions without pinned workspace ownership.
  final String userId;

  /// Principals whose stale rows must be cleared during a complete rebuild.
  final Set<String> configuredPrincipals;

  Map<String, int>? _projectedCounts;

  /// Maps one eligible persisted message to its index document.
  static SearchDocument? document({
    required Message message,
    required SessionType sessionType,
    ConversationRetention retention = ConversationRetention.durable,
  }) {
    if (!retention.isDurable || !sessionType.isChatFacing || (message.role != 'user' && message.role != 'assistant')) {
      return null;
    }
    return SearchDocument(
      id: message.id,
      chunks: [message.content],
      metadata: {'session_id': message.sessionId, 'role': message.role},
      timestamp: message.createdAt.toUtc(),
    );
  }

  /// Streams one bounded document batch per chat-facing session.
  Stream<({String principal, List<SearchDocument> documents})> documents() async* {
    final chatTypes = SessionType.values.where((type) => type.isChatFacing).toList(growable: false);
    final selected = await sessions.listSessions(types: chatTypes);
    for (final session in selected) {
      final state = await sessions.getConversationState(session.id);
      final batch = (await messages.getMessages(session.id))
          .where((message) => state.includesMessage(message.id))
          .map((message) => document(message: message, sessionType: session.type, retention: session.retention))
          .whereType<SearchDocument>()
          .toList(growable: false);
      yield (principal: _principal(session), documents: batch);
    }
  }

  /// Replaces every known principal corpus and populates them from session NDJSON.
  Future<ConversationProjectionResult> populate(FullTextIndex index) async {
    final selected = await sessions.listSessions(types: SessionType.values.where((type) => type.isChatFacing).toList());
    final principals = {...configuredPrincipals, userId, for (final session in selected) _principal(session)};
    for (final principal in principals) {
      await index.replaceAll(const [], userId: principal);
    }
    final counts = <String, int>{};
    await for (final batch in documents()) {
      if (batch.documents.isEmpty) continue;
      await index.upsert(batch.documents, userId: batch.principal);
      counts['${batch.principal}\u0000${batch.documents.first.metadata['session_id']!}'] = batch.documents.length;
    }
    _projectedCounts = Map.unmodifiable(counts);
    return ConversationProjectionResult(
      messageCount: counts.values.fold(0, (total, count) => total + count),
      sessionCount: counts.length,
    );
  }

  /// Confirms the authoritative source still matches the latest population.
  Future<bool> authenticateComplete() async {
    final projected = _projectedCounts;
    if (projected == null) return false;
    final current = await _sourceCounts();
    if (current.length != projected.length) return false;
    for (final entry in projected.entries) {
      if (current[entry.key] != entry.value) return false;
    }
    return true;
  }

  /// Reconstructs the owner's corpus from session NDJSON.
  Future<ConversationProjectionResult> rebuild(FullTextIndex index) => populate(index);

  Future<Map<String, int>> _sourceCounts() async {
    final counts = <String, int>{};
    await for (final batch in documents()) {
      if (batch.documents.isNotEmpty) {
        counts['${batch.principal}\u0000${batch.documents.first.metadata['session_id']!}'] = batch.documents.length;
      }
    }
    return counts;
  }

  String _principal(Session session) => SessionService.persistedPrincipal(session, fallbackUserId: userId);
}
