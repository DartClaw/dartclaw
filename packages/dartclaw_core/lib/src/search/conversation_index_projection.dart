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
  new({required this.sessions, required this.messages, this.userId = 'owner'});

  /// Session metadata authority.
  final SessionService sessions;

  /// Message NDJSON authority.
  final MessageService messages;

  /// Instance owner scope used for every index operation.
  final String userId;

  Map<String, int>? _projectedCounts;

  /// Maps one eligible persisted message to its index document.
  static SearchDocument? document({required Message message, required SessionType sessionType}) {
    if (!sessionType.isChatFacing || (message.role != 'user' && message.role != 'assistant')) {
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
  Stream<List<SearchDocument>> documents() async* {
    final chatTypes = SessionType.values.where((type) => type.isChatFacing).toList(growable: false);
    final selected = await sessions.listSessions(types: chatTypes);
    for (final session in selected) {
      final batch = (await messages.getMessages(session.id))
          .map((message) => document(message: message, sessionType: session.type))
          .whereType<SearchDocument>()
          .toList(growable: false);
      yield batch;
    }
  }

  /// Replaces the owner's corpus and populates it from session NDJSON.
  Future<ConversationProjectionResult> populate(FullTextIndex index) async {
    await index.replaceAll(const [], userId: userId);
    final counts = <String, int>{};
    await for (final batch in documents()) {
      if (batch.isEmpty) continue;
      await index.upsert(batch, userId: userId);
      counts[batch.first.metadata['session_id']!] = batch.length;
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
      if (batch.isNotEmpty) counts[batch.first.metadata['session_id']!] = batch.length;
    }
    return counts;
  }
}
