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
    showChannels: true,
    tasksEnabled: false,
  );
  const navItems = <NavItem>[(label: 'Tasks', href: '/tasks', active: true, navGroup: 'system', icon: 'tasks')];

  group('tasksPageTemplate', () {
    test('renders empty state with no tasks', () {
      final html = tasksPageTemplate(sidebarData: emptySidebar, navItems: navItems, tasks: const []);

      expect(html, contains('No tasks yet'));
      expect(html, contains('Tasks will appear here when created.'));
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
      expect(html, contains('status-badge-interrupted'));
      expect(html, contains('value="interrupted"'));
      expect(html, contains('selected'));
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

    test('renders provider badges in running cards, table rows, and agent overview', () {
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
        agentRunners: const [
          {
            'runnerId': 1,
            'role': 'task',
            'state': 'busy',
            'providerId': 'codex',
            'tokensConsumed': 120,
            'turnsCompleted': 3,
            'errorCount': 0,
            'currentTaskId': 'task-running',
          },
        ],
        agentPool: const {'size': 2, 'activeCount': 1, 'availableCount': 1, 'maxConcurrentTasks': 2},
      );

      expect(html, contains('Provider'));
      expect(html, contains('provider-badge-codex'));
      expect(html, contains('provider-badge-claude'));
      expect(html, contains('Run codex worker'));
      expect(html, contains('Review claude output'));
      expect(html, contains('Agent Pool'));
    });

    test('renders agent overview when pool data is present', () {
      final html = tasksPageTemplate(
        sidebarData: emptySidebar,
        navItems: navItems,
        tasks: const [],
        agentRunners: const [
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
        agentPool: const {'size': 1, 'activeCount': 0, 'availableCount': 0, 'maxConcurrentTasks': 0},
      );

      expect(html, contains('Agent Pool'));
      expect(html, contains('Single runner mode'));
    });
  });
}
