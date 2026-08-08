import 'components.dart';
import 'layout.dart';
import 'loader.dart';
import 'sidebar.dart';
import 'topbar.dart';

/// Render-ready category group for the temporal KG timeline.
final class KgTimelineCategoryView {
  final String name;
  final List<KgTimelineFactView> facts;

  const KgTimelineCategoryView({required this.name, required this.facts});
}

/// Render-ready temporal KG fact card.
final class KgTimelineFactView {
  final int id;
  final String statement;
  final String validFrom;
  final String validTo;
  final String stateLabel;
  final String stateClass;
  final bool isConflict;
  final String attributionHtml;

  const KgTimelineFactView({
    required this.id,
    required this.statement,
    required this.validFrom,
    required this.validTo,
    required this.stateLabel,
    required this.stateClass,
    required this.isConflict,
    required this.attributionHtml,
  });
}

/// Renders the full read-only temporal KG timeline page.
String kgTimelineTemplate({
  required List<KgTimelineCategoryView> categories,
  required SidebarData sidebarData,
  required List<NavItem> navItems,
  String? selectedCategory,
  String? asOf,
  String? errorMessage,
  int? statusCode,
  String restartBannerHtml = '',
  String appName = 'DartClaw',
}) {
  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);
  final topbar = pageTopbarTemplate(title: 'KG Timeline', restartBannerHtml: restartBannerHtml);
  final context = <String, dynamic>{
    'sidebar': sidebar,
    'topbar': topbar,
    'selectedCategory': selectedCategory ?? '',
    'asOf': asOf ?? '',
    'hasAsOf': asOf != null && asOf.isNotEmpty,
    'hasError': errorMessage != null && errorMessage.isNotEmpty,
    'errorMessage': errorMessage ?? '',
    'statusCode': statusCode == null ? '' : '$statusCode',
    'hasCategories': categories.isNotEmpty,
    'emptyStateHtml': _emptyStateHtml(selectedCategory),
    'categories': categories
        .map(
          (category) => {
            'name': category.name,
            'count': '${category.facts.length}',
            'facts': category.facts
                .map(
                  (fact) => {
                    'id': 'fact-${fact.id}',
                    'statement': fact.statement,
                    'validFrom': fact.validFrom,
                    'validTo': fact.validTo,
                    'stateLabel': fact.stateLabel,
                    'stateClass': fact.stateClass,
                    'isConflict': fact.isConflict,
                    'attributionHtml': fact.attributionHtml,
                  },
                )
                .toList(),
          },
        )
        .toList(),
  };

  final body = templateLoader.trellis.render(templateLoader.source('kg_timeline'), context);
  return layoutTemplate(title: 'KG Timeline', body: body, appName: appName, scripts: standardShellScripts());
}

String _emptyStateHtml(String? selectedCategory) {
  final filtered = selectedCategory != null && selectedCategory.isNotEmpty;
  return emptyStateTemplate(
    title: filtered ? 'No facts in this category' : 'No temporal facts yet',
    body: filtered
        ? 'Nothing was recorded for this category in the selected window. Reset the filters or try another category.'
        : 'Facts with a validity window appear here once the knowledge graph records them.',
    actionHtml: '<a class="btn btn-primary" href="/knowledge">Browse the knowledge hub</a>',
  );
}
