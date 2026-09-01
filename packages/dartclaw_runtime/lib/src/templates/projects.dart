import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show formatLocalDateTime;

import 'components.dart';
import 'helpers.dart';
import 'layout.dart';
import 'loader.dart';
import 'sidebar.dart';
import 'topbar.dart';

/// The add/edit dialog's control values, as the operator last saw them.
///
/// A refused save re-renders the dialog from the submitted values, so what the
/// operator typed survives the round trip; an edit renders them from the stored
/// project instead.
typedef ProjectDialogValues = ({
  String remoteUrl,
  String name,
  String defaultBranch,
  String credentialsRef,
  String prStrategy,
  bool prDraft,
  String prLabels,
});

/// The values an empty Add Project dialog starts from.
const ProjectDialogValues projectDialogDefaults = (
  remoteUrl: '',
  name: '',
  defaultBranch: 'main',
  credentialsRef: '',
  prStrategy: 'branchOnly',
  prDraft: true,
  prLabels: '',
);

/// Reads [project] into the dialog's control values.
ProjectDialogValues projectDialogValuesOf(Project project) => (
  remoteUrl: project.remoteUrl,
  name: project.name,
  defaultBranch: project.defaultBranch,
  credentialsRef: project.credentialsRef ?? '',
  prStrategy: project.pr.strategy.name,
  prDraft: project.pr.draft,
  prLabels: project.pr.labels.join(', '),
);

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

  final body = templateLoader.trellis.renderFragment(
    templateLoader.source('projects'),
    fragment: 'projects',
    context: {
      'sidebar': sidebar,
      'topbar': topbar,
      'contentHtml': projectsContentFragment(projects: projects, defaultProject: defaultProject),
      'dialogHostHtml': projectDialogHostFragment(),
    },
  );

  return layoutTemplate(title: 'Projects', body: body, appName: appName, scripts: standardShellScripts());
}

/// Renders `#projects-content`: the page header, the project cards and the
/// empty state — the surface every project mutation swaps.
///
/// [outOfBand] marks the fragment for an `hx-swap-oob` ride-along, for a
/// response whose primary target is the dialog host.
String projectsContentFragment({required List<Project> projects, Project? defaultProject, bool outOfBand = false}) {
  return templateLoader.trellis.renderFragment(
    templateLoader.source('projects'),
    fragment: 'projectsContent',
    context: {
      'outOfBand': outOfBand ? 'true' : null,
      'pageHeaderHtml': pageHeaderTemplate(
        subtitle: 'Repositories available to tasks and workflows.',
        actionsHtml: _addProjectButtonHtml(),
      ),
      'hasProjects': projects.isNotEmpty,
      'projects': projects.map((p) => _projectToMap(p, defaultProject: defaultProject)).toList(),
      'emptyStateHtml': emptyStateTemplate(
        title: 'No projects registered',
        body: 'Add a project to run tasks against external repositories.',
        actionHtml: _addProjectButtonHtml(),
      ),
    },
  );
}

/// Renders `#project-dialog-host`.
///
/// With [values] the host carries the add/edit dialog; without them it is
/// empty, which *is* the close — a `<dialog>` leaving the document leaves the
/// browser top layer with it.
///
/// [projectId] switches the form between create and update. [errorMessage]
/// lands on the control [errorField] names, or in the form-level `.form-error`
/// when the refusal has no control of its own.
String projectDialogHostFragment({
  ProjectDialogValues? values,
  String? projectId,
  String? errorMessage,
  String? errorField,
}) {
  if (values == null) {
    return templateLoader.trellis.renderFragment(
      templateLoader.source('projects'),
      fragment: 'projectDialogHost',
      context: {'hasDialog': false},
    );
  }

  const inlineFields = {'name', 'remoteUrl', 'credentialsRef'};
  final inlineField = errorMessage != null && inlineFields.contains(errorField) ? errorField : null;
  String errorFor(String field) => inlineField == field ? errorMessage! : '';
  String? invalidFor(String field) => inlineField == field ? 'true' : null;

  return templateLoader.trellis.renderFragment(
    templateLoader.source('projects'),
    fragment: 'projectDialogHost',
    context: {
      'hasDialog': true,
      'submitUrl': projectId == null ? '/projects/create' : '${projectPath(projectId)}/update',
      'dialogTitle': projectId == null ? 'Add Project' : 'Edit Project',
      'submitLabel': projectId == null ? 'Add Project' : 'Save Changes',
      'remoteUrl': values.remoteUrl,
      'name': values.name,
      'defaultBranch': values.defaultBranch,
      'credentialsRef': values.credentialsRef,
      'prStrategyGithubPr': values.prStrategy == PrStrategy.githubPr.name,
      'prStrategyBranchOnly': values.prStrategy != PrStrategy.githubPr.name,
      'prDraft': values.prDraft,
      'prLabels': values.prLabels,
      'remoteUrlError': errorFor('remoteUrl'),
      'remoteUrlInvalid': invalidFor('remoteUrl'),
      'nameError': errorFor('name'),
      'nameInvalid': invalidFor('name'),
      'credentialsRefError': errorFor('credentialsRef'),
      'credentialsRefInvalid': invalidFor('credentialsRef'),
      'formError': errorMessage != null && inlineField == null ? errorMessage : '',
    },
  );
}

/// The `/projects` sub-path owning [projectId]'s mutating routes.
String projectPath(String projectId) => '/projects/${Uri.encodeComponent(projectId)}';

String _addProjectButtonHtml() =>
    '<button class="btn btn-primary" type="button" data-icon="plus" '
    'hx-get="/projects/dialog" hx-target="#project-dialog-host" hx-swap="outerHTML">Add Project</button>';

Map<String, dynamic> _projectToMap(Project project, {Project? defaultProject}) {
  final isLocal = project.id == '_local';
  final isEditable = !project.configDefined && !isLocal;
  final isDefault = defaultProject != null && project.id == defaultProject.id;
  final path = projectPath(project.id);

  return {
    'id': project.id,
    'name': project.name,
    'displayUrl': truncate(project.remoteUrl, 60),
    'defaultBranch': project.defaultBranch,
    'statusLabel': titleCase(project.status.name),
    'statusBadgeClass': _statusBadgeClass(project.status),
    'lastFetchDisplay': absentValue(
      formatLocalDateTime(project.lastFetchAt?.toIso8601String(), seconds: false, emptyPlaceholder: ''),
    ).value,
    'lastFetchAbsent': project.lastFetchAt == null,
    'lastFetchIso': project.lastFetchAt?.toIso8601String(),
    'isLocal': isLocal,
    'configDefinedLabel': project.configDefined ? 'Config' : 'Runtime',
    'isEditable': isEditable,
    'hasError': project.status == ProjectStatus.error,
    'errorMessage': project.errorMessage ?? '',
    'prStrategyLabel': _prStrategyLabel(project.pr.strategy),
    'isDefault': isDefault,
    'fetchUrl': '$path/fetch',
    'editUrl': '$path/dialog',
    'removeUrl': '$path/delete',
    'removeConfirm': 'Remove project "${project.name}"? Running tasks will be cancelled.',
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
