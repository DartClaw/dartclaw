import 'package:dartclaw_core/dartclaw_core.dart'
    show EventBus, TaskEvent, ToolCalled, TokenUpdate, ArtifactCreated, PushBack;
import 'package:dartclaw_server/src/task/task_progress_tracker.dart';
import 'package:dartclaw_server/src/task/task_service.dart';
import 'package:dartclaw_server/src/templates/loader.dart';
import 'package:dartclaw_server/src/templates/sidebar.dart';
import 'package:dartclaw_server/src/templates/tasks.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart' show SqliteTaskRepository, TaskEventService, openTaskDbInMemory;
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
  );
  const navItems = <NavItem>[(label: 'Tasks', href: '/tasks', active: true, navGroup: 'system', icon: 'tasks')];

  const runningTask = {
    'id': 'task-run',
    'title': 'Running task',
    'type': 'coding',
    'status': 'running',
    'provider': 'claude',
    'createdAt': '2026-03-24T10:00:00Z',
    'startedAt': '2026-03-24T10:01:00Z',
  };

  const reviewTask = {
    'id': 'task-rev',
    'title': 'Review task',
    'type': 'coding',
    'status': 'review',
    'provider': 'claude',
    'createdAt': '2026-03-24T10:00:00Z',
    'startedAt': '2026-03-24T10:01:00Z',
  };

  group('S11 running card enhancements', () {
    test('renders indeterminate progress bar when no token budget', () {
      final html = tasksPageTemplate(sidebarData: emptySidebar, navItems: navItems, tasks: const [runningTask]);

      expect(html, contains('task-progress-indeterminate'));
      expect(html, contains('task-progress'));
    });

    test('renders determinate progress bar with percentage when budget set', () {
      final tracker = _stubTrackerWithTokens('task-run', tokensUsed: 5000, tokenBudget: 10000);
      final html = tasksPageTemplate(
        sidebarData: emptySidebar,
        navItems: navItems,
        tasks: const [runningTask],
        progressTracker: tracker,
      );

      expect(html, contains('width:50%'));
      expect(html, isNot(contains('task-progress-indeterminate')));
    });

    test('renders token display text for running task', () {
      final tracker = _stubTrackerWithTokens('task-run', tokensUsed: 1500, tokenBudget: 10000);
      final html = tasksPageTemplate(
        sidebarData: emptySidebar,
        navItems: navItems,
        tasks: const [runningTask],
        progressTracker: tracker,
      );

      expect(html, contains('1.5K'));
    });

    test('renders fallback token display when no tracker snapshot', () {
      final html = tasksPageTemplate(sidebarData: emptySidebar, navItems: navItems, tasks: const [runningTask]);

      expect(html, contains('0 tokens'));
    });

    test('renders agent badge when runner is assigned to task', () {
      final html = tasksPageTemplate(
        sidebarData: emptySidebar,
        navItems: navItems,
        tasks: const [runningTask],
        agentRunners: const [
          {
            'runnerId': 2,
            'role': 'task',
            'state': 'busy',
            'currentTaskId': 'task-run',
            'providerId': 'claude',
            'tokensConsumed': 0,
            'turnsCompleted': 0,
            'errorCount': 0,
          },
        ],
        agentPool: const {'size': 2, 'activeCount': 1, 'availableCount': 1, 'maxConcurrentTasks': 2},
      );

      expect(html, contains('task-agent-badge'));
      expect(html, contains('Agent #2'));
    });

    test('agent badge shows Primary label for primary role runner', () {
      final html = tasksPageTemplate(
        sidebarData: emptySidebar,
        navItems: navItems,
        tasks: const [runningTask],
        agentRunners: const [
          {
            'runnerId': 0,
            'role': 'primary',
            'state': 'busy',
            'currentTaskId': 'task-run',
            'providerId': 'claude',
            'tokensConsumed': 0,
            'turnsCompleted': 0,
            'errorCount': 0,
          },
        ],
        agentPool: const {'size': 1, 'activeCount': 1, 'availableCount': 0, 'maxConcurrentTasks': 1},
      );

      expect(html, contains('task-agent-badge'));
      expect(html, contains('Primary (#0)'));
    });

    test('no agent badge when no runner assigned to task', () {
      final html = tasksPageTemplate(
        sidebarData: emptySidebar,
        navItems: navItems,
        tasks: const [runningTask],
        agentRunners: const [
          {
            'runnerId': 1,
            'role': 'task',
            'state': 'idle',
            'currentTaskId': null,
            'providerId': 'claude',
            'tokensConsumed': 0,
            'turnsCompleted': 0,
            'errorCount': 0,
          },
        ],
        agentPool: const {'size': 1, 'activeCount': 0, 'availableCount': 1, 'maxConcurrentTasks': 1},
      );

      expect(html, isNot(contains('task-agent-badge')));
    });

    test('renders compact events section when task has recent events', () {
      final db = openTaskDbInMemory();
      final eventService = TaskEventService(db);
      eventService.insert(
        TaskEvent(
          id: 'evt-1',
          taskId: 'task-run',
          timestamp: DateTime.parse('2026-03-24T10:02:00Z'),
          kind: const ToolCalled(),
          details: {'name': 'Bash', 'success': true},
        ),
      );

      final html = tasksPageTemplate(
        sidebarData: emptySidebar,
        navItems: navItems,
        tasks: const [runningTask],
        taskEventService: eventService,
      );

      expect(html, contains('task-events'));
      expect(html, contains('task-event-icon'));
      expect(html, contains('Bash'));
    });

    test('omits events section when task has no recent events', () {
      final html = tasksPageTemplate(sidebarData: emptySidebar, navItems: navItems, tasks: const [runningTask]);

      expect(html, isNot(contains('task-events')));
    });

    test('compact events limited to last 3', () {
      final db = openTaskDbInMemory();
      final eventService = TaskEventService(db);
      for (var i = 1; i <= 5; i++) {
        eventService.insert(
          TaskEvent(
            id: 'evt-$i',
            taskId: 'task-run',
            timestamp: DateTime.parse('2026-03-24T10:0$i:00Z'),
            kind: const ToolCalled(),
            details: {'name': 'Tool$i', 'success': true},
          ),
        );
      }

      final html = tasksPageTemplate(
        sidebarData: emptySidebar,
        navItems: navItems,
        tasks: const [runningTask],
        taskEventService: eventService,
      );

      // Most recent 3 events shown (most-recent-first): Tool5, Tool4, Tool3.
      expect(html, contains('Tool3'));
      expect(html, contains('Tool4'));
      expect(html, contains('Tool5'));
      expect(html, isNot(contains('Tool1')));
      expect(html, isNot(contains('Tool2')));
    });

    test('event icon classes are set per kind', () {
      final db = openTaskDbInMemory();
      final eventService = TaskEventService(db);
      eventService.insert(
        TaskEvent(
          id: 'evt-tool',
          taskId: 'task-run',
          timestamp: DateTime.parse('2026-03-24T10:02:00Z'),
          kind: const ToolCalled(),
          details: {'name': 'Read', 'success': true},
        ),
      );
      eventService.insert(
        TaskEvent(
          id: 'evt-artifact',
          taskId: 'task-run',
          timestamp: DateTime.parse('2026-03-24T10:03:00Z'),
          kind: const ArtifactCreated(),
          details: {'name': 'output.md', 'kind': 'document'},
        ),
      );

      final html = tasksPageTemplate(
        sidebarData: emptySidebar,
        navItems: navItems,
        tasks: const [runningTask],
        taskEventService: eventService,
      );

      expect(html, contains('task-event-icon-tool'));
      expect(html, contains('task-event-icon-artifact'));
    });
  });

  group('S11 non-running task token column', () {
    test('Tokens column header present in non-running table', () {
      final html = tasksPageTemplate(sidebarData: emptySidebar, navItems: navItems, tasks: const [reviewTask]);

      expect(html, contains('<th class="task-col-tokens">Tokens</th>'));
    });

    test('shows dash when task has no token events', () {
      final html = tasksPageTemplate(sidebarData: emptySidebar, navItems: navItems, tasks: const [reviewTask]);

      expect(html, contains('task-tokens-static'));
      expect(html, contains('—'));
    });

    test('shows formatted token total from token events', () {
      final db = openTaskDbInMemory();
      final eventService = TaskEventService(db);
      eventService.insert(
        TaskEvent(
          id: 'evt-tok',
          taskId: 'task-rev',
          timestamp: DateTime.parse('2026-03-24T10:05:00Z'),
          kind: const TokenUpdate(),
          details: {'inputTokens': 8000, 'outputTokens': 2000},
        ),
      );

      final html = tasksPageTemplate(
        sidebarData: emptySidebar,
        navItems: navItems,
        tasks: const [reviewTask],
        taskEventService: eventService,
      );

      expect(html, contains('task-tokens-static'));
      expect(html, contains('10.0K'));
    });

    test('sums multiple token events for total', () {
      final db = openTaskDbInMemory();
      final eventService = TaskEventService(db);
      eventService.insert(
        TaskEvent(
          id: 'evt-tok-1',
          taskId: 'task-rev',
          timestamp: DateTime.parse('2026-03-24T10:05:00Z'),
          kind: const TokenUpdate(),
          details: {'inputTokens': 1000, 'outputTokens': 500},
        ),
      );
      eventService.insert(
        TaskEvent(
          id: 'evt-tok-2',
          taskId: 'task-rev',
          timestamp: DateTime.parse('2026-03-24T10:06:00Z'),
          kind: const TokenUpdate(),
          details: {'inputTokens': 500, 'outputTokens': 250},
        ),
      );

      final html = tasksPageTemplate(
        sidebarData: emptySidebar,
        navItems: navItems,
        tasks: const [reviewTask],
        taskEventService: eventService,
      );

      // Total: 1000+500+500+250 = 2250 → 2.3K
      expect(html, contains('2.3K'));
    });

    test('non-tool events on running task do not affect non-running token count', () {
      final db = openTaskDbInMemory();
      final eventService = TaskEventService(db);
      // Insert a pushback event — should not count as tokens
      eventService.insert(
        TaskEvent(
          id: 'evt-push',
          taskId: 'task-rev',
          timestamp: DateTime.parse('2026-03-24T10:07:00Z'),
          kind: const PushBack(),
          details: {'comment': 'Fix this'},
        ),
      );

      final html = tasksPageTemplate(
        sidebarData: emptySidebar,
        navItems: navItems,
        tasks: const [reviewTask],
        taskEventService: eventService,
      );

      // No token events → should show dash
      expect(html, contains('—'));
    });
  });
}

/// Creates a [TaskProgressTracker] seeded with [tokensUsed] (and optionally
/// [tokenBudget]) for [taskId].
TaskProgressTracker _stubTrackerWithTokens(String taskId, {required int tokensUsed, int? tokenBudget}) {
  final eventBus = EventBus();
  final tasks = TaskService(SqliteTaskRepository(openTaskDbInMemory()));
  final tracker = TaskProgressTracker(eventBus: eventBus, tasks: tasks);
  tracker.seedFromEvents(taskId, [
    {
      'kind': 'tokenUpdate',
      'details': {'inputTokens': tokensUsed, 'outputTokens': 0},
    },
  ], tokenBudget: tokenBudget);
  return tracker;
}
