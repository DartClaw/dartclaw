import 'package:dartclaw_storage/dartclaw_storage.dart'
    show KnowledgeContradiction, KnowledgeFact, TemporalKnowledgeGraphService, normalizeKnowledgeEntity;
import 'package:shelf/shelf.dart';

import '../../mcp/citation_packet.dart';
import '../../templates/kg_timeline.dart';
import '../../templates/source_attribution.dart';
import '../dashboard_page.dart';
import '../web_utils.dart';

/// Renders the read-only temporal KG timeline.
class KgTimelinePage extends DashboardPage {
  KgTimelinePage({TemporalKnowledgeGraphService? Function()? kgGetter, CitationSourceResolver? resolver})
    : _kgGetter = kgGetter,
      _resolver = resolver;

  final TemporalKnowledgeGraphService? Function()? _kgGetter;
  final CitationSourceResolver? _resolver;

  @override
  String get route => '/knowledge/timeline';

  @override
  String get title => 'Timeline';

  @override
  String? get icon => 'clock';

  @override
  String get navGroup => 'system';

  @override
  Future<Response> handler(Request request, PageContext context) async {
    final kg = _kgGetter?.call();
    if (kg == null) {
      return Response.internalServerError(
        body: 'KG timeline not available - knowledge graph not configured',
        headers: htmlHeaders,
      );
    }

    final sidebarData = await context.sidebar.build();
    final selectedCategory = _categoryParam(request);
    final asOf = _asOfParam(request);
    final resolver = _resolver ?? CitationSourceIndexResolver(kgFactExists: kg.factExists);

    try {
      final facts = kg.allFacts();
      final activeAsOfIds = asOf == null ? <int>{} : kg.allFacts(asOf: asOf).map((fact) => fact.id).toSet();
      final groups = await _buildTimelineGroups(
        facts: facts,
        contradictions: kg.openContradictions(),
        resolver: resolver,
        selectedCategory: selectedCategory,
        asOf: asOf,
        asOfInstant: asOf == null ? null : kg.parseAsOf(asOf),
        activeAsOfIds: activeAsOfIds,
      );
      final page = kgTimelineTemplate(
        categories: groups,
        sidebarData: sidebarData,
        navItems: context.navItems(activePage: title),
        selectedCategory: selectedCategory,
        asOf: asOf,
        bannerHtml: context.restartBannerHtml(),
        appName: context.appDisplay.name,
      );
      return Response.ok(page, headers: htmlHeaders);
    } on ArgumentError {
      final page = kgTimelineTemplate(
        categories: const [],
        sidebarData: sidebarData,
        navItems: context.navItems(activePage: title),
        selectedCategory: selectedCategory,
        asOf: asOf,
        errorMessage: 'invalid as-of timestamp',
        statusCode: 400,
        bannerHtml: context.restartBannerHtml(),
        appName: context.appDisplay.name,
      );
      return Response(400, body: page, headers: htmlHeaders);
    } catch (_) {
      final page = kgTimelineTemplate(
        categories: const [],
        sidebarData: sidebarData,
        navItems: context.navItems(activePage: title),
        selectedCategory: selectedCategory,
        asOf: asOf,
        errorMessage: 'Temporal KG query failed.',
        statusCode: 500,
        bannerHtml: context.restartBannerHtml(),
        appName: context.appDisplay.name,
      );
      return Response.internalServerError(body: page, headers: htmlHeaders);
    }
  }
}

String? _categoryParam(Request request) {
  final raw = request.url.queryParameters['category']?.trim();
  return raw == null || raw.isEmpty ? null : normalizeKnowledgeEntity(raw);
}

String? _asOfParam(Request request) {
  final raw = request.url.queryParameters['as_of']?.trim();
  return raw == null || raw.isEmpty ? null : raw;
}

Future<List<KgTimelineCategoryView>> _buildTimelineGroups({
  required List<KnowledgeFact> facts,
  required List<KnowledgeContradiction> contradictions,
  required CitationSourceResolver resolver,
  required String? selectedCategory,
  required String? asOf,
  required DateTime? asOfInstant,
  required Set<int> activeAsOfIds,
}) async {
  final conflictKeys = _conflictKeys(
    facts: facts,
    contradictions: contradictions,
    asOf: asOf,
    activeAsOfIds: activeAsOfIds,
  );
  final filtered = selectedCategory == null ? facts : facts.where((fact) => fact.entity == selectedCategory);
  final grouped = <String, List<KnowledgeFact>>{};
  for (final fact in filtered) {
    grouped.putIfAbsent(fact.entity, () => []).add(fact);
  }

  final categories = <KgTimelineCategoryView>[];
  for (final entry in grouped.entries) {
    final factViews = <KgTimelineFactView>[];
    for (final fact in entry.value) {
      final isConflict =
          conflictKeys.contains(_factKey(fact)) &&
          (asOf == null ? fact.invalidatedAt == null && fact.validTo == null : activeAsOfIds.contains(fact.id));
      final sourceRef = SourceRef(layer: CitationLayer.kg, locator: '${fact.id}', label: fact.source);
      final stateLabel = _stateLabel(fact, isConflict: isConflict, asOf: asOfInstant, activeAsOfIds: activeAsOfIds);
      factViews.add(
        KgTimelineFactView(
          id: fact.id,
          statement: '${fact.predicate}: ${fact.value}',
          validFrom: fact.validFrom,
          validTo: fact.validTo ?? 'ongoing',
          stateLabel: stateLabel,
          stateClass: 'kg-fact-card--$stateLabel',
          isConflict: isConflict,
          attributionHtml: await sourceAttributionFragment(sourceRef: sourceRef, marker: fact.id, resolver: resolver),
        ),
      );
    }
    categories.add(KgTimelineCategoryView(name: entry.key, facts: factViews));
  }
  return categories;
}

Set<String> _conflictKeys({
  required List<KnowledgeFact> facts,
  required List<KnowledgeContradiction> contradictions,
  required String? asOf,
  required Set<int> activeAsOfIds,
}) {
  if (asOf == null) {
    return contradictions.map((contradiction) => _factKey(contradiction.existing)).toSet();
  }

  final valuesByKey = <String, Set<String>>{};
  for (final fact in facts.where((fact) => activeAsOfIds.contains(fact.id))) {
    valuesByKey.putIfAbsent(_factKey(fact), () => <String>{}).add(fact.value);
  }
  return {
    for (final entry in valuesByKey.entries)
      if (entry.value.length > 1) entry.key,
  };
}

String _stateLabel(
  KnowledgeFact fact, {
  required bool isConflict,
  required DateTime? asOf,
  required Set<int> activeAsOfIds,
}) {
  if (asOf != null && DateTime.parse(fact.validFrom).toUtc().isAfter(asOf)) return 'not-yet-valid';
  if (isConflict) return 'contradicting';
  if (asOf != null && activeAsOfIds.contains(fact.id)) return 'active-as-of';
  if (fact.invalidatedAt != null || fact.validTo != null) return 'superseded';
  return 'active';
}

String _factKey(KnowledgeFact fact) => '${fact.entity}\u{1f}${fact.predicate}';
