import 'package:dartclaw_core/dartclaw_core.dart' show MemorySearchResult, SearchBackend;
import 'package:logging/logging.dart';

import 'qmd_manager.dart';
import 'wiki_search_source.dart';

/// Search depth options for QMD queries.
enum SearchDepth {
  /// Lexical only (~26ms)
  fast('lex'),

  /// Lexical + vector (~200ms)
  standard('lex+vec'),

  /// Full query with reranking (5-8s)
  deep('query');

  /// Wire value passed to the QMD `mode` query parameter.
  final String value;
  const SearchDepth(this.value);

  /// Parses a [SearchDepth] from its config string.
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

  /// QMD lifecycle manager used to issue queries.
  final QmdManager manager;

  /// Backend used when QMD is unreachable or fails.
  final SearchBackend fallback;

  /// Default search depth applied when callers do not override it.
  final SearchDepth defaultDepth;

  final WikiSearchSource? _wikiSearch;

  /// Creates a QMD-backed search backend with [fallback] as the FTS5 substitute.
  QmdSearchBackend({
    required this.manager,
    required this.fallback,
    this.defaultDepth = SearchDepth.standard,
    WikiSearchSource? wikiSearch,
  }) : _wikiSearch = wikiSearch;

  @override
  Future<List<MemorySearchResult>> search(String query, {int limit = 10, String userId = 'owner'}) async {
    if (!manager.isRunning) {
      _log.fine('QMD not running — falling back to FTS5');
      return fallback.search(query, limit: limit, userId: userId);
    }

    try {
      final results = await manager.query(query, depth: defaultDepth.value, limit: limit);

      final wiki = await _wikiSearch?.search(query, limit: limit) ?? const <MemorySearchResult>[];
      final raw = results.map((r) {
        // QMD relevance is higher-is-better; the merged list and the FTS5
        // fallback both sort ascending (lower-is-better, matching wiki/bm25
        // sentinels). Negate so a more relevant QMD row sorts ahead of a less
        // relevant one and below wiki-backed results.
        return MemorySearchResult(
          text: r['text'] as String? ?? r['content'] as String? ?? '',
          source: r['source'] as String? ?? r['path'] as String? ?? 'qmd',
          category: r['category'] as String?,
          score: -((r['score'] as num?)?.toDouble() ?? 0.0),
        );
      });
      final combined = [...wiki, ...raw]..sort((a, b) => a.score.compareTo(b.score));
      return combined.take(limit).toList();
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
