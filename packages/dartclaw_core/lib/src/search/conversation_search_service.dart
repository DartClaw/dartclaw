import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:logging/logging.dart';

/// Searches one owner's conversation corpus.
typedef ConversationSearchQuery = Future<List<SearchResult>> Function(
  String query, {
  required String userId,
  required int limit,
  FullTextSearchScope? scope,
  SearchDiagnosticsSink? diagnostics,
});

/// Result of one conversation search request.
final class ConversationSearchOutcome {
  /// Creates a successful search outcome.
  const new success({required this.hits, required this.total}) : failure = null;

  /// Creates a failed search outcome without presenting it as an empty match.
  const new failed(this.failure) : hits = const [], total = 0;

  /// Ranked hits after scope filtering and pagination.
  final List<ConversationHit> hits;

  /// Complete match count after scope filtering and before [hits] is limited.
  final int total;

  /// Stable failure code, or `null` on success.
  final String? failure;

  /// Whether the index query completed successfully.
  bool get succeeded => failure == null;
}

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

  /// Returns best-first matching persisted messages for [userId].
  ///
  /// This principal-local entry point deliberately ignores [userIds]. Product
  /// owner aggregation goes through [searchAdministrative].
  Future<List<ConversationHit>> search(String query, {int limit = 20, SearchDiagnosticsSink? diagnostics}) async {
    final outcome = await _search(query, principals: {userId}, limit: limit, diagnostics: diagnostics);
    return outcome.hits;
  }

  /// Searches the configured administrative principal set.
  ///
  /// [principals] can only narrow the configured set. Session filtering happens
  /// before [limit], so excluded conversations cannot affect [total] or pages.
  Future<ConversationSearchOutcome> searchAdministrative(
    String query, {
    Set<String>? principals,
    Set<String>? sessionIds,
    int? limit = 20,
    SearchDiagnosticsSink? diagnostics,
  }) {
    final configured = userIds ?? {userId};
    final selected = principals == null ? configured : configured.intersection(principals);
    return _search(query, principals: selected, sessionIds: sessionIds, limit: limit, diagnostics: diagnostics);
  }

  Future<ConversationSearchOutcome> _search(
    String naturalLanguageQuery, {
    required Set<String> principals,
    Set<String>? sessionIds,
    required int? limit,
    SearchDiagnosticsSink? diagnostics,
  }) async {
    if (limit != null && limit < 1) throw ArgumentError.value(limit, 'limit', 'must be positive');
    if (sessionIds?.isEmpty ?? false) return const ConversationSearchOutcome.success(hits: [], total: 0);
    try {
      final scopedIndex = index as ScopedFullTextIndex;
      final scope = sessionIds == null
          ? null
          : FullTextSearchScope(metadataKey: 'session_id', acceptedValues: sessionIds);
      final buffered = <SearchDiagnostics>[];
      final ranked = <_PrincipalResult>[];
      var total = 0;
      final orderedPrincipals = principals.toList(growable: false)..sort();
      for (final principal in orderedPrincipals) {
        final injectedQuery = query;
        if (injectedQuery != null && scope == null) {
          final results = await injectedQuery(
            naturalLanguageQuery,
            userId: principal,
            limit: limit ?? await scopedIndex.countMatches(naturalLanguageQuery, userId: principal),
            diagnostics: diagnostics == null ? null : buffered.add,
          );
          total += results.length;
          ranked.addAll([
            for (final (rank, result) in results.indexed)
              _PrincipalResult(principal: principal, rank: rank, result: result),
          ]);
          continue;
        }
        final principalTotal = await scopedIndex.countMatches(naturalLanguageQuery, userId: principal, scope: scope);
        total += principalTotal;
        if (principalTotal == 0) continue;
        final candidateLimit = limit ?? principalTotal;
        final results =
            await (injectedQuery?.call(
                  naturalLanguageQuery,
                  userId: principal,
                  limit: candidateLimit,
                  scope: scope,
                  diagnostics: diagnostics == null ? null : buffered.add,
                ) ??
                (scope == null
                    ? index.search(naturalLanguageQuery, userId: principal, limit: candidateLimit)
                    : scopedIndex.searchScoped(
                        naturalLanguageQuery,
                        userId: principal,
                        scope: scope,
                        limit: candidateLimit,
                      )));
        ranked.addAll([
          for (final (rank, result) in results.indexed)
            _PrincipalResult(principal: principal, rank: rank, result: result),
        ]);
      }
      if (orderedPrincipals.length > 1) ranked.sort(_comparePrincipalResults);
      final mapped = ranked.map((ranked) {
        final result = ranked.result;
        return ConversationHit(
          messageId: result.id,
          chunkIndex: result.chunkIndex,
          sessionId: result.metadata['session_id']!,
          role: result.metadata['role']!,
          createdAt: result.timestamp.toUtc(),
          text: result.chunk,
          score: result.score,
        );
      });
      final hits = (limit == null ? mapped : mapped.take(limit)).toList(growable: false);
      for (final evidence in buffered) {
        diagnostics?.call(evidence);
      }
      return ConversationSearchOutcome.success(hits: hits, total: total);
    } catch (error, stackTrace) {
      _log.warning('Conversation search failed: $error', error, stackTrace);
      return const ConversationSearchOutcome.failed('SEARCH_BACKEND_UNAVAILABLE');
    }
  }
}

final class _PrincipalResult {
  const new({required this.principal, required this.rank, required this.result});

  final String principal;
  final int rank;
  final SearchResult result;
}

int _comparePrincipalResults(_PrincipalResult left, _PrincipalResult right) {
  final byNormalizedRank = left.rank.compareTo(right.rank);
  if (byNormalizedRank != 0) return byNormalizedRank;
  final byTimestamp = right.result.timestamp.compareTo(left.result.timestamp);
  if (byTimestamp != 0) return byTimestamp;
  final byPrincipal = left.principal.compareTo(right.principal);
  if (byPrincipal != 0) return byPrincipal;
  final byDocument = left.result.id.compareTo(right.result.id);
  return byDocument != 0 ? byDocument : left.result.chunkIndex.compareTo(right.result.chunkIndex);
}
