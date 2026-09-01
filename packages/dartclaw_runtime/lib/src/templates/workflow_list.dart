import 'components.dart';
import 'helpers.dart';
import 'layout.dart';
import 'loader.dart';
import 'sidebar.dart';
import 'topbar.dart';

import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowSummary;

List<Map<String, dynamic>> workflowDefinitionViewModels(List<WorkflowSummary> definitions) => definitions
    .map(
      (definition) => {
        'name': definition.name,
        'description': definition.description,
        'stepCount': definition.stepCount,
        'hasLoops': definition.hasLoops,
        'errorId': 'workflow-error-${definition.name}',
        'projectSelectId': 'workflow-project-${definition.name}',
        'variableInputs': [
          for (final entry in definition.variables.entries)
            {
              'id': 'workflow-var-${definition.name}-${entry.key}',
              'inputName': 'var_${entry.key}',
              'name': entry.key,
              'label': titleCase(entry.key),
              'description': entry.value.description,
              'placeholder': entry.value.description,
              'required': entry.value.required,
              'defaultValue': entry.value.defaultValue ?? '',
            },
        ],
      },
    )
    .toList();

String workflowDefinitionsFragment({
  required List<Map<String, dynamic>> definitions,
  required List<Map<String, dynamic>> projectOptions,
}) => templateLoader.trellis.renderFragment(
  templateLoader.source('workflow_list'),
  fragment: 'workflowDefinitions',
  context: {
    'definitions': definitions,
    'hasDefinitions': definitions.isNotEmpty,
    'projectOptions': projectOptions,
    'hasProjects': projectOptions.isNotEmpty,
    'emptyDefinitionsHtml': emptyStateTemplate(
      title: 'No workflows available',
      body: 'Add a workflow definition to launch it here.',
    ),
  },
);

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
  required List<Map<String, dynamic>> projectOptions,
  required Map<String, dynamic> filters,
  String restartBannerHtml = '',
  String appName = 'DartClaw',
}) {
  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);
  final topbar = pageTopbarTemplate(title: 'Workflows', restartBannerHtml: restartBannerHtml);

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
    return {'value': value, 'label': titleCase(value), 'active': value == activeStatus, 'href': href};
  }).toList();

  final definitionOptions = (filters['definitionOptions'] as List? ?? []).map((d) {
    final value = d.toString();
    return {'value': value, 'label': value, 'selected': value == activeDefinition};
  }).toList();

  final body = templateLoader.trellis.render(templateLoader.source('workflow_list'), {
    'sidebar': sidebar,
    'topbar': topbar,
    'runs': runs,
    'hasRuns': runs.isNotEmpty,
    'definitions': definitions,
    'hasDefinitions': definitions.isNotEmpty,
    'projectOptions': projectOptions,
    'hasProjects': projectOptions.isNotEmpty,
    'emptyDefinitionsHtml': emptyStateTemplate(
      title: 'No workflows available',
      body: 'Add a workflow definition to launch it here.',
    ),
    'filters': filters,
    'statusOptions': statusOptions,
    'definitionOptions': definitionOptions,
    'activeStatusFilter': activeStatus == 'all' ? null : activeStatus,
    'emptyRunsHtml': emptyStateTemplate(
      title: 'No workflow runs found',
      body: 'Adjust the filters or launch an available workflow.',
      actionHtml: '<a class="btn btn-primary" href="/workflows">Clear filters</a>',
    ),
  });

  return layoutTemplate(title: 'Workflows', body: body, scripts: standardShellScripts());
}
