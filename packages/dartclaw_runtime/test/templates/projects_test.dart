import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/templates/loader.dart';
import 'package:dartclaw_runtime/src/templates/projects.dart';
import 'package:dartclaw_runtime/src/templates/sidebar.dart';
import 'package:dartclaw_runtime/src/templates/tasks.dart';
import 'package:test/test.dart';

import '../helpers/factories.dart';
import '../test_utils.dart';

void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  final SidebarData emptySidebar = (
    main: null,
    dmChannels: <SidebarSession>[],
    groupChannels: <SidebarSession>[],
    activeEntries: <SidebarSession>[],
    archivedEntries: <SidebarSession>[],
    activeTasks: <SidebarActiveTask>[],
    activeWorkflows: <SidebarActiveWorkflow>[],
    showChannels: false,
    tasksEnabled: false,
    activeSessionId: null,
  );
  const navItems = <NavItem>[
    (label: 'Projects', href: '/projects', active: true, navGroup: 'system', icon: 'folder-git'),
  ];

  group('projectsPageTemplate', () {
    test('empty state shown when no projects', () {
      final html = projectsPageTemplate(sidebarData: emptySidebar, navItems: navItems, projects: []);
      expect(html, contains('<header class="pagehead">'));
      expect(RegExp(r'<h1\b').allMatches(html), hasLength(1));
      expect(html, isNot(contains('class="page-title"')));
      expect(html, contains('No projects registered'));
      expect(html, contains('Add a project to run tasks against external repositories'));
      expect(html, contains('class="empty-state"'));
    });

    test('renders project list with names', () {
      final projects = [
        makeProject(id: 'my-project', name: 'My Project'),
        makeProject(id: 'other-project', name: 'Other Project'),
      ];
      final html = projectsPageTemplate(sidebarData: emptySidebar, navItems: navItems, projects: projects);
      expect(html, contains('My Project'));
      expect(html, contains('Other Project'));
    });

    test('the Projects SYSTEM nav entry survives the fragment split', () {
      final html = projectsPageTemplate(sidebarData: emptySidebar, navItems: navItems, projects: []);
      expect(html, contains('href="/projects"'));
    });

    test('the page embeds the list fragment verbatim, so a swap and a load agree', () {
      final projects = [makeProject(id: 'p1', name: 'P1')];
      final page = projectsPageTemplate(sidebarData: emptySidebar, navItems: navItems, projects: projects);
      final fragment = projectsContentFragment(projects: projects);

      expect(fragment, startsWith('<div class="page-inner" id="projects-content"'));
      expect(page, contains(fragment));
    });

    test('each swappable surface appears exactly once, so a swap has one target', () {
      // The template source holds three fragments; rendering it whole instead of
      // by name would concatenate all of them and duplicate both swap targets.
      final html = projectsPageTemplate(
        sidebarData: emptySidebar,
        navItems: navItems,
        projects: [makeProject(id: 'p1', name: 'P1')],
      );

      expect(RegExp('id="projects-content"').allMatches(html), hasLength(1));
      expect(RegExp('id="project-dialog-host"').allMatches(html), hasLength(1));
    });

    test('the page starts with an empty dialog host, so nothing is open on load', () {
      final html = projectsPageTemplate(sidebarData: emptySidebar, navItems: navItems, projects: []);
      expect(html, contains('id="project-dialog-host"'));
      expect(html, isNot(contains('id="add-project-dialog"')));
    });

    test('the card carries no project values for JavaScript to copy into a dialog', () {
      final html = projectsPageTemplate(
        sidebarData: emptySidebar,
        navItems: navItems,
        projects: [
          makeProject(
            id: 'p1',
            name: 'P1',
            remoteUrl: 'https://github.com/acme/app.git',
            credentialsRef: 'github-main',
            pr: const PrConfig(strategy: PrStrategy.githubPr, labels: ['agent']),
          ),
        ],
      );
      for (final hook in ['url', 'branch', 'creds', 'strategy', 'draft', 'labels', 'edit', 'remove', 'fetch']) {
        expect(html, isNot(contains('data-project-$hook=')), reason: hook);
      }
    });
  });

  group('projectsContentFragment', () {
    test('ready status badge class applied', () {
      final html = projectsContentFragment(
        projects: [makeProject(id: 'p1', name: 'P1', status: ProjectStatus.ready)],
      );
      expect(html, contains('status-badge-success'));
    });

    test('cloning status badge class applied', () {
      final html = projectsContentFragment(
        projects: [makeProject(id: 'p1', name: 'P1', status: ProjectStatus.cloning)],
      );
      expect(html, contains('status-badge-info'));
    });

    test('error status badge class applied', () {
      final html = projectsContentFragment(
        projects: [makeProject(id: 'p1', name: 'P1', status: ProjectStatus.error, errorMessage: 'auth denied')],
      );
      expect(html, contains('status-badge-error'));
      expect(html, contains('auth denied'));
      expect(html, contains('banner banner-error'));
      expect(html, contains('icon-triangle-alert'));
      expect(html, contains('data-project-error=""'), reason: 'the live status badge updater targets it');
    });

    test('stale status badge class applied', () {
      final html = projectsContentFragment(
        projects: [makeProject(id: 'p1', name: 'P1', status: ProjectStatus.stale)],
      );
      expect(html, contains('status-badge-warning'));
    });

    test('config-defined project shows Config badge and offers no edit or remove control', () {
      final html = projectsContentFragment(
        projects: [makeProject(id: 'p1', name: 'Cfg Project', configDefined: true)],
      );
      expect(html, contains('Config'));
      expect(html, isNot(contains('/projects/p1/dialog')));
      expect(html, isNot(contains('/projects/p1/delete')));
    });

    test('runtime project shows Runtime badge and points its controls at the page routes', () {
      final html = projectsContentFragment(
        projects: [makeProject(id: 'p1', name: 'My Project', configDefined: false)],
      );
      expect(html, contains('Runtime'));
      expect(html, contains('hx-get="/projects/p1/dialog"'));
      expect(html, contains('hx-post="/projects/p1/delete"'));
      expect(html, contains('hx-post="/projects/p1/fetch"'));
      expect(html, contains('hx-confirm="Remove project &quot;My Project&quot;? Running tasks will be cancelled."'));
    });

    test('every swap target pairs its selector with an outerHTML swap', () {
      final html = projectsContentFragment(
        projects: [makeProject(id: 'p1', name: 'P1')],
      );
      expect(RegExp('hx-target="#projects-content" hx-swap="outerHTML"').allMatches(html), isNotEmpty);
      expect(html, isNot(contains('hx-swap="none"')));
    });

    test('default project gets Default badge', () {
      final defaultProject = makeProject(id: 'main-proj', name: 'Main Project');
      final html = projectsContentFragment(
        projects: [
          defaultProject,
          makeProject(id: 'side-proj', name: 'Side Project'),
        ],
        defaultProject: defaultProject,
      );
      expect(html, contains('Default'));
    });

    test('local project shows Local badge without edit/remove', () {
      final localProject = Project(
        id: '_local',
        name: 'Local',
        remoteUrl: '',
        localPath: '/workspace',
        status: ProjectStatus.ready,
        configDefined: false,
        createdAt: DateTime.parse('2026-01-01T00:00:00Z'),
      );
      final html = projectsContentFragment(projects: [localProject]);
      expect(html, contains('Local'));
      expect(html, isNot(contains('/projects/_local/dialog')));
      expect(html, isNot(contains('/projects/_local/delete')));
    });

    test('long remote URL is truncated to 60 chars with ellipsis', () {
      final longUrl = 'https://github.com/${'x' * 60}';
      final html = projectsContentFragment(
        projects: [makeProject(id: 'p1', name: 'P1', remoteUrl: longUrl)],
      );
      expect(html, contains('\u2026')); // ellipsis character
    });

    test('last fetch uses the absent-value treatment when null', () {
      final html = projectsContentFragment(
        projects: [makeProject(id: 'p1', name: 'P1')],
      );
      expect(html, contains('Fetched: <span class="value-absent"></span>'));
    });

    test('PR strategy label shown', () {
      final html = projectsContentFragment(
        projects: [
          makeProject(
            id: 'p1',
            name: 'P1',
            pr: const PrConfig(strategy: PrStrategy.githubPr),
          ),
        ],
      );
      expect(html, contains('GitHub PR'));
    });

    test('branch-only PR strategy label shown', () {
      final html = projectsContentFragment(
        projects: [
          makeProject(
            id: 'p1',
            name: 'P1',
            pr: const PrConfig(strategy: PrStrategy.branchOnly),
          ),
        ],
      );
      expect(html, contains('Branch Only'));
    });

    test('project card composes canon and keeps its live-status hook', () {
      final html = projectsContentFragment(
        projects: [makeProject(id: 'p1', name: 'P1', configDefined: false)],
      );
      expect(html, contains('class="card" data-project-id="p1"'));
      expect(html, contains('class="card-header"'));
      expect(html, contains('class="card-header-actions"'));
      expect(html, contains('class="card-footer t-caption"'));
    });

    test('the empty list renders the shared empty state, not an empty container', () {
      final html = projectsContentFragment(projects: []);
      expect(html, contains('class="empty-state"'));
      expect(html, contains('No projects registered'));
      expect(html, contains('hx-get="/projects/dialog"'));
    });

    test('an out-of-band render marks itself for the ride-along swap', () {
      expect(projectsContentFragment(projects: [], outOfBand: true), contains('hx-swap-oob="true"'));
      expect(projectsContentFragment(projects: []), isNot(contains('hx-swap-oob')));
    });

    test('a hostile project name cannot escape its card text or its confirmation attribute', () {
      final html = projectsContentFragment(
        projects: [makeProject(id: 'p1', name: 'a" <script>x</script>', configDefined: false)],
      );

      expect(html, contains('&lt;script&gt;x&lt;/script&gt;'), reason: 'card text is escaped');
      final confirm = RegExp('hx-confirm="([^"]*)"').firstMatch(html)!.group(1)!;
      expect(confirm, contains('&quot;a&quot;'), reason: 'a quote in the name cannot terminate the attribute');
    });
  });

  group('projectDialogHostFragment', () {
    test('an empty host carries no dialog, which is how a successful save closes it', () {
      final html = projectDialogHostFragment();
      expect(html, contains('id="project-dialog-host"'));
      expect(html, isNot(contains('<dialog')));
    });

    test('the add dialog renders the defaults and posts to the create route', () {
      final html = projectDialogHostFragment(values: projectDialogDefaults);
      expect(html, contains('id="add-project-dialog"'));
      expect(html, contains('hx-post="/projects/create"'));
      expect(html, contains('hx-target="#project-dialog-host" hx-swap="outerHTML"'));
      expect(html, contains('>Add Project</h2>'));
      expect(html, contains('name="remoteUrl"'));
      expect(html, contains('name="name"'));
      expect(html, contains('name="defaultBranch"'));
      expect(html, contains('name="credentialsRef"'));
      expect(html, contains('name="prStrategy"'));
      expect(html, contains('name="draft"'));
      expect(html, contains('<label class="form-field form-field--checkbox">'));
      expect(html, contains('name="labels"'));
      expect(html, contains('value="main"'));
      expect(html, contains('<option value="branchOnly" selected="">'));
      expect(html, contains('GitHub PR'));
      expect(html, contains('Branch Only'));
      expect(html, contains('id="add-project-error"'));
      expect(html, contains('data-controller="dc-dialog"'));
    });

    test('uses the canonical glass treatment for the add-project dialog', () {
      expect(
        projectDialogHostFragment(values: projectDialogDefaults),
        contains('class="dialog dialog--md card card-glass"'),
      );
    });

    test('the edit dialog arrives already carrying the stored project', () {
      final project = makeProject(
        id: 'acme',
        name: 'acme',
        remoteUrl: 'https://github.com/acme/app.git',
        defaultBranch: 'develop',
        credentialsRef: 'github-main',
        pr: const PrConfig(strategy: PrStrategy.githubPr, draft: false, labels: ['agent', 'automated']),
      );

      final html = projectDialogHostFragment(values: projectDialogValuesOf(project), projectId: project.id);

      expect(html, contains('hx-post="/projects/acme/update"'));
      expect(html, contains('>Edit Project</h2>'));
      expect(html, contains('>Save Changes</button>'));
      expect(html, contains('value="https://github.com/acme/app.git"'));
      expect(html, contains('value="acme"'));
      expect(html, contains('value="develop"'));
      expect(html, contains('value="github-main"'));
      expect(html, contains('<option value="githubPr" selected="">'));
      expect(html, contains('value="agent, automated"'));
      expect(html, isNot(contains('name="draft" checked')), reason: 'draft off renders no checked attribute');
    });

    test('a refusal on a control renders in that field and marks it invalid', () {
      final html = projectDialogHostFragment(
        values: (
          remoteUrl: 'https://github.com/acme/app.git',
          name: 'app',
          defaultBranch: 'main',
          credentialsRef: '',
          prStrategy: 'branchOnly',
          prDraft: true,
          prLabels: '',
        ),
        errorMessage: 'Project with id "app" already exists',
        errorField: 'name',
      );

      expect(html, contains('value="app"'), reason: 'the operator\'s entry survives the refusal');
      expect(html, contains('value="https://github.com/acme/app.git"'));
      expect(html, contains('aria-invalid="true"'));
      expect(html, contains('<div class="form-error t-caption">Project with id "app" already exists</div>'));
      expect(html, contains('<div id="add-project-error" class="form-error t-caption" role="alert"></div>'));
    });

    test('a refusal naming no control lands in the form-level error', () {
      final html = projectDialogHostFragment(
        values: projectDialogDefaults,
        errorMessage: 'Config-defined projects cannot be modified via API',
        errorField: null,
      );

      expect(html, contains('role="alert">Config-defined projects cannot be modified via API</div>'));
      expect(html, isNot(contains('aria-invalid')));
    });
  });

  group('taskCreatePanelFragment with projectOptions', () {
    test('project selector reflects server-side project state', () {
      final html = taskCreatePanelFragment(
        goalOptions: const [],
        projectOptions: const [
          {'value': '_local', 'label': 'Local', 'status': 'ready', 'isDefault': 'false'},
          {'value': 'ready-proj', 'label': 'Ready', 'status': 'ready', 'isDefault': 'true'},
          {'value': 'cloning-proj', 'label': 'Cloning', 'status': 'cloning', 'isDefault': 'false'},
        ],
      );

      expect(html, contains('id="task-project-select"'));
      expect(html, contains('value="ready-proj" selected'));
      expect(html, contains('Cloning (cloning)'));
      expect(RegExp(r'value="cloning-proj"[^>]*disabled').hasMatch(html), isTrue);
    });

    test('no project selector is rendered for the local project alone', () {
      final html = taskCreatePanelFragment(
        goalOptions: const [],
        projectOptions: const [
          {'value': '_local', 'label': 'Local', 'status': 'ready', 'isDefault': 'true'},
        ],
      );

      expect(html, isNot(contains('task-project-select')));
    });
  });
}
