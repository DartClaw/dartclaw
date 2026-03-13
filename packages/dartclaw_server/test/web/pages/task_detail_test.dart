import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_server/src/templates/sidebar.dart';
import 'package:dartclaw_server/src/templates/task_detail.dart';
import 'package:dartclaw_server/src/templates/task_form.dart';
import 'package:dartclaw_server/src/web/pages/tasks_page.dart';
import 'package:test/test.dart';

import '../../test_utils.dart';

void main() {
  late TasksPage page;

  setUpAll(() {
    initTemplates(resolveTemplatesDir());
  });

  tearDownAll(() {
    resetTemplates();
  });

  setUp(() {
    page = TasksPage();
  });

  group('TasksPage routing', () {
    test('route is /tasks', () {
      expect(page.route, '/tasks');
    });

    test('title is Tasks', () {
      expect(page.title, 'Tasks');
    });

    test('navGroup is system', () {
      expect(page.navGroup, 'system');
    });

    test('PageRegistry accepts /tasks route', () {
      final registry = PageRegistry();
      registry.register(page);
      expect(registry.resolve('/tasks'), same(page));
    });

    test('appears in sidebar nav items', () {
      final registry = PageRegistry()..register(page);
      final navItems = registry.navItems(activePage: 'Tasks');
      expect(navItems, isNotEmpty);
      expect(navItems.first.label, 'Tasks');
      expect(navItems.first.active, isTrue);
    });
  });

  group('PageContext', () {
    test('accepts taskService, eventBus, and messages fields', () {
      final context = PageContext(
        sessions: _StubSessionService(),
        appDisplay: const AppDisplayParams(),
        taskService: null,
        goalService: null,
        eventBus: null,
        messages: null,
        buildSidebarData: () async => _emptySidebarData,
        restartBannerHtml: () => '',
        buildNavItems: ({required String activePage}) => [],
      );

      expect(context.taskService, isNull);
      expect(context.goalService, isNull);
      expect(context.eventBus, isNull);
      expect(context.messages, isNull);
    });
  });

  group('newTaskFormDialogHtml', () {
    test('returns dialog with form fields', () {
      final html = newTaskFormDialogHtml();
      expect(html, contains('id="new-task-dialog"'));
      expect(html, contains('id="new-task-form"'));
      expect(html, contains('name="title"'));
      expect(html, contains('name="description"'));
      expect(html, contains('name="type"'));
      expect(html, contains('name="acceptanceCriteria"'));
      expect(html, contains('name="goalId"'));
      expect(html, contains('name="autoStart"'));
      expect(html, contains('name="model"'));
      expect(html, contains('name="tokenBudget"'));
      expect(html, contains('task-type-guidance'));
      expect(html, contains('Create Task'));
      expect(html, contains('Cancel'));
    });

    test('includes type options', () {
      final html = newTaskFormDialogHtml();
      expect(html, contains('value="coding"'));
      expect(html, contains('value="research"'));
      expect(html, contains('value="writing"'));
      expect(html, contains('value="analysis"'));
      expect(html, contains('value="automation"'));
      expect(html, contains('value="custom"'));
    });

    test('includes advanced section', () {
      final html = newTaskFormDialogHtml();
      expect(html, contains('Advanced'));
      expect(html, contains('Model Override'));
      expect(html, contains('Token Budget'));
    });

    test('renders provided goal options', () {
      final html = newTaskFormDialogHtml(
        goalOptions: const [
          {'value': 'goal-1', 'label': 'Ship 0.8'},
        ],
      );
      expect(html, contains('value="goal-1"'));
      expect(html, contains('Ship 0.8'));
    });
  });

  group('taskDetailPageTemplate', () {
    test('renders start control for draft tasks', () {
      final html = taskDetailPageTemplate(
        sidebarData: _emptySidebarData,
        navItems: const [],
        task: {
          'id': 'task-1',
          'title': 'Draft task',
          'type': 'coding',
          'status': 'draft',
          'description': 'Implement the feature',
          'createdAt': '2026-03-10T10:00:00Z',
        },
        artifacts: const [],
      );

      expect(html, contains('data-task-start'));
      expect(html, contains('Start Task'));
    });

    test('renders queued state shell for live refresh', () {
      final html = taskDetailPageTemplate(
        sidebarData: _emptySidebarData,
        navItems: const [],
        task: {
          'id': 'task-queued',
          'title': 'Queued task',
          'type': 'coding',
          'status': 'queued',
          'description': 'Wait for a runner',
          'createdAt': '2026-03-10T10:00:00Z',
        },
        artifacts: const [],
      );

      expect(html, contains('id="tasks-content"'));
      expect(html, contains('Waiting for an available runner'));
      expect(html, contains('Task queued'));
      expect(html, contains('data-task-cancel'));
    });

    test('renders goal and push-back warning when present', () {
      final html = taskDetailPageTemplate(
        sidebarData: _emptySidebarData,
        navItems: const [],
        task: {
          'id': 'task-warning',
          'title': 'Needs help',
          'type': 'research',
          'status': 'review',
          'goalTitle': 'Launch 0.8',
          'description': 'Investigate gaps',
          'createdAt': '2026-03-10T10:00:00Z',
          'pushBackCount': 3,
        },
        artifacts: const [],
      );

      expect(html, contains('Launch 0.8'));
      expect(html, contains('Push-backed'));
      expect(html, contains('pushed back multiple times'));
    });

    test('renders cancel action for running tasks', () {
      final html = taskDetailPageTemplate(
        sidebarData: _emptySidebarData,
        navItems: const [],
        task: {
          'id': 'task-running',
          'title': 'Long run',
          'type': 'analysis',
          'status': 'running',
          'description': 'Keep going',
          'createdAt': '2026-03-10T10:00:00Z',
          'startedAt': '2026-03-10T10:05:00Z',
        },
        artifacts: const [],
      );

      expect(html, contains('data-task-cancel'));
      expect(html, contains('Cancel Task'));
    });

    test('renders structured diff html when provided', () {
      final html = taskDetailPageTemplate(
        sidebarData: _emptySidebarData,
        navItems: const [],
        task: {
          'id': 'task-2',
          'title': 'Review task',
          'type': 'coding',
          'status': 'review',
          'description': 'Review generated code',
          'createdAt': '2026-03-10T10:00:00Z',
        },
        artifacts: const [
          {
            'id': 'artifact-1',
            'kind': 'diff',
            'name': 'diff.json',
            'content': '{"filesChanged":1}',
            'renderedHtml':
                '<div class="task-diff-summary">1 file changed</div><section class="task-diff-file"><strong>lib/main.dart</strong></section>',
          },
        ],
      );

      expect(html, contains('task-diff-summary'));
      expect(html, contains('lib/main.dart'));
      expect(html, contains('task-diff-file'));
    });

    test('renders merge conflict section when conflict data is provided', () {
      final html = taskDetailPageTemplate(
        sidebarData: _emptySidebarData,
        navItems: const [],
        task: {
          'id': 'task-conflict',
          'title': 'Conflict task',
          'type': 'coding',
          'status': 'review',
          'description': 'Resolve merge issue',
          'createdAt': '2026-03-10T10:00:00Z',
        },
        artifacts: const [],
        conflictData: const {
          'conflictingFiles': ['lib/main.dart', 'lib/utils.dart'],
          'details': 'Automatic merge failed',
        },
      );

      expect(html, contains('Merge Conflict'));
      expect(html, contains('lib/main.dart'));
      expect(html, contains('Resolve conflicts via git CLI in the worktree'));
    });
  });
}

const _emptySidebarData = (
  main: null,
  dmChannels: <SidebarSession>[],
  groupChannels: <SidebarSession>[],
  activeEntries: <SidebarSession>[],
  archivedEntries: <SidebarSession>[],
);

class _StubSessionService implements SessionService {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
