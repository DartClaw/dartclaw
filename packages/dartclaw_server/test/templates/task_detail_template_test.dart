import 'package:dartclaw_server/src/templates/loader.dart';
import 'package:dartclaw_server/src/templates/sidebar.dart';
import 'package:dartclaw_server/src/templates/task_detail.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  const emptySidebar = (
    main: null,
    dmChannels: <SidebarSession>[],
    groupChannels: <SidebarSession>[],
    activeEntries: <SidebarSession>[],
    archivedEntries: <SidebarSession>[],
    showChannels: true,
    tasksEnabled: false,
  );
  const navItems = <NavItem>[(label: 'Tasks', href: '/tasks', active: true, navGroup: 'system', icon: 'tasks')];

  test('renders draft start action', () {
    final html = taskDetailPageTemplate(
      sidebarData: emptySidebar,
      navItems: navItems,
      task: const {
        'id': 'task-1',
        'title': 'Draft task',
        'type': 'coding',
        'status': 'draft',
        'description': 'Do work',
        'createdAt': '2026-03-10T10:00:00Z',
      },
      artifacts: const [],
    );

    expect(html, contains('data-task-start'));
    expect(html, contains('Start Task'));
  });

  test('renders provider badge in the task meta grid', () {
    final html = taskDetailPageTemplate(
      sidebarData: emptySidebar,
      navItems: navItems,
      task: const {
        'id': 'task-1',
        'title': 'Provider-aware task',
        'type': 'coding',
        'status': 'review',
        'provider': 'codex',
        'providerLabel': 'Codex',
        'description': 'Do work',
        'createdAt': '2026-03-10T10:00:00Z',
      },
      artifacts: const [],
    );

    expect(html, contains('Provider'));
    expect(html, contains('provider-badge-codex'));
    expect(html, contains('Codex'));
  });

  test('renders structured diff html when provided', () {
    final html = taskDetailPageTemplate(
      sidebarData: emptySidebar,
      navItems: navItems,
      task: const {
        'id': 'task-1',
        'title': 'Review task',
        'type': 'coding',
        'status': 'review',
        'description': 'Do work',
        'createdAt': '2026-03-10T10:00:00Z',
      },
      artifacts: const [
        {
          'name': 'diff.json',
          'kind': 'diff',
          'content': '{}',
          'renderedHtml': '<section class="task-diff-file"><strong>lib/main.dart</strong></section>',
        },
      ],
    );

    expect(html, contains('task-diff-file'));
    expect(html, contains('lib/main.dart'));
  });
}
