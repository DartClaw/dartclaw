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

  test('renders token summary card when traceCount > 0', () {
    final html = taskDetailPageTemplate(
      sidebarData: emptySidebar,
      navItems: navItems,
      task: const {
        'id': 'task-1',
        'title': 'Traced task',
        'type': 'research',
        'status': 'review',
        'description': 'Do work',
        'createdAt': '2026-03-10T10:00:00Z',
      },
      artifacts: const [],
      tokenSummary: const {
        'traceCount': 3,
        'totalTokens': 15500,
        'totalInputTokens': 12000,
        'totalOutputTokens': 3500,
        'totalCacheReadTokens': 0,
        'totalCacheWriteTokens': 0,
        'totalDurationMs': 45000,
        'totalToolCalls': 24,
      },
    );

    expect(html, contains('task-token-summary'));
    expect(html, contains('Total Tokens'));
    expect(html, contains('15,500'));
    expect(html, contains('12,000'));
    expect(html, contains('3,500'));
    expect(html, contains('45s'));
    expect(html, contains('24'));
    expect(html, contains('Turns'));
    expect(html, contains('>3<'));
  });

  test('hides token summary card when traceCount is 0', () {
    final html = taskDetailPageTemplate(
      sidebarData: emptySidebar,
      navItems: navItems,
      task: const {
        'id': 'task-1',
        'title': 'Untraced task',
        'type': 'research',
        'status': 'draft',
        'description': 'Not started',
        'createdAt': '2026-03-10T10:00:00Z',
      },
      artifacts: const [],
      tokenSummary: const {
        'traceCount': 0,
        'totalTokens': 0,
        'totalInputTokens': 0,
        'totalOutputTokens': 0,
        'totalCacheReadTokens': 0,
        'totalCacheWriteTokens': 0,
        'totalDurationMs': 0,
        'totalToolCalls': 0,
      },
    );

    expect(html, isNot(contains('task-token-summary')));
  });

  test('hides cache row when no cache tokens', () {
    final html = taskDetailPageTemplate(
      sidebarData: emptySidebar,
      navItems: navItems,
      task: const {
        'id': 'task-1',
        'title': 'No cache task',
        'type': 'research',
        'status': 'review',
        'description': 'Do work',
        'createdAt': '2026-03-10T10:00:00Z',
      },
      artifacts: const [],
      tokenSummary: const {
        'traceCount': 2,
        'totalTokens': 1000,
        'totalInputTokens': 800,
        'totalOutputTokens': 200,
        'totalCacheReadTokens': 0,
        'totalCacheWriteTokens': 0,
        'totalDurationMs': 10000,
        'totalToolCalls': 5,
      },
    );

    expect(html, contains('task-token-summary'));
    expect(html, isNot(contains('Cache')));
  });

  test('injects timelineHtml when provided', () {
    const sentinel = '<div class="task-timeline" data-test-sentinel="1"></div>';
    final html = taskDetailPageTemplate(
      sidebarData: emptySidebar,
      navItems: navItems,
      task: const {
        'id': 'task-1',
        'title': 'Timeline task',
        'type': 'coding',
        'status': 'running',
        'description': 'Do work',
        'createdAt': '2026-03-10T10:00:00Z',
      },
      artifacts: const [],
      timelineHtml: sentinel,
    );

    expect(html, contains(sentinel));
  });

  test('omits timeline section when timelineHtml is null', () {
    final html = taskDetailPageTemplate(
      sidebarData: emptySidebar,
      navItems: navItems,
      task: const {
        'id': 'task-1',
        'title': 'No timeline task',
        'type': 'coding',
        'status': 'draft',
        'description': 'Do work',
        'createdAt': '2026-03-10T10:00:00Z',
      },
      artifacts: const [],
    );

    expect(html, isNot(contains('task-timeline')));
  });
}
