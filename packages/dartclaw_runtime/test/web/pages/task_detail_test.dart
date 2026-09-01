import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_runtime/src/templates/sidebar.dart';
import 'package:dartclaw_runtime/src/templates/task_detail.dart';
import 'package:dartclaw_runtime/src/templates/tasks.dart';
import 'package:dartclaw_runtime/src/web/pages/tasks_page.dart';
import 'package:test/test.dart';

import '../../test_utils.dart';

void main() {
  late TasksPage page;

  setUpAll(() async {
    initTemplates(await resolveTemplatesDir());
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
        taskService: null,
        goalService: null,
        eventBus: null,
        messages: null,
        sidebarData: () async => _emptySidebarData,
        restartBannerHtml: () => '',
        buildNavItems: ({required String activePage}) => [],
      );

      expect(context.taskService, isNull);
      expect(context.goalService, isNull);
      expect(context.eventBus, isNull);
      expect(context.messages, isNull);
    });

    test('derives app identity from config and carries only runtime display facts', () {
      final context = PageContext(
        sessions: _StubSessionService(),
        config: const DartclawConfig(server: ServerConfig(name: 'Acme')),
        contentGuardApiKeyConfigured: true,
        contentGuardFailOpen: true,
        schedulingJobs: const [
          {'name': 'heartbeat'},
        ],
        systemJobNames: const ['heartbeat'],
        sidebarData: () async => _emptySidebarData,
        restartBannerHtml: () => '',
        buildNavItems: ({required String activePage}) => [],
      );
      final fallback = PageContext(
        sessions: _StubSessionService(),
        sidebarData: () async => _emptySidebarData,
        restartBannerHtml: () => '',
        buildNavItems: ({required String activePage}) => [],
      );

      expect(context.appName, 'Acme');
      expect(fallback.appName, 'DartClaw');
      expect(context.contentGuardApiKeyConfigured, isTrue);
      expect(context.contentGuardFailOpen, isTrue);
      expect(context.schedulingJobs.single['name'], 'heartbeat');
      expect(context.systemJobNames, ['heartbeat']);
    });
  });

  group('task create fragments', () {
    test('dialog and task panel retain the complete create surface', () {
      final panel = taskCreatePanelFragment(goalOptions: const [], projectOptions: const []);
      final dialog = taskCreateDialogFragment(
        goalOptions: const [],
        projectOptions: const [],
        workflowDefinitions: const [],
      );

      expect(dialog, contains('id="new-task-dialog"'));
      expect(dialog, contains('class="dialog dialog--md card card-glass"'));
      expect(dialog, contains(panel));
      for (final name in const [
        'title',
        'description',
        'acceptanceCriteria',
        'goalId',
        'autoStart',
        'model',
        'tokenBudget',
        'needsWorktree',
      ]) {
        expect(panel, contains('name="$name"'));
      }
      expect(RegExp('name="allowedTools"').allMatches(panel), hasLength(7));
      expect(panel, isNot(contains('name="type"')));
      expect(panel, isNot(contains('securityProfile')));
      expect(panel, isNot(contains('dialog-footer')));
      expect(dialog, contains('<div class="dialog-footer">'));
      expect(dialog, contains('form="new-task-panel"'));
      expect(dialog, contains('Create Task'));
      expect(dialog, contains('Cancel'));
    });

    test('goal options render in the task panel', () {
      final html = taskCreatePanelFragment(
        goalOptions: const [
          {'value': 'goal-1', 'label': 'Ship 0.25'},
        ],
        projectOptions: const [],
      );
      expect(html, contains('value="goal-1"'));
      expect(html, contains('Ship 0.25'));
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
          'status': 'draft',
          'description': 'Implement the feature',
          'createdAt': '2026-03-10T10:00:00Z',
        },
        artifacts: const [],
      );

      expect(html, contains('hx-post="/tasks/task-1/start"'));
      expect(html, contains('Start Task'));
    });

    test('renders queued state shell for live refresh', () {
      final html = taskDetailPageTemplate(
        sidebarData: _emptySidebarData,
        navItems: const [],
        task: {
          'id': 'task-queued',
          'title': 'Queued task',
          'status': 'queued',
          'description': 'Wait for a runner',
          'createdAt': '2026-03-10T10:00:00Z',
        },
        artifacts: const [],
      );

      expect(html, contains('id="tasks-content"'));
      expect(html, contains('Waiting for an available runner'));
      expect(html, contains('Task queued'));
      expect(html, contains('hx-post="/tasks/task-queued/cancel"'));
    });

    test('renders goal and push-back warning when present', () {
      final html = taskDetailPageTemplate(
        sidebarData: _emptySidebarData,
        navItems: const [],
        task: {
          'id': 'task-warning',
          'title': 'Needs help',
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

    test('does not render a completed timestamp for review tasks', () {
      final html = taskDetailPageTemplate(
        sidebarData: _emptySidebarData,
        navItems: const [],
        task: {
          'id': 'task-review',
          'title': 'Needs review',
          'status': 'review',
          'description': 'Check the generated changes',
          'createdAt': '2026-03-10T10:00:00Z',
          'startedAt': '2026-03-10T10:05:00Z',
        },
        artifacts: const [],
      );

      expect(html, contains('Started'));
      expect(html, isNot(contains('Completed')));
    });

    test('renders cancel action for running tasks', () {
      final html = taskDetailPageTemplate(
        sidebarData: _emptySidebarData,
        navItems: const [],
        task: {
          'id': 'task-running',
          'title': 'Long run',
          'status': 'running',
          'description': 'Keep going',
          'createdAt': '2026-03-10T10:00:00Z',
          'startedAt': '2026-03-10T10:05:00Z',
        },
        artifacts: const [],
      );

      expect(html, contains('hx-post="/tasks/task-running/cancel"'));
      expect(html, contains('Cancel Task'));
    });

    test('renders structured diff html when provided', () {
      final html = taskDetailPageTemplate(
        sidebarData: _emptySidebarData,
        navItems: const [],
        task: {
          'id': 'task-2',
          'title': 'Review task',
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
            'renderedHtml': '<div class="task-diff-summary">1 file changed</div><section class="task-diff-file"><strong>lib/main.dart</strong></section>',
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

final _emptySidebarData = (
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

class _StubSessionService implements SessionService {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
