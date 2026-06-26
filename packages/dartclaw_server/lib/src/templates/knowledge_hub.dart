import '../knowledge/knowledge_hub_service.dart';
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
  final String attributionHtml;

  const KnowledgeHubItemView({
    required this.layerClass,
    required this.layerLabel,
    required this.title,
    required this.snippet,
    required this.sourceHref,
    required this.sourceLabel,
    required this.attributionHtml,
  });
}

/// Renders the full read-only knowledge hub page.
String knowledgeHubTemplate({
  required KnowledgeHubResult result,
  required List<KnowledgeHubItemView> items,
  required SidebarData sidebarData,
  required List<NavItem> navItems,
  String bannerHtml = '',
  String appName = 'DartClaw',
}) {
  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);
  final topbar = pageTopbarTemplate(title: 'Knowledge Hub');
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
          'attributionHtml': item.attributionHtml,
        },
    ],
    'layerChips': [
      for (final layer in KnowledgeHubLayer.values)
        {
          'label': layer.label,
          'href': _knowledgeHref(query, layer: layer, page: null),
          'className': layer == query.layer ? 'filter-chip filter-chip--active' : 'filter-chip',
        },
    ],
    'layerSummaries': [
      for (final layer in KnowledgeHubLayer.searchable)
        {'label': layer.label, 'count': '${result.layerCounts[layer] ?? 0}'},
    ],
    'hasFailedLayers': result.failedLayers.isNotEmpty,
    'failedLayerNames': result.failedLayers.map((layer) => layer.label.toUpperCase()).join(', '),
    'emptyMessage': _emptyMessage(query.layer, query.query),
    'hasQuery': query.query.isNotEmpty,
    'hasPagination': result.totalPages > 1,
    'pageLabel': 'Page ${query.page} of ${result.totalPages}',
    'hasPreviousPage': result.hasPreviousPage,
    'hasNextPage': result.hasNextPage,
    'previousHref': _knowledgeHref(query, page: query.page - 1),
    'nextHref': _knowledgeHref(query, page: query.page + 1),
  };
  if (bannerHtml.isNotEmpty) context['bannerHtml'] = bannerHtml;

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

String _emptyMessage(KnowledgeHubLayer layer, String query) {
  if (query.isNotEmpty) return 'No results for this filter. Broaden the query or switch layers.';
  return switch (layer) {
    KnowledgeHubLayer.wiki => 'No wiki pages yet.',
    KnowledgeHubLayer.kg => 'No facts extracted.',
    KnowledgeHubLayer.memory => 'Nothing remembered.',
    KnowledgeHubLayer.inbox => 'Inbox is clear.',
    KnowledgeHubLayer.all => 'No knowledge has been recorded yet.',
  };
}
