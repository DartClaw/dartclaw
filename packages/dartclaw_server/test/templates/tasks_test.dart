import 'package:dartclaw_server/src/templates/loader.dart';
import 'package:dartclaw_server/src/templates/sidebar.dart';
import 'package:dartclaw_server/src/templates/tasks.dart';
import 'package:test/test.dart';

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
    activeTasks: <SidebarActiveTask>[],
    activeWorkflows: <SidebarActiveWorkflow>[],
    showChannels: true,
    tasksEnabled: false,
    activeSessionId: null,
  );
  const navItems = <NavItem>[(label: 'Tasks', href: '/tasks', active: true, navGroup: 'system', icon: 'tasks')];

  group('tasksPageTemplate', () {
    test('renders empty state with no tasks', () {
      final html = tasksPageTemplate(sidebarData: emptySidebar, navItems: navItems, tasks: const []);

      // Composed through the shared emptyState fragment, not a page-local copy.
      expect(html, contains('No tasks yet'));
      expect(html, contains('Create a task to hand a piece of work to an agent.'));
      expect(html, contains('empty-state-title t-label'));
      expect(html, isNot(contains('\u2610')));
    });

    test('renders running task cards with the shared entry treatment', () {
      final html = tasksPageTemplate(
        sidebarData: emptySidebar,
        navItems: navItems,
        tasks: [
          {
            'id': 'task-1',
            'title': 'Sync assets',
            'status': 'running',
            'type': 'coding',
            'provider': 'claude',
            'createdAt': '2026-07-20T00:00:00Z',
          },
        ],
      );

      expect(html, contains('task-card-running print-in'));
      expect(html, contains('card-tint-accent'));
    });

    test('renders interrupted tasks in their own group and filter', () {
      final html = tasksPageTemplate(
        sidebarData: emptySidebar,
        navItems: navItems,
        tasks: [
          {
            'id': 'task-1',
            'title': 'Recover state',
            'type': 'analysis',
            'status': 'interrupted',
            'createdAt': '2026-03-10T10:00:00Z',
          },
        ],
        statusFilter: 'interrupted',
      );

      expect(html, contains('Interrupted'));
      // The table's STATUS column is a canon pill driven by the shared
      // presentation map, not the badge vocabulary.
      expect(html, contains('status-pill--warning'));
      expect(html, contains('status-dot--warning'));
      expect(html, contains('value="interrupted"'));
      expect(html, contains('selected'));
      expect(html, contains('<section class="task-status-group" aria-labelledby="task-status-interrupted">'));
      expect(html, contains('<h2 class="t-heading" id="task-status-interrupted">'));
    });

    test('links task title to detail page', () {
      final html = tasksPageTemplate(
        sidebarData: emptySidebar,
        navItems: navItems,
        tasks: [
          {
            'id': 'task-1',
            'title': 'Implement endpoint',
            'type': 'coding',
            'status': 'review',
            'sessionId': 'session-1',
            'createdAt': '2026-03-10T10:00:00Z',
          },
        ],
      );

      expect(html, contains('href="/tasks/task-1"'));
      expect(html, contains('Implement endpoint'));
    });

    test('links task title to detail page even without session', () {
      final html = tasksPageTemplate(
        sidebarData: emptySidebar,
        navItems: navItems,
        tasks: [
          {
            'id': 'task-1',
            'title': 'Triage review',
            'type': 'research',
            'status': 'review',
            'createdAt': '2026-03-10T10:00:00Z',
          },
        ],
      );

      expect(html, contains('Triage review'));
      expect(html, contains('href="/tasks/task-1"'));
    });

    test('renders provider badges in running cards, table rows, and harness overview', () {
      final html = tasksPageTemplate(
        sidebarData: emptySidebar,
        navItems: navItems,
        tasks: [
          {
            'id': 'task-running',
            'title': 'Run codex worker',
            'type': 'analysis',
            'status': 'running',
            'provider': 'codex',
            'providerLabel': 'Codex',
            'createdAt': '2026-03-10T10:00:00Z',
          },
          {
            'id': 'task-review',
            'title': 'Review claude output',
            'type': 'coding',
            'status': 'review',
            'provider': 'claude',
            'providerLabel': 'Claude',
            'createdAt': '2026-03-10T10:00:00Z',
          },
        ],
        runners: const [
          {
            'runnerId': 1,
            'role': 'worker',
            'state': 'busy',
            'providerId': 'codex',
            'tokensConsumed': 120,
            'turnsCompleted': 3,
            'errorCount': 0,
            'currentTaskId': 'task-running',
          },
        ],
        harnessPool: const {'size': 2, 'activeCount': 1, 'availableCount': 1, 'maxConcurrentWorkers': 2},
      );

      expect(html, contains('Provider'));
      expect(html, contains('provider-badge-codex'));
      expect(html, contains('provider-badge-claude'));
      expect(html, contains('Run codex worker'));
      expect(html, contains('Review claude output'));
      expect(html, contains('Harness Pool'));
      expect(html, contains('1/2 workers active'));
      expect(html, contains('Worker #1'));
    });

    test('renders harness overview when pool data is present', () {
      final html = tasksPageTemplate(
        sidebarData: emptySidebar,
        navItems: navItems,
        tasks: const [],
        runners: const [
          {
            'runnerId': 0,
            'role': 'primary',
            'state': 'idle',
            'providerId': 'claude',
            'tokensConsumed': 10,
            'turnsCompleted': 2,
            'errorCount': 0,
          },
        ],
        harnessPool: const {'size': 1, 'activeCount': 0, 'availableCount': 0, 'maxConcurrentWorkers': 0},
      );

      expect(html, contains('Harness Pool'));
      expect(html, contains('Single runner mode'));
    });
  });
}
