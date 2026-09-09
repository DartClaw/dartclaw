import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'api_helpers.dart';

typedef MemoryInspectionQuery = Future<List<SearchResult>?> Function(
  String query, {
  int limit,
  SearchDiagnosticsSink? diagnostics,
});

Router searchInspectionRoutes({MemoryInspectionQuery? inspectMemory, ConversationSearchService? conversations}) {
  final router = Router();
  router.post('/api/search/inspect', (Request request) async {
    final parsed = await readJsonObject(request);
    if (parsed.error != null) return parsed.error!;
    final body = parsed.value!;
    final corpus = body['corpus'];
    final query = body['query'];
    final limit = body['limit'] ?? 20;
    if (body.keys.any((key) => !const {'corpus', 'query', 'limit'}.contains(key)) ||
        (corpus != 'memory' && corpus != 'conversation') ||
        query is! String ||
        query.trim().isEmpty ||
        limit is! int ||
        limit < 1 ||
        limit > 20 ||
        (body.containsKey('limit') && body['limit'] == null)) {
      return errorResponse(400, 'INVALID_INPUT', 'Supply a corpus, nonblank query and integer limit from 1 to 20');
    }
    Response unavailable() =>
        errorResponse(503, 'SEARCH_INSPECTION_UNAVAILABLE', 'Hybrid search inspection is unavailable');
    SearchDiagnostics? evidence;
    void capture(SearchDiagnostics value) => evidence = value;
    try {
      final List<Map<String, Object?>> results;
      if (corpus == 'memory') {
        final hits = await inspectMemory?.call(query, limit: limit, diagnostics: capture);
        if (hits == null || evidence == null) return unavailable();
        results = [
          for (final hit in hits.take(limit))
            {
              'documentId': hit.id,
              'chunkIndex': hit.chunkIndex,
              ...MemoryIndexProjection.toSearchResult(hit).toRetrievalJson(),
            },
        ];
      } else {
        final hits = await conversations?.search(query, limit: limit, diagnostics: capture);
        if (hits == null || evidence == null) return unavailable();
        results = [
          for (final hit in hits.take(limit))
            {
              'documentId': hit.messageId,
              'chunkIndex': hit.chunkIndex,
              'messageId': hit.messageId,
              'sessionId': hit.sessionId,
              'role': hit.role,
              'createdAt': hit.createdAt.toUtc().toIso8601String(),
              'snippet': String.fromCharCodes(hit.text.runes.take(MemorySearchResult.maxSnippetCharacters)),
              'score': hit.score,
            },
        ];
      }
      final diagnostic = evidence!;
      return jsonResponse(200, {
        'corpus': corpus,
        'results': results,
        'diagnostics': {
          'candidates': [
            for (final candidate in diagnostic.candidates)
              {
                'documentId': candidate.documentId,
                'chunkIndex': candidate.chunkIndex,
                'keywordRank': candidate.keywordRank,
                'vectorRank': candidate.vectorRank,
                'keywordContribution': candidate.keywordContribution,
                'vectorContribution': candidate.vectorContribution,
                'fusedScore': candidate.fusedScore,
                'sourceLayer': candidate.sourceLayer,
              },
          ],
          'unembeddedCount': diagnostic.unembeddedCount,
          'degradations': diagnostic.degradations.map((value) => value.toJson()).toList(growable: false),
        },
      });
    } catch (_) {
      return unavailable();
    }
  });
  return router;
}
