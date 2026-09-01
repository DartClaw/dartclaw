import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart'
    show ComposedSearchBackend, Fts5SearchBackend, MemoryService, TemporalKnowledgeGraphService, WikiSearchSource;
import 'package:dartclaw_core/dartclaw_core.dart' show MemoryCorpusService;
import 'package:shelf/shelf.dart';

import '../../knowledge/knowledge_hub_service.dart';
import '../../knowledge/knowledge_inbox_read_service.dart';
import '../../mcp/citation_packet.dart';
import '../../mcp/live_citation_source_resolver.dart';
import '../../templates/knowledge_hub.dart';
import '../../templates/source_attribution.dart';
import '../dashboard_page.dart';
import '../web_utils.dart';

/// Renders the read-only cross-layer knowledge hub.
class KnowledgeHubPage extends DashboardPage {
  static const navigationTitle = 'Knowledge';

  new({KnowledgeHubService? Function()? hubGetter, CitationSourceResolver? resolver})
    : _hubGetter = hubGetter,
      _resolver = resolver;

  final KnowledgeHubService? Function()? _hubGetter;
  final CitationSourceResolver? _resolver;

  @override
  String get route => '/knowledge';

  @override
  String get title => navigationTitle;

  @override
  String? get icon => 'database';

  @override
  String get navGroup => 'system';

  @override
  Future<Response> handler(Request request, PageContext context) async {
    final hub = _hubGetter?.call();
    if (hub == null) {
      return Response.internalServerError(
        body: 'Knowledge hub not available - workspace not configured',
        headers: htmlHeaders,
      );
    }

    final query = KnowledgeHubQuery(
      query: request.url.queryParameters['q'] ?? '',
      layer: KnowledgeHubLayer.fromQuery(request.url.queryParameters['layer']),
      page: int.tryParse(request.url.queryParameters['page'] ?? '') ?? 1,
    );
    final result = await hub.search(query);
    final resolver = _resolver ?? hub.sourceResolver ?? _resolverFor(hub, result);
    final itemViews = <KnowledgeHubItemView>[];
    for (var i = 0; i < result.items.length; i++) {
      final item = result.items[i];
      final sourceResolved = await resolver.resolves(item.sourceRef);
      itemViews.add(
        KnowledgeHubItemView(
          layerClass: 'layer-badge--${item.layer.wireName}',
          layerLabel: citationSourceRoleLabel(item.sourceRef).toUpperCase(),
          title: item.title,
          snippet: item.snippet,
          sourceHref: item.sourceHref,
          sourceLabel: item.sourceLabel,
          sourceResolved: sourceResolved,
          attributionHtml: await sourceAttributionFragment(
            sourceRef: item.sourceRef,
            marker: i + 1,
            resolver: resolver,
            excerpt: item.snippet,
            showLayerBadge: false,
            resolved: sourceResolved,
          ),
        ),
      );
    }

    final page = knowledgeHubTemplate(
      result: result,
      items: itemViews,
      sidebarData: await context.sidebar.build(),
      navItems: context.navItems(activePage: title),
      restartBannerHtml: context.restartBannerHtml(),
      appName: context.appName,
    );
    return Response.ok(page, headers: htmlHeaders);
  }
}

KnowledgeHubService knowledgeHubServiceForWorkspace({
  required String workspaceDir,
  required MemoryService memory,
  SearchBackend? searchBackend,
  MemoryCorpusService? memoryCorpus,
  required TemporalKnowledgeGraphService kg,
}) {
  final wiki = WikiSearchSource(workspaceDir: workspaceDir);
  final inbox = KnowledgeInboxReadService(workspaceDir: workspaceDir);
  final effectiveSearch =
      searchBackend ??
      ComposedSearchBackend(
        personal: Fts5SearchBackend(memoryService: memory),
        wiki: wiki,
      );
  return KnowledgeHubService(
    wiki: wiki,
    kg: kg,
    memory: memory,
    searchBackend: effectiveSearch,
    inbox: inbox,
    sourceResolver: memoryCorpus == null
        ? null
        : LiveCitationSourceResolver(corpus: memoryCorpus, wiki: wiki, kg: kg, inbox: inbox),
  );
}

CitationSourceResolver _resolverFor(KnowledgeHubService hub, KnowledgeHubResult result) {
  return CitationSourceIndexResolver(
    wikiLocators: _locators(result, KnowledgeHubLayer.wiki),
    memoryLocators: _locators(result, KnowledgeHubLayer.memory),
    inboxLocators: _locators(result, KnowledgeHubLayer.inbox),
    kgFactExists: hub.kg.factExists,
  );
}

Iterable<String> _locators(KnowledgeHubResult result, KnowledgeHubLayer layer) sync* {
  for (final item in result.items) {
    if (item.layer == layer) yield item.sourceRef.locator;
  }
}
