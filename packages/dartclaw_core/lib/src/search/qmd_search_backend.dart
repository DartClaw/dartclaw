import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart'
    show MemoryFileService, MemoryResourceLimitException, MemoryResourceLimits, MemoryRole;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'qmd_manager.dart';
import 'search_file_io.dart';

/// Search depth options for QMD queries.
enum SearchDepth {
  /// Lexical only (~26ms)
  fast('lex'),

  /// Lexical + vector (~200ms)
  standard('lex+vec'),

  /// Full query with reranking (5-8s)
  deep('query');

  /// Wire value used to select the QMD query strategy.
  final String value;
  new(this.value);

  /// Parses a [SearchDepth] from its config string.
  static SearchDepth fromString(String s) => switch (s) {
    'fast' => SearchDepth.fast,
    'deep' => SearchDepth.deep,
    _ => SearchDepth.standard,
  };
}

/// QMD-based search backend with FTS5 fallback.
///
/// Queries the QMD REST API for native hybrid matches and combines canonical
/// FTS5 results. Falls back entirely to FTS5 if QMD is unreachable.
class QmdSearchBackend implements SearchBackend {
  static final _log = Logger('QmdSearchBackend');

  /// QMD lifecycle manager used to issue queries.
  final QmdManager manager;

  /// Backend used when QMD is unreachable or fails.
  final SearchBackend fallback;

  /// Default search depth applied when callers do not override it.
  final SearchDepth defaultDepth;

  /// Creates a QMD-backed search backend with [fallback] as the FTS5 substitute.
  new({required this.manager, required this.fallback, this.defaultDepth = SearchDepth.standard});

  @override
  Future<MemorySearchOutcome> search(
    String query, {
    int limit = 10,
    String userId = 'owner',
    Set<SearchResultLayer>? layers,
  }) async {
    if (!manager.isRunning) {
      _log.fine('QMD not running — falling back to FTS5');
      return _degradedFallback(query, limit: limit, userId: userId, layers: layers);
    }

    try {
      final results = await manager.query(query, depth: defaultDepth.value, limit: limit);
      MemorySearchOutcome indexed;
      try {
        indexed = await fallback.search(query, limit: limit, userId: userId, layers: layers);
      } on Object {
        indexed = const MemorySearchOutcome(results: [], degradedLayers: ['memory']);
      }
      final raw = <MemorySearchResult>[];
      for (final result in results) {
        final source = result['source'] as String? ?? result['path'] as String? ?? 'qmd';
        if (_isCanonicalCorpusSource(source)) continue;
        final score = -((result['score'] as num?)?.toDouble() ?? 0.0);
        final mapped = MemorySearchResult(
          text: result['text'] as String? ?? result['content'] as String? ?? '',
          source: source,
          category: result['category'] as String?,
          score: score,
          role: _roleForSource(source),
          provenance: 'qmd',
          locator: _qmdLocator(source),
        );
        if (layers == null || layers.contains(_layerFor(mapped))) raw.add(mapped);
      }
      final combined = [...indexed.results, ...raw]..sort((a, b) => a.score.compareTo(b.score));
      final seen = <String>{};
      return MemorySearchOutcome(
        results: combined.where((result) => seen.add('${result.role}:${result.locator}')).take(limit).toList(),
        degradedLayers: indexed.degradedLayers,
        degradations: indexed.degradations,
      );
    } catch (e) {
      _log.warning('QMD search failed — falling back to FTS5: $e');
      return _degradedFallback(query, limit: limit, userId: userId, layers: layers);
    }
  }

  Future<MemorySearchOutcome> _degradedFallback(
    String query, {
    required int limit,
    required String userId,
    required Set<SearchResultLayer>? layers,
  }) async {
    final outcome = await fallback.search(query, limit: limit, userId: userId, layers: layers);
    return MemorySearchOutcome(
      results: outcome.results,
      degradedLayers: [
        ...{...outcome.degradedLayers, 'qmd'},
      ],
      degradations: outcome.degradations,
    );
  }

  @override
  Future<MemorySearchResult?> resolve(String locator, {String userId = 'owner'}) async {
    final delegated = await fallback.resolve(locator, userId: userId);
    if (delegated != null) return delegated;
    final workspace = manager.workspaceDir;
    final uri = Uri.tryParse(locator);
    if (workspace == null || uri?.scheme != 'qmd' || uri!.hasAuthority || uri.hasQuery || uri.hasFragment) {
      return null;
    }
    final relative = _sourcePath(locator);
    if (!_isQmdSource(relative) || locator != _qmdLocator(relative)) return null;
    final root = Directory(p.absolute(workspace));
    final file = File(p.normalize(p.join(root.path, relative)));
    if (!isRegularFileWithinRoot(root, file)) return null;
    final size = file.lengthSync();
    if (size > MemoryResourceLimits.sourceBytes) {
      throw MemoryResourceLimitException(
        role: _memoryRoleForSource(relative),
        locator: locator,
        observedBytes: size,
        limitBytes: MemoryResourceLimits.sourceBytes,
      );
    }
    final text = MemoryFileService.readRegularFile(file, maxBytes: MemoryResourceLimits.sourceBytes);
    if (text == null) return null;
    return MemorySearchResult(
      text: text,
      source: locator,
      score: 0,
      role: _roleForSource(relative),
      provenance: 'qmd',
      locator: locator,
    );
  }

  @override
  Future<void> indexAfterWrite() async {
    if (!manager.isRunning) return;
    try {
      await manager.triggerIndex();
    } catch (e) {
      _log.warning('QMD indexing failed: $e');
      rethrow;
    }
  }

  static String _sourcePath(String source) {
    final uri = Uri.tryParse(source);
    final path = uri?.scheme == 'qmd' ? uri!.pathSegments.join('/') : source;
    return path.replaceFirst(RegExp(r'^\./'), '').replaceAll('\\', '/');
  }

  static String _qmdLocator(String source) => Uri(scheme: 'qmd', path: '/${_sourcePath(source)}').toString();

  static bool _isQmdSource(String source) {
    final path = _sourcePath(source);
    return path.endsWith('.md') && !_isCanonicalCorpusSource(path);
  }

  static bool _isAuditSource(String source) => _sourcePath(source) == 'MEMORY.audit.md';

  static bool _isCanonicalCorpusSource(String source) {
    final path = _sourcePath(source);
    return _isAuditSource(source) ||
        path == 'MEMORY.md' ||
        path == 'MEMORY.archive.md' ||
        path == 'learnings.md' ||
        path.startsWith('memory/topics/') ||
        RegExp(r'^memory/\d{4}-\d{2}-\d{2}\.md$').hasMatch(path);
  }

  static String _roleForSource(String source) {
    final path = _sourcePath(source);
    if (path.startsWith('wiki/')) return 'wiki';
    if (const ['inbox/', 'processed/', 'quarantine/', 'skipped/'].any(path.startsWith)) {
      return 'knowledge-inbox';
    }
    if (path == 'learnings.md') return 'learning';
    if (path == 'MEMORY.archive.md') return 'archive';
    if (RegExp(r'^memory/\d{4}-\d{2}-\d{2}\.md$').hasMatch(path)) return 'observation';
    if (path.startsWith('memory/topics/')) return 'topic';
    return 'qmd';
  }

  static MemoryRole _memoryRoleForSource(String source) =>
      _roleForSource(source) == 'wiki' ? MemoryRole.wiki : MemoryRole.topic;

  static SearchResultLayer _layerFor(MemorySearchResult result) =>
      result.role == 'wiki' ? SearchResultLayer.wiki : SearchResultLayer.memory;
}
