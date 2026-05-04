import 'package:dartclaw_core/dartclaw_core.dart' show MemorySearchResult, SearchBackend;
import 'package:logging/logging.dart';

import 'qmd_manager.dart';

/// Search depth options for QMD queries.
enum SearchDepth {
  /// Lexical only (~26ms)
  fast('lex'),

  /// Lexical + vector (~200ms)
  standard('lex+vec'),

  /// Full query with reranking (5-8s)
  deep('query');

  final String value;
  const SearchDepth(this.value);

  static SearchDepth fromString(String s) => switch (s) {
    'fast' => SearchDepth.fast,
    'deep' => SearchDepth.deep,
    _ => SearchDepth.standard,
  };
}

/// QMD-based search backend with FTS5 fallback.
///
/// Queries the QMD REST API for hybrid search (lexical + vector).
/// Falls back to FTS5 if QMD is unreachable.
class QmdSearchBackend implements SearchBackend {
  static final _log = Logger('QmdSearchBackend');

  final QmdManager manager;
  final SearchBackend fallback;
  final SearchDepth defaultDepth;

  QmdSearchBackend({required this.manager, required this.fallback, this.defaultDepth = SearchDepth.standard});

  @override
  Future<List<MemorySearchResult>> search(String query, {int limit = 10, String userId = 'owner'}) async {
    if (!manager.isRunning) {
      _log.fine('QMD not running — falling back to FTS5');
      return fallback.search(query, limit: limit, userId: userId);
    }

    try {
      final results = await manager.query(query, depth: defaultDepth.value, limit: limit);

      return results.map((r) {
        return MemorySearchResult(
          text: r['text'] as String? ?? r['content'] as String? ?? '',
          source: r['source'] as String? ?? r['path'] as String? ?? 'qmd',
          category: r['category'] as String?,
          score: (r['score'] as num?)?.toDouble() ?? 0.0,
        );
      }).toList();
    } catch (e) {
      _log.warning('QMD search failed — falling back to FTS5: $e');
      return fallback.search(query, limit: limit, userId: userId);
    }
  }

  @override
  Future<void> indexAfterWrite() async {
    if (!manager.isRunning) return;
    try {
      await manager.triggerIndex();
    } catch (e) {
      _log.warning('QMD indexing failed: $e');
    }
  }
}
