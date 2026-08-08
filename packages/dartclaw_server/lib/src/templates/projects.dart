import 'package:dartclaw_config/dartclaw_config.dart' show PrStrategy, Project, ProjectStatus;
import 'package:dartclaw_core/dartclaw_core.dart' show formatLocalDateTime;

import 'components.dart';
import 'helpers.dart';
import 'layout.dart';
import 'loader.dart';
import 'project_form.dart';
import 'sidebar.dart';
import 'topbar.dart';

/// Renders the projects management page.
String projectsPageTemplate({
  required SidebarData sidebarData,
  required List<NavItem> navItems,
  required List<Project> projects,
  Project? defaultProject,
  String restartBannerHtml = '',
  String appName = 'DartClaw',
}) {
  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);
  final topbar = pageTopbarTemplate(title: 'Projects', restartBannerHtml: restartBannerHtml);

  final projectMaps = projects.map((p) => _projectToMap(p, defaultProject: defaultProject)).toList();
  final pageHeaderHtml = pageHeaderTemplate(
    subtitle: 'Repositories available to tasks and workflows.',
    actionsHtml:
        '<button class="btn btn-primary" type="button" data-icon="plus" data-project-dialog-open>Add Project</button>',
  );

  final body = templateLoader.trellis.render(templateLoader.source('projects'), {
    'sidebar': sidebar,
    'topbar': topbar,
    'hasProjects': projects.isNotEmpty,
    'projects': projectMaps,
    'pageHeaderHtml': pageHeaderHtml,
    'addProjectDialogHtml': addProjectDialogHtml(),
  });

  return layoutTemplate(title: 'Projects', body: body, appName: appName, scripts: standardShellScripts());
}

Map<String, dynamic> _projectToMap(Project project, {Project? defaultProject}) {
  final isLocal = project.id == '_local';
  final isEditable = !project.configDefined && !isLocal;
  final isDefault = defaultProject != null && project.id == defaultProject.id;

  return {
    'id': project.id,
    'name': project.name,
    'remoteUrl': project.remoteUrl,
    'displayUrl': truncate(project.remoteUrl, 60),
    'defaultBranch': project.defaultBranch,
    'credentialsRef': project.credentialsRef ?? '',
    'statusLabel': titleCase(project.status.name),
    'statusBadgeClass': _statusBadgeClass(project.status),
    'lastFetchDisplay': absentValue(
      formatLocalDateTime(project.lastFetchAt?.toIso8601String(), seconds: false, emptyPlaceholder: ''),
    ).value,
    'lastFetchAbsent': project.lastFetchAt == null,
    'lastFetchIso': project.lastFetchAt?.toIso8601String(),
    'isLocal': isLocal,
    'isConfigDefined': project.configDefined,
    'configDefinedLabel': project.configDefined ? 'Config' : 'Runtime',
    'isEditable': isEditable,
    'hasError': project.status == ProjectStatus.error,
    'errorMessage': project.errorMessage ?? '',
    'prStrategyLabel': _prStrategyLabel(project.pr.strategy),
    'prStrategy': project.pr.strategy.name,
    'prDraft': project.pr.draft,
    'prLabels': project.pr.labels.join(', '),
    'isDefault': isDefault,
  };
}

String _statusBadgeClass(ProjectStatus status) => switch (status) {
  ProjectStatus.ready => 'status-badge-success',
  ProjectStatus.cloning => 'status-badge-info',
  ProjectStatus.error => 'status-badge-error',
  ProjectStatus.stale => 'status-badge-warning',
};

String _prStrategyLabel(PrStrategy strategy) => switch (strategy) {
  PrStrategy.githubPr => 'GitHub PR',
  PrStrategy.branchOnly => 'Branch Only',
};
