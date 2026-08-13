import '../knowledge/knowledge_hub_service.dart';
import 'components.dart';
import 'layout.dart';
import 'loader.dart';
import 'sidebar.dart';
import 'topbar.dart';

final class KnowledgeHubItemView {
  final String layerClass;
  final String layerLabel;
  final String title;
  final String snippet;
  final String sourceHref;
  final String sourceLabel;
  final bool sourceResolved;
  final String attributionHtml;

  const KnowledgeHubItemView({
    required this.layerClass,
    required this.layerLabel,
    required this.title,
    required this.snippet,
    required this.sourceHref,
    required this.sourceLabel,
    required this.sourceResolved,
    required this.attributionHtml,
  });
}

/// Renders the full read-only knowledge hub page.
String knowledgeHubTemplate({
  required KnowledgeHubResult result,
  required List<KnowledgeHubItemView> items,
  required SidebarData sidebarData,
  required List<NavItem> navItems,
  String restartBannerHtml = '',
  String appName = 'DartClaw',
}) {
  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);
  final topbar = pageTopbarTemplate(title: 'Knowledge Hub', restartBannerHtml: restartBannerHtml);
  final query = result.query;
  final context = <String, dynamic>{
    'sidebar': sidebar,
    'topbar': topbar,
    'query': query.query,
    'activeLayer': query.layer.wireName,
    'readOnlyMarker': 'READ-ONLY',
    'hasItems': items.isNotEmpty,
    'items': [
      for (final item in items)
        {
          'layerClass': item.layerClass,
          'layerLabel': item.layerLabel,
          'title': item.title,
          'snippet': item.snippet,
          'sourceHref': item.sourceHref,
          'sourceLabel': item.sourceLabel,
          'sourceResolved': item.sourceResolved,
          'attributionHtml': item.attributionHtml,
        },
    ],
    'layerChips': [
      for (final layer in KnowledgeHubLayer.values)
        {
          'label': layer.label,
          'href': _knowledgeHref(query, layer: layer, page: null),
          'current': layer == query.layer ? 'page' : null,
        },
    ],
    'layerSummaries': [
      for (final layer in KnowledgeHubLayer.searchable)
        {
          'label': layer.label,
          'count': '${result.layerCounts[layer] ?? 0}',
          'failed': result.failedLayers.contains(layer),
          'cardClass': result.failedLayers.contains(layer) ? 'card-metric--warning' : null,
        },
    ],
    'hasFailedLayers': result.failedLayers.isNotEmpty,
    'failedLayerNames': result.failedLayers.map((layer) => layer.label.toUpperCase()).join(', '),
    'emptyStateHtml': _emptyStateHtml(query.layer, query.query),
    'hasPagination': result.totalPages > 1,
    'pageLabel': 'Page ${query.page} of ${result.totalPages}',
    'hasPreviousPage': result.hasPreviousPage,
    'hasNextPage': result.hasNextPage,
    'previousHref': _knowledgeHref(query, page: query.page - 1),
    'nextHref': _knowledgeHref(query, page: query.page + 1),
  };

  final body = templateLoader.trellis.render(templateLoader.source('knowledge_hub'), context);
  return layoutTemplate(title: 'Knowledge Hub', body: body, appName: appName, scripts: standardShellScripts());
}

String _knowledgeHref(KnowledgeHubQuery query, {KnowledgeHubLayer? layer, int? page}) {
  final targetLayer = layer ?? query.layer;
  final params = <String, String>{
    if (query.query.isNotEmpty) 'q': query.query,
    if (targetLayer != KnowledgeHubLayer.all) 'layer': targetLayer.wireName,
    if (page != null) 'page': '$page',
  };
  return params.isEmpty ? '/knowledge' : Uri(path: '/knowledge', queryParameters: params).toString();
}

String _emptyStateHtml(KnowledgeHubLayer layer, String query) {
  final (title, body) = _emptyCopy(layer, query);
  return emptyStateTemplate(title: title, body: body);
}

(String, String) _emptyCopy(KnowledgeHubLayer layer, String query) {
  if (query.isNotEmpty) {
    return ('No results', 'Nothing matched this query in the selected layer. Broaden it or switch layers.');
  }
  return switch (layer) {
    KnowledgeHubLayer.wiki => ('No wiki pages yet', 'Markdown files under the workspace wiki directory appear here.'),
    KnowledgeHubLayer.kg => ('No facts extracted', 'Temporal facts appear here once the knowledge graph records them.'),
    KnowledgeHubLayer.memory => (
      'Nothing remembered',
      'Durable facts and preferences appear here as sessions capture them.',
    ),
    KnowledgeHubLayer.inbox => ('Inbox is clear', 'Captured items awaiting triage appear here.'),
    KnowledgeHubLayer.all => (
      'No knowledge recorded yet',
      'Wiki pages, graph facts, memories and inbox items appear here as they are captured.',
    ),
  };
}
