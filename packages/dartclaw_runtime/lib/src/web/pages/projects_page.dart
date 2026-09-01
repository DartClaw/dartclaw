import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show ProjectService;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../../api/api_helpers.dart';
import '../../project/project_mutation_service.dart';
import '../../templates/projects.dart';
import '../dashboard_page.dart';
import '../web_utils.dart';

/// Caps a project form submission: a remote URL, a name and a label list.
const _maxProjectFormBytes = 16 * 1024;

/// Dashboard page for managing external project repositories.
///
/// The page owns its mutating routes: every add, edit, fetch and remove is an
/// ordinary submission to a `/projects` sub-path, answered with the same
/// fragments the page itself renders. Each one delegates the decision to the
/// shared [ProjectMutationService], so the web tier refuses exactly what
/// `/api/projects*` refuses.
class ProjectsPage extends DashboardPage {
  @override
  String get route => '/projects';

  @override
  String get title => 'Projects';

  @override
  String? get icon => 'folder-git';

  @override
  String get navGroup => 'system';

  @override
  List<PageRouteDeclaration> get declaredRoutes => const [
    (method: 'GET', path: '/projects/dialog'),
    (method: 'GET', path: '/projects/<id>/dialog'),
    (method: 'POST', path: '/projects/create'),
    (method: 'POST', path: '/projects/<id>/update'),
    (method: 'POST', path: '/projects/<id>/delete'),
    (method: 'POST', path: '/projects/<id>/fetch'),
  ];

  @override
  Future<Response> handler(Request request, PageContext context) async {
    final projects = context.projectService;
    if (projects == null) {
      return Response.ok(
        '<div class="empty-state"><p class="empty-state-title t-label">Projects not configured</p></div>',
        headers: htmlHeaders,
      );
    }

    // The declared routes all end in their action; the page GET does not.
    final action = request.requestedUri.pathSegments.last;
    final id = request.params['id'];
    return switch ((request.method, action)) {
      ('GET', 'dialog') => _dialog(projects, id),
      ('POST', 'create') => _save(request, context, projects, id: null),
      ('POST', 'update') => _save(request, context, projects, id: id),
      ('POST', 'delete') => _rowAction(context, projects, id: id, success: 'Project removed', delete: true),
      ('POST', 'fetch') => _rowAction(context, projects, id: id, success: 'Project fetched', delete: false),
      _ => _page(context, projects),
    };
  }

  Future<Response> _page(PageContext context, ProjectService projects) async {
    final all = await projects.getAll();
    final defaultProject = await projects.defaultProject;
    final sidebarData = await context.sidebar.build();

    return Response.ok(
      projectsPageTemplate(
        sidebarData: sidebarData,
        navItems: context.navItems(activePage: title),
        projects: all,
        defaultProject: defaultProject,
        restartBannerHtml: context.restartBannerHtml(),
        appName: context.appName,
      ),
      headers: htmlHeaders,
    );
  }

  /// `GET /projects/dialog` and `GET /projects/<id>/dialog`.
  ///
  /// Renders the dialog into its host already filled in — empty for an add,
  /// from the stored project for an edit — so nothing on the page carries
  /// project values for the browser to copy across.
  Future<Response> _dialog(ProjectService projects, String? rawId) async {
    if (rawId == null) {
      return Response.ok(projectDialogHostFragment(values: projectDialogDefaults), headers: htmlHeaders);
    }
    final id = decodePathSegment(rawId);
    final project = await projects.get(id);
    if (project == null) {
      return Response.ok(
        projectDialogHostFragment(),
        headers: {...htmlHeaders, ...toastTriggerHeader('error', 'Project not found')},
      );
    }
    return Response.ok(
      projectDialogHostFragment(values: projectDialogValuesOf(project), projectId: id),
      headers: htmlHeaders,
    );
  }

  /// `POST /projects/create` and `POST /projects/<id>/update`.
  ///
  /// Success answers the closed (empty) dialog host with the re-rendered list
  /// riding along out of band; a refusal answers the dialog again, carrying the
  /// operator's entry and the refusal on the control it belongs to.
  Future<Response> _save(Request request, PageContext context, ProjectService projects, {required String? id}) async {
    final mutations = context.projectMutations;
    if (mutations == null) return _editingUnavailable();

    final body = await readRequestBody(request, maxBytes: _maxProjectFormBytes);
    if (body.error != null) return body.error!;
    final Map<String, String> form;
    try {
      form = Uri.splitQueryString(body.body!);
    } on ArgumentError {
      return errorResponse(400, 'INVALID_INPUT', 'Request body must be form-encoded');
    } on FormatException {
      // A percent escape that is not valid UTF-8 throws this rather than
      // ArgumentError; letting it out turns Save into a silent no-op, because
      // HTMX drops the body of the 500 the page wrapper would answer.
      return errorResponse(400, 'INVALID_INPUT', 'Request body must be form-encoded');
    }

    final values = _dialogValues(form);
    final projectId = id == null ? null : decodePathSegment(id);
    final pr = PrConfig(
      strategy: PrStrategy.fromYaml(values.prStrategy),
      draft: values.prDraft,
      labels: _labels(values.prLabels),
    );
    final result = projectId == null
        ? await mutations.create((
            name: _blankToNull(values.name),
            remoteUrl: _blankToNull(values.remoteUrl),
            localPath: null,
            defaultBranch: _blankToNull(values.defaultBranch),
            credentialsRef: _blankToNull(values.credentialsRef),
            cloneStrategy: CloneStrategy.shallow,
            pr: pr,
          ))
        : await mutations.update(projectId, (
            name: _blankToNull(values.name),
            remoteUrl: _blankToNull(values.remoteUrl),
            defaultBranch: _blankToNull(values.defaultBranch),
            credentialsRef: _blankToNull(values.credentialsRef),
            pr: pr,
          ));

    switch (result) {
      case ProjectMutationRefused(:final refusal):
        return Response.ok(
          projectDialogHostFragment(
            values: values,
            projectId: projectId,
            errorMessage: refusal.message,
            errorField: refusal.field,
          ),
          headers: htmlHeaders,
        );
      case ProjectMutationApplied():
        final content = await _contentFragment(projects, outOfBand: true);
        return Response.ok(
          '${projectDialogHostFragment()}$content',
          headers: {
            ...htmlHeaders,
            ...toastTriggerHeader('success', projectId == null ? 'Project added' : 'Project updated'),
          },
        );
    }
  }

  /// `POST /projects/<id>/delete` and `POST /projects/<id>/fetch`.
  ///
  /// A row action has no control to carry a field error, so it always answers
  /// the re-rendered list and reports the outcome as a toast.
  Future<Response> _rowAction(
    PageContext context,
    ProjectService projects, {
    required String? id,
    required String success,
    required bool delete,
  }) async {
    final mutations = context.projectMutations;
    if (mutations == null) return _editingUnavailable();

    final projectId = decodePathSegment(id!);
    final result = delete ? await mutations.delete(projectId) : await mutations.fetch(projectId);
    final (type, message) = switch (result) {
      ProjectMutationRefused(:final refusal) => ('error', refusal.message),
      ProjectMutationApplied() => ('success', success),
    };
    return Response.ok(
      await _contentFragment(projects, outOfBand: false),
      headers: {...htmlHeaders, ...toastTriggerHeader(type, message)},
    );
  }

  Future<String> _contentFragment(ProjectService projects, {required bool outOfBand}) async {
    return projectsContentFragment(
      projects: await projects.getAll(),
      defaultProject: await projects.defaultProject,
      outOfBand: outOfBand,
    );
  }

  Response _editingUnavailable() =>
      errorResponse(503, 'PROJECTS_READ_ONLY', 'Project editing is not available on this server');
}

ProjectDialogValues _dialogValues(Map<String, String> form) => (
  remoteUrl: form['remoteUrl']?.trim() ?? '',
  name: form['name']?.trim() ?? '',
  defaultBranch: form['defaultBranch']?.trim() ?? '',
  credentialsRef: form['credentialsRef']?.trim() ?? '',
  prStrategy: form['prStrategy'] ?? projectDialogDefaults.prStrategy,
  // An unchecked checkbox is absent from a form body, which is `false` — not
  // "unchanged".
  prDraft: form.containsKey('draft'),
  prLabels: form['labels']?.trim() ?? '',
);

/// A blank control is "unset", so the mutation authority applies its own
/// default rather than storing an empty value.
String? _blankToNull(String value) => value.isEmpty ? null : value;

List<String> _labels(String raw) =>
    raw.split(',').map((label) => label.trim()).where((label) => label.isNotEmpty).toList();
