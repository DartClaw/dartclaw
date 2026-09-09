import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:logging/logging.dart';

/// One scored conversation-message search hit with persisted provenance.
final class ConversationHit {
  /// Creates a conversation hit.
  const new({
    required this.messageId,
    required this.sessionId,
    required this.role,
    required this.createdAt,
    required this.text,
    required this.score,
  });

  /// Persisted message identity.
  final String messageId;

  /// Parent session identity.
  final String sessionId;

  /// Persisted message role.
  final String role;

  /// Persisted message timestamp in UTC.
  final DateTime createdAt;

  /// Persisted message content.
  final String text;

  /// Backend-native relevance score.
  final double score;
}

/// Searches the instance owner's derived conversation corpus.
final class ConversationSearchService {
  static final _log = Logger('ConversationSearchService');

  /// Creates a service over one conversation index instance.
  const new({required this.index, this.userId = 'owner'});

  /// Derived conversation index.
  final FullTextIndex index;

  /// Instance owner scope used for every query.
  final String userId;

  /// Returns best-first matching persisted messages, or empty when unavailable.
  Future<List<ConversationHit>> search(String query, {int limit = 20}) async {
    try {
      final results = await index.search(query, userId: userId, limit: limit);
      return results
          .map(
            (result) => ConversationHit(
              messageId: result.id,
              sessionId: result.metadata['session_id']!,
              role: result.metadata['role']!,
              createdAt: result.timestamp.toUtc(),
              text: result.chunk,
              score: result.score,
            ),
          )
          .toList(growable: false);
    } catch (error, stackTrace) {
      _log.warning('Conversation search failed: $error', error, stackTrace);
      return const [];
    }
  }
}
