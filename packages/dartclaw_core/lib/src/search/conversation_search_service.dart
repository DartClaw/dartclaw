import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:logging/logging.dart';

/// Searches one owner's conversation corpus.
typedef ConversationSearchQuery = Future<List<SearchResult>> Function(
  String query, {
  required String userId,
  required int limit,
  SearchDiagnosticsSink? diagnostics,
});

/// One scored conversation-message search hit with persisted provenance.
final class ConversationHit {
  /// Creates a conversation hit.
  const new({
    required this.messageId,
    this.chunkIndex = 0,
    required this.sessionId,
    required this.role,
    required this.createdAt,
    required this.text,
    required this.score,
  });

  /// Persisted message identity.
  final String messageId;

  /// Zero-based chunk identity retained from the index.
  final int chunkIndex;

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
  const new({required this.index, this.query, this.userId = 'owner', this.userIds});

  /// Derived conversation index.
  final FullTextIndex index;

  /// Optional query implementation used instead of the lexical index.
  final ConversationSearchQuery? query;

  /// Fallback scope when this search surface covers one principal.
  final String userId;

  /// Principal scopes included in this administrative search surface.
  final Set<String>? userIds;

  /// Returns best-first matching persisted messages, or empty when unavailable.
  Future<List<ConversationHit>> search(String query, {int limit = 20, SearchDiagnosticsSink? diagnostics}) async {
    try {
      final buffered = <SearchDiagnostics>[];
      final results = <SearchResult>[];
      for (final principal in userIds ?? {userId}) {
        results.addAll(
          await (this.query?.call(
                query,
                userId: principal,
                limit: limit,
                diagnostics: diagnostics == null ? null : buffered.add,
              ) ??
              index.search(query, userId: principal, limit: limit)),
        );
      }
      if ((userIds?.length ?? 1) > 1) results.sort((left, right) => left.score.compareTo(right.score));
      final hits = results
          .take(limit)
          .map(
            (result) => ConversationHit(
              messageId: result.id,
              chunkIndex: result.chunkIndex,
              sessionId: result.metadata['session_id']!,
              role: result.metadata['role']!,
              createdAt: result.timestamp.toUtc(),
              text: result.chunk,
              score: result.score,
            ),
          )
          .toList(growable: false);
      for (final evidence in buffered) {
        diagnostics?.call(evidence);
      }
      return hits;
    } catch (error, stackTrace) {
      _log.warning('Conversation search failed: $error', error, stackTrace);
      return const [];
    }
  }
}
