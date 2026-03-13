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
  );
  const navItems = <NavItem>[(label: 'Tasks', href: '/tasks', active: true, navGroup: 'system')];

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
