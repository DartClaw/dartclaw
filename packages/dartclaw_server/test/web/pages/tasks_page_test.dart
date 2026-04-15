import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_server/src/templates/sidebar.dart';
import 'package:dartclaw_server/src/web/pages/tasks_page.dart';
import 'package:test/test.dart';

void main() {
  late TasksPage page;

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
