import 'package:dartclaw_models/dartclaw_models.dart' show Project, ProjectStatus, PrStrategy;

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
  String bannerHtml = '',
  String appName = 'DartClaw',
}) {
  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);
  final topbar = pageTopbarTemplate(title: 'Projects');

  final projectMaps = projects.map((p) => _projectToMap(p, defaultProject: defaultProject)).toList();

  final body = templateLoader.trellis.render(templateLoader.source('projects'), {
    'sidebar': sidebar,
    'topbar': topbar,
    'bannerHtml': bannerHtml.isNotEmpty ? bannerHtml : null,
    'hasProjects': projects.isNotEmpty,
    'projects': projectMaps,
    'addProjectDialogHtml': addProjectDialogHtml(),
  });

  return layoutTemplate(title: 'Projects', body: body, appName: appName);
}

Map<String, dynamic> _projectToMap(Project project, {Project? defaultProject}) {
  final isLocal = project.id == '_local';
  final isEditable = !project.configDefined && !isLocal;
  final isDefault = defaultProject != null && project.id == defaultProject.id;

  return {
    'id': project.id,
    'name': project.name,
    'remoteUrl': project.remoteUrl,
    'displayUrl': _truncateUrl(project.remoteUrl, 60),
    'defaultBranch': project.defaultBranch,
    'credentialsRef': project.credentialsRef ?? '',
    'statusLabel': _titleCase(project.status.name),
    'statusBadgeClass': _statusBadgeClass(project.status),
    'lastFetchDisplay': _formatLastFetch(project.lastFetchAt),
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

String _titleCase(String value) {
  if (value.isEmpty) return value;
  return value[0].toUpperCase() + value.substring(1);
}

String _truncateUrl(String url, int maxLength) {
  if (url.length <= maxLength) return url;
  return '${url.substring(0, maxLength - 1)}\u2026';
}

String _formatLastFetch(DateTime? lastFetchAt) {
  if (lastFetchAt == null) return 'Never';
  final diff = DateTime.now().difference(lastFetchAt);
  if (diff.inDays > 0) return '${diff.inDays}d ago';
  if (diff.inHours > 0) return '${diff.inHours}h ago';
  if (diff.inMinutes > 0) return '${diff.inMinutes}m ago';
  return 'just now';
}
