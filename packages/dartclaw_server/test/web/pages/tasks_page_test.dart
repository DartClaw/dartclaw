import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_server/src/templates/sidebar.dart';
import 'package:dartclaw_server/src/web/pages/tasks_page.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart' show SqliteTaskRepository, openTaskDbInMemory;
import 'package:shelf/shelf.dart';
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

  group('TasksPage', () {
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

    test('PageContext accepts taskService and eventBus fields', () {
      final context = PageContext(
        sessions: _StubSessionService(),
        appDisplay: const AppDisplayParams(),
        taskService: null,
        goalService: null,
        eventBus: null,
        buildSidebarData: () async => _emptySidebarData,
        restartBannerHtml: () => '',
        buildNavItems: ({required String activePage}) => [],
      );

      expect(context.taskService, isNull);
      expect(context.goalService, isNull);
      expect(context.eventBus, isNull);
    });

    test('default review list excludes workflow-owned review tasks and exposes toggle', () async {
      final db = openTaskDbInMemory();
      final taskService = TaskService(SqliteTaskRepository(db));
      addTearDown(() async {
        await taskService.dispose();
        db.close();
      });

      await taskService.create(
        id: 'task-review-normal',
        title: 'Normal review task',
        description: 'Review me',
        type: TaskType.coding,
        autoStart: true,
      );
      await taskService.transition('task-review-normal', TaskStatus.running);
      await taskService.transition('task-review-normal', TaskStatus.review);

      await taskService.create(
        id: 'task-review-workflow',
        title: 'Workflow review task',
        description: 'Workflow-owned review artifact',
        type: TaskType.coding,
        autoStart: true,
        workflowRunId: 'run-123',
        configJson: const {
          '_workflowGit': {'worktree': 'per-map-item', 'promotion': 'merge'},
        },
      );
      await taskService.transition('task-review-workflow', TaskStatus.running);
      await taskService.transition('task-review-workflow', TaskStatus.review);

      final context = PageContext(
        sessions: _StubSessionService(),
        appDisplay: const AppDisplayParams(),
        taskService: taskService,
        goalService: null,
        eventBus: null,
        buildSidebarData: () async => _emptySidebarData,
        restartBannerHtml: () => '',
        buildNavItems: ({required String activePage}) => [],
      );

      final response = await page.handler(Request('GET', Uri.parse('http://localhost/tasks?status=review')), context);
      final body = await response.readAsString();
      expect(body, contains('Normal review task'));
      expect(body, isNot(contains('Workflow review task')));
      expect(body, contains('Show workflow artifacts'));

      final includeResponse = await page.handler(
        Request('GET', Uri.parse('http://localhost/tasks?status=review&include=workflow')),
        context,
      );
      final includeBody = await includeResponse.readAsString();
      expect(includeBody, contains('Normal review task'));
      expect(includeBody, contains('Workflow review task'));
      expect(includeBody, contains('Hide workflow artifacts'));
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
);

class _StubSessionService implements SessionService {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
