import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show MemoryResourceLimits;

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

  /// Runs one query only while the derived index remains current.
  static Future<({T? result, int? canonicalRevision, String? reason})> queryCurrentIndex<T>({
    required Future<T> Function() query,
    SearchIndexHealthProbe? indexHealthProbe,
  }) async {
    if (indexHealthProbe == null) {
      try {
        return (result: await query(), canonicalRevision: null, reason: null);
      } on Object {
        return (result: null, canonicalRevision: null, reason: 'searchFailure');
      }
    }

    late final IndexHealthEvidence before;
    try {
      before = await indexHealthProbe();
    } on Object {
      return (result: null, canonicalRevision: null, reason: 'indexHealthUnavailable');
    }
    if (!before.isCurrent(before.canonicalRevision, before.canonicalFingerprint)) {
      return (result: null, canonicalRevision: before.canonicalRevision, reason: 'indexNotCurrent');
    }

    T? result;
    Object? queryFailure;
    try {
      result = await query();
    } on Object catch (error) {
      queryFailure = error;
    }

    late final IndexHealthEvidence after;
    try {
      after = await indexHealthProbe();
    } on Object {
      return (result: null, canonicalRevision: before.canonicalRevision, reason: 'indexHealthUnavailable');
    }
    if (!after.isCurrent(after.canonicalRevision, after.canonicalFingerprint)) {
      return (result: null, canonicalRevision: after.canonicalRevision, reason: 'indexNotCurrent');
    }
    final unchanged =
        before.canonicalRevision == after.canonicalRevision &&
        before.canonicalFingerprint == after.canonicalFingerprint &&
        before.indexRevision == after.indexRevision &&
        before.indexFingerprint == after.indexFingerprint;
    if (!unchanged) {
      return (result: null, canonicalRevision: after.canonicalRevision, reason: 'indexChangedDuringSearch');
    }
    return queryFailure == null
        ? (result: result, canonicalRevision: after.canonicalRevision, reason: null)
        : (result: null, canonicalRevision: after.canonicalRevision, reason: 'searchFailure');
  }

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
    if (includesPersonal) {
      MemorySearchOutcome? queried;
      final guarded = await queryCurrentIndex(
        query: () async => queried = await _personal.search(query, limit: outputLimit, userId: userId, layers: layers),
        indexHealthProbe: _indexHealthProbe,
      );
      canonicalRevision = guarded.canonicalRevision ?? guarded.result?.canonicalRevision;
      if (guarded.result case final result?) {
        personal = result;
      } else {
        final attempted = queried;
        personal = _degradedPersonal(
          MemorySearchOutcome(
            results: const [],
            degradedLayers: attempted?.degradedLayers ?? const [],
            degradations: attempted?.degradations ?? const [],
            canonicalRevision: canonicalRevision,
          ),
          guarded.reason!,
        );
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
