import 'package:dartclaw_core/dartclaw_core.dart'
    show
        MemoryResourceLimits,
        MemorySearchDegradation,
        MemorySearchOutcome,
        MemorySearchResult,
        SearchBackend,
        SearchResultLayer;

import 'wiki_search_source.dart';
import '../storage/index_reconciler.dart';

/// Reads persisted index health relative to one current canonical identity.
typedef SearchIndexHealthProbe = Future<IndexHealthEvidence> Function();

/// Request-level composition of personal-memory and native wiki retrieval.
final class ComposedSearchBackend implements SearchBackend {
  /// Hard output ceiling shared by retrieval surfaces.
  static const maxResults = MemoryResourceLimits.searchResults;

  final SearchBackend _personal;
  final WikiSearchSource _wiki;
  final SearchIndexHealthProbe? _indexHealthProbe;

  /// Creates the single composition owner for one configured search backend.
  new({required SearchBackend personal, required WikiSearchSource wiki, SearchIndexHealthProbe? indexHealthProbe})
    : _personal = personal,
      _wiki = wiki,
      _indexHealthProbe = indexHealthProbe;

  @override
  Future<MemorySearchOutcome> search(
    String query, {
    int limit = 10,
    String userId = 'owner',
    Set<SearchResultLayer>? layers,
  }) async {
    if (query.trim().isEmpty) return const MemorySearchOutcome(results: []);
    final outputLimit = limit.clamp(1, maxResults);

    var personal = const MemorySearchOutcome(results: <MemorySearchResult>[]);
    List<MemorySearchResult> wiki;
    var wikiDegradations = const <MemorySearchDegradation>[];
    int? canonicalRevision;
    final includesPersonal = layers == null || layers.contains(SearchResultLayer.memory);
    IndexHealthEvidence? before;
    var canQueryPersonal = includesPersonal;
    if (includesPersonal && _indexHealthProbe != null) {
      try {
        before = await _indexHealthProbe();
        canonicalRevision = before.canonicalRevision;
        if (!before.isCurrent(before.canonicalRevision, before.canonicalFingerprint)) {
          canQueryPersonal = false;
          personal = _degradedPersonal(personal, 'indexNotCurrent');
        }
      } on Object {
        canQueryPersonal = false;
        personal = _degradedPersonal(personal, 'indexHealthUnavailable');
      }
    }
    if (canQueryPersonal) {
      try {
        personal = await _personal.search(query, limit: outputLimit, userId: userId, layers: layers);
        canonicalRevision ??= personal.canonicalRevision;
      } on Object {
        personal = _degradedPersonal(personal, 'searchFailure');
      }
      if (_indexHealthProbe != null && before != null) {
        try {
          final after = await _indexHealthProbe();
          canonicalRevision = after.canonicalRevision;
          final current = after.isCurrent(after.canonicalRevision, after.canonicalFingerprint);
          final unchanged =
              before.canonicalRevision == after.canonicalRevision &&
              before.canonicalFingerprint == after.canonicalFingerprint &&
              before.indexRevision == after.indexRevision &&
              before.indexFingerprint == after.indexFingerprint;
          if (!current || !unchanged) {
            personal = _degradedPersonal(
              MemorySearchOutcome(
                results: const [],
                degradedLayers: personal.degradedLayers,
                degradations: personal.degradations,
                canonicalRevision: canonicalRevision,
              ),
              current ? 'indexChangedDuringSearch' : 'indexNotCurrent',
            );
          }
        } on Object {
          personal = _degradedPersonal(
            MemorySearchOutcome(
              results: const [],
              degradedLayers: personal.degradedLayers,
              degradations: personal.degradations,
              canonicalRevision: canonicalRevision,
            ),
            'indexHealthUnavailable',
          );
        }
      }
    }
    if (layers != null && !layers.contains(SearchResultLayer.wiki)) {
      wiki = const [];
    } else {
      try {
        final scan = await _wiki.searchScan(query);
        wiki = scan.results;
        wikiDegradations = scan.degradations;
        if (scan.degraded) {
          personal = MemorySearchOutcome(
            results: personal.results,
            degradedLayers: [
              ...{...personal.degradedLayers, 'wiki'},
            ],
            degradations: personal.degradations,
            canonicalRevision: personal.canonicalRevision,
          );
        }
      } on Object {
        wiki = const [];
        personal = MemorySearchOutcome(
          results: personal.results,
          degradedLayers: [
            ...{...personal.degradedLayers, 'wiki'},
          ],
          degradations: [
            ...personal.degradations,
            const MemorySearchDegradation(layer: 'wiki', reason: 'searchFailure'),
          ],
          canonicalRevision: personal.canonicalRevision,
        );
      }
    }

    final wikiByPath = {for (final result in wiki) _normalizedNativePath(result.locator): result};
    final candidates = <MemorySearchResult>[
      for (final result in wiki)
        if (layers == null || layers.contains(SearchResultLayer.wiki)) result,
    ];
    for (final result in personal.results) {
      final nativePath = _normalizedNativePath(result.locator);
      if (nativePath.startsWith('wiki/') && wikiByPath.containsKey(nativePath)) {
        continue;
      }
      if (layers == null || layers.contains(_layerFor(result))) candidates.add(result);
    }
    candidates.sort(_compareResults);
    final seen = <String>{};
    return MemorySearchOutcome(
      results: candidates
          .where((result) => seen.add('${result.role}:${result.locator}'))
          .take(outputLimit)
          .toList(growable: false),
      degradedLayers: [...personal.degradedLayers.toSet()],
      degradations: [...personal.degradations, ...wikiDegradations],
      canonicalRevision: canonicalRevision,
    );
  }

  @override
  Future<MemorySearchResult?> resolve(String locator, {String userId = 'owner'}) async {
    final personal = await _personal.resolve(locator, userId: userId);
    return personal ?? _wiki.resolve(locator);
  }

  @override
  Future<void> indexAfterWrite() => _personal.indexAfterWrite();

  static int _compareResults(MemorySearchResult left, MemorySearchResult right) {
    final byScore = left.score.compareTo(right.score);
    if (byScore != 0) return byScore;
    final byRole = left.role.compareTo(right.role);
    return byRole != 0 ? byRole : left.locator.compareTo(right.locator);
  }

  static String _normalizedNativePath(String locator) {
    final uri = Uri.tryParse(locator);
    final path = uri?.scheme == 'qmd' ? uri!.pathSegments.join('/') : locator;
    return path.replaceFirst(RegExp(r'^\./'), '').replaceAll('\\', '/');
  }

  static SearchResultLayer _layerFor(MemorySearchResult result) =>
      result.role == 'wiki' ? SearchResultLayer.wiki : SearchResultLayer.memory;

  static MemorySearchOutcome _degradedPersonal(MemorySearchOutcome outcome, String reason) => MemorySearchOutcome(
    results: outcome.results,
    degradedLayers: [
      ...{...outcome.degradedLayers, 'memory'},
    ],
    degradations: [
      ...outcome.degradations,
      if (!outcome.degradations.any((item) => item.layer == 'memory' && item.reason == reason))
        MemorySearchDegradation(layer: 'memory', reason: reason),
    ],
    canonicalRevision: outcome.canonicalRevision,
  );
}
