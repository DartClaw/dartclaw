import 'package:dartclaw_storage/dartclaw_storage.dart'
    show MemoryService, TemporalKnowledgeGraphService, WikiSearchSource;
import 'package:shelf/shelf.dart';

import '../../knowledge/knowledge_hub_service.dart';
import '../../knowledge/knowledge_inbox_service.dart';
import '../../mcp/citation_packet.dart';
import '../../templates/knowledge_hub.dart';
import '../../templates/source_attribution.dart';
import '../dashboard_page.dart';
import '../web_utils.dart';

/// Renders the read-only cross-layer knowledge hub.
class KnowledgeHubPage extends DashboardPage {
  KnowledgeHubPage({KnowledgeHubService? Function()? hubGetter, CitationSourceResolver? resolver})
    : _hubGetter = hubGetter,
      _resolver = resolver;

  final KnowledgeHubService? Function()? _hubGetter;
  final CitationSourceResolver? _resolver;

  @override
  String get route => '/knowledge';

  @override
  String get title => 'Knowledge';

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
    final resolver = _resolver ?? _resolverFor(hub, result);
    final itemViews = <KnowledgeHubItemView>[];
    for (var i = 0; i < result.items.length; i++) {
      final item = result.items[i];
      itemViews.add(
        KnowledgeHubItemView(
          layerClass: 'layer-badge--${item.layer.wireName}',
          layerLabel: item.layer.label.toUpperCase(),
          title: item.title,
          snippet: item.snippet,
          sourceHref: item.sourceHref,
          sourceLabel: item.sourceLabel,
          attributionHtml: await sourceAttributionFragment(
            sourceRef: item.sourceRef,
            marker: i + 1,
            resolver: resolver,
            excerpt: item.snippet,
          ),
        ),
      );
    }

    final page = knowledgeHubTemplate(
      result: result,
      items: itemViews,
      sidebarData: await context.sidebar.build(),
      navItems: context.navItems(activePage: title),
      bannerHtml: context.restartBannerHtml(),
      appName: context.appDisplay.name,
    );
    return Response.ok(page, headers: htmlHeaders);
  }
}

KnowledgeHubService knowledgeHubServiceForWorkspace({
  required String workspaceDir,
  required MemoryService memory,
  required TemporalKnowledgeGraphService kg,
}) {
  return KnowledgeHubService(
    wiki: WikiSearchSource(workspaceDir: workspaceDir),
    kg: kg,
    memory: memory,
    inbox: KnowledgeInboxReadService(workspaceDir: workspaceDir),
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
