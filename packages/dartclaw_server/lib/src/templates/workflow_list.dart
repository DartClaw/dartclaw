import 'helpers.dart';
import 'layout.dart';
import 'loader.dart';
import 'sidebar.dart';
import 'topbar.dart';

/// Renders the workflow management page with runs list, filters,
/// and definition browser.
///
/// [runs] and [definitions] are pre-computed view-model maps built by the
/// page handler. [filters] carries the active filter state.
String workflowListPageTemplate({
  required SidebarData sidebarData,
  required List<NavItem> navItems,
  required List<Map<String, dynamic>> runs,
  required List<Map<String, dynamic>> definitions,
  required Map<String, dynamic> filters,
  String bannerHtml = '',
  String appName = 'DartClaw',
}) {
  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);
  final topbar = pageTopbarTemplate(title: 'Workflows');

  final activeStatus = filters['activeStatus']?.toString() ?? 'all';
  final activeDefinition = filters['activeDefinition']?.toString();

  final statusOptions = (filters['statusOptions'] as List? ?? []).map((s) {
    final value = s.toString();
    final isAll = value == 'all';
    // Build href preserving definition filter when status changes.
    final String href;
    if (isAll) {
      href = activeDefinition != null
          ? '/workflows?definition=${Uri.encodeQueryComponent(activeDefinition)}'
          : '/workflows';
    } else {
      href = activeDefinition != null
          ? '/workflows?status=$value&definition=${Uri.encodeQueryComponent(activeDefinition)}'
          : '/workflows?status=$value';
    }
    return {
      'value': value,
      'label': titleCase(value),
      'active': value == activeStatus,
      'href': href,
    };
  }).toList();

  final definitionOptions = (filters['definitionOptions'] as List? ?? []).map((d) {
    final value = d.toString();
    return {
      'value': value,
      'label': value,
      'selected': value == activeDefinition,
    };
  }).toList();

  final body = templateLoader.trellis.render(
    templateLoader.source('workflow_list'),
    {
      'sidebar': sidebar,
      'topbar': topbar,
      'bannerHtml': bannerHtml.isNotEmpty ? bannerHtml : null,
      'runs': runs,
      'hasRuns': runs.isNotEmpty,
      'definitions': definitions,
      'hasDefinitions': definitions.isNotEmpty,
      'filters': filters,
      'statusOptions': statusOptions,
      'definitionOptions': definitionOptions,
    },
  );

  return layoutTemplate(title: 'Workflows', body: body);
}
