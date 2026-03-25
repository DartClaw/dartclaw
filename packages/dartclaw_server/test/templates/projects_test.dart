import 'package:dartclaw_models/dartclaw_models.dart'
    show Project, ProjectStatus, PrConfig, PrStrategy;
import 'package:dartclaw_server/src/templates/loader.dart';
import 'package:dartclaw_server/src/templates/project_form.dart';
import 'package:dartclaw_server/src/templates/projects.dart';
import 'package:dartclaw_server/src/templates/sidebar.dart';
import 'package:dartclaw_server/src/templates/task_form.dart';
import 'package:test/test.dart';

import '../helpers/factories.dart';
import '../test_utils.dart';

void main() {
  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  final SidebarData emptySidebar = (
    main: null,
    dmChannels: <SidebarSession>[],
    groupChannels: <SidebarSession>[],
    activeEntries: <SidebarSession>[],
    archivedEntries: <SidebarSession>[],
    showChannels: false,
    tasksEnabled: false,
  );
  const navItems = <NavItem>[(label: 'Projects', href: '/projects', active: true, navGroup: 'system', icon: 'folder-git')];

  group('projectsPageTemplate', () {
    test('empty state shown when no projects', () {
      final html = projectsPageTemplate(
        sidebarData: emptySidebar,
        navItems: navItems,
        projects: [],
      );
      expect(html, contains('No projects registered'));
      expect(html, contains('Add a project to run tasks against external repositories'));
    });

    test('renders project list with names', () {
      final projects = [
        makeProject(id: 'my-project', name: 'My Project'),
        makeProject(id: 'other-project', name: 'Other Project'),
      ];
      final html = projectsPageTemplate(
        sidebarData: emptySidebar,
        navItems: navItems,
        projects: projects,
      );
      expect(html, contains('My Project'));
      expect(html, contains('Other Project'));
    });

    test('ready status badge class applied', () {
      final projects = [makeProject(id: 'p1', name: 'P1', status: ProjectStatus.ready)];
      final html = projectsPageTemplate(sidebarData: emptySidebar, navItems: navItems, projects: projects);
      expect(html, contains('status-badge-success'));
    });

    test('cloning status badge class applied', () {
      final projects = [makeProject(id: 'p1', name: 'P1', status: ProjectStatus.cloning)];
      final html = projectsPageTemplate(sidebarData: emptySidebar, navItems: navItems, projects: projects);
      expect(html, contains('status-badge-info'));
    });

    test('error status badge class applied', () {
      final projects = [
        makeProject(id: 'p1', name: 'P1', status: ProjectStatus.error, errorMessage: 'auth denied'),
      ];
      final html = projectsPageTemplate(sidebarData: emptySidebar, navItems: navItems, projects: projects);
      expect(html, contains('status-badge-error'));
      expect(html, contains('auth denied'));
    });

    test('stale status badge class applied', () {
      final projects = [makeProject(id: 'p1', name: 'P1', status: ProjectStatus.stale)];
      final html = projectsPageTemplate(sidebarData: emptySidebar, navItems: navItems, projects: projects);
      expect(html, contains('status-badge-warning'));
    });

    test('config-defined project shows Config badge and no edit/remove buttons', () {
      final projects = [makeProject(id: 'p1', name: 'Cfg Project', configDefined: true)];
      final html = projectsPageTemplate(sidebarData: emptySidebar, navItems: navItems, projects: projects);
      expect(html, contains('Config'));
      expect(html, isNot(contains('data-project-edit=')));
      expect(html, isNot(contains('data-project-remove=')));
    });

    test('runtime project shows Runtime badge and edit/remove buttons', () {
      final projects = [makeProject(id: 'p1', name: 'My Project', configDefined: false)];
      final html = projectsPageTemplate(sidebarData: emptySidebar, navItems: navItems, projects: projects);
      expect(html, contains('Runtime'));
      expect(html, contains('data-project-edit='));
      expect(html, contains('data-project-remove='));
    });

    test('default project gets Default badge', () {
      final defaultProject = makeProject(id: 'main-proj', name: 'Main Project');
      final other = makeProject(id: 'side-proj', name: 'Side Project');
      final html = projectsPageTemplate(
        sidebarData: emptySidebar,
        navItems: navItems,
        projects: [defaultProject, other],
        defaultProject: defaultProject,
      );
      // The default project card should contain "Default"
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
      final html = projectsPageTemplate(
        sidebarData: emptySidebar,
        navItems: navItems,
        projects: [localProject],
      );
      expect(html, contains('Local'));
      expect(html, isNot(contains('data-project-edit=')));
      expect(html, isNot(contains('data-project-remove=')));
    });

    test('long remote URL is truncated to 60 chars with ellipsis', () {
      final longUrl = 'https://github.com/${'x' * 60}';
      final projects = [makeProject(id: 'p1', name: 'P1', remoteUrl: longUrl)];
      final html = projectsPageTemplate(sidebarData: emptySidebar, navItems: navItems, projects: projects);
      expect(html, contains('\u2026')); // ellipsis character
    });

    test('last fetch "Never" shown when lastFetchAt is null', () {
      final projects = [makeProject(id: 'p1', name: 'P1')];
      final html = projectsPageTemplate(sidebarData: emptySidebar, navItems: navItems, projects: projects);
      expect(html, contains('Never'));
    });

    test('PR strategy label shown', () {
      final projects = [
        makeProject(
          id: 'p1',
          name: 'P1',
          pr: const PrConfig(strategy: PrStrategy.githubPr),
        ),
      ];
      final html = projectsPageTemplate(sidebarData: emptySidebar, navItems: navItems, projects: projects);
      expect(html, contains('GitHub PR'));
    });

    test('branch-only PR strategy label shown', () {
      final projects = [
        makeProject(
          id: 'p1',
          name: 'P1',
          pr: const PrConfig(strategy: PrStrategy.branchOnly),
        ),
      ];
      final html = projectsPageTemplate(sidebarData: emptySidebar, navItems: navItems, projects: projects);
      expect(html, contains('Branch Only'));
    });

    test('project data-project-id attribute present for JS targeting', () {
      final projects = [makeProject(id: 'my-repo', name: 'My Repo')];
      final html = projectsPageTemplate(sidebarData: emptySidebar, navItems: navItems, projects: projects);
      expect(html, contains('data-project-id="my-repo"'));
    });
  });

  group('addProjectDialogHtml', () {
    test('contains all required form fields', () {
      final html = addProjectDialogHtml();
      expect(html, contains('id="add-project-dialog"'));
      expect(html, contains('name="remoteUrl"'));
      expect(html, contains('name="name"'));
      expect(html, contains('name="defaultBranch"'));
      expect(html, contains('name="credentialsRef"'));
      expect(html, contains('name="prStrategy"'));
      expect(html, contains('name="draft"'));
      expect(html, contains('name="labels"'));
    });

    test('GitHub PR and Branch Only options present in strategy select', () {
      final html = addProjectDialogHtml();
      expect(html, contains('GitHub PR'));
      expect(html, contains('Branch Only'));
    });

    test('error container present', () {
      final html = addProjectDialogHtml();
      expect(html, contains('id="add-project-error"'));
    });
  });

  group('newTaskFormDialogHtml with projectOptions', () {
    test('no project selector when only local project exists', () {
      final html = newTaskFormDialogHtml(
        projectOptions: [
          {'value': '_local', 'label': 'Local', 'status': 'ready', 'isDefault': 'true'},
        ],
      );
      expect(html, isNot(contains('task-project-select')));
    });

    test('project selector shown when external projects exist', () {
      final html = newTaskFormDialogHtml(
        projectOptions: [
          {'value': '_local', 'label': 'Local', 'status': 'ready', 'isDefault': 'false'},
          {'value': 'my-project', 'label': 'My Project', 'status': 'ready', 'isDefault': 'true'},
        ],
      );
      expect(html, contains('id="task-project-select"'));
      expect(html, contains('My Project'));
    });

    test('ready project option is not disabled', () {
      final html = newTaskFormDialogHtml(
        projectOptions: [
          {'value': 'ready-proj', 'label': 'Ready', 'status': 'ready', 'isDefault': 'true'},
        ],
      );
      // Ready options should not have disabled attribute
      expect(html, isNot(contains('value="ready-proj" disabled')));
      expect(html, isNot(contains('value="ready-proj" selected disabled')));
    });

    test('cloning project option is disabled', () {
      final html = newTaskFormDialogHtml(
        projectOptions: [
          {'value': 'cloning-proj', 'label': 'Cloning', 'status': 'cloning', 'isDefault': 'false'},
        ],
      );
      expect(html, contains('disabled'));
      expect(html, contains('(cloning)'));
    });

    test('error project option is disabled', () {
      final html = newTaskFormDialogHtml(
        projectOptions: [
          {'value': 'error-proj', 'label': 'Error', 'status': 'error', 'isDefault': 'false'},
        ],
      );
      expect(html, contains('disabled'));
      expect(html, contains('(error)'));
    });

    test('default project gets selected attribute', () {
      final html = newTaskFormDialogHtml(
        projectOptions: [
          {'value': 'proj-a', 'label': 'Project A', 'status': 'ready', 'isDefault': 'false'},
          {'value': 'proj-b', 'label': 'Project B', 'status': 'ready', 'isDefault': 'true'},
        ],
      );
      expect(html, contains('value="proj-b" selected'));
    });
  });
}
