import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_server/src/templates/sidebar.dart';
import 'package:dartclaw_server/src/web/pages/workflows_page.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart'
    show SqliteTaskRepository, SqliteWorkflowRunRepository, openTaskDbInMemory;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../../test_utils.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

WorkflowDefinition _makeDefinition({String name = 'spec-and-implement'}) {
  return WorkflowDefinition(
    name: name,
    description: 'test',
    variables: const {},
    steps: const [
      WorkflowStep(id: 'research', name: 'Research', prompts: ['research']),
      WorkflowStep(id: 'implement', name: 'Implement', prompts: ['implement']),
    ],
  );
}


const _emptySidebarData = (
  main: null,
  dmChannels: <SidebarSession>[],
  groupChannels: <SidebarSession>[],
  activeEntries: <SidebarSession>[],
  archivedEntries: <SidebarSession>[],
  showChannels: false,
  tasksEnabled: false,
);

class _StubSessionService implements SessionService {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

PageContext _makeContext({
  WorkflowService? workflowService,
  TaskService? taskService,
  WorkflowDefinitionSource? definitionSource,
}) {
  return PageContext(
    sessions: _StubSessionService(),
    appDisplay: const AppDisplayParams(),
    taskService: taskService,
    workflowService: workflowService,
    definitionSource: definitionSource,
    buildSidebarData: () async => _emptySidebarData,
    restartBannerHtml: () => '',
    buildNavItems: ({required String activePage}) => [],
  );
}

/// Builds a Request for the given path.
Request _get(String path) => Request('GET', Uri.parse('http://localhost$path'));

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late WorkflowsPage page;
  late Database taskDb;
  late Database workflowDb;
  late TaskService tasks;
  late WorkflowService workflows;
  late Directory tempDir;

  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  setUp(() async {
    page = WorkflowsPage();
    taskDb = openTaskDbInMemory();
    workflowDb = sqlite3.openInMemory();
    tempDir = Directory.systemTemp.createTempSync('wf_page_test_');

    final taskRepo = SqliteTaskRepository(taskDb);
    final eventBus = EventBus();
    tasks = TaskService(taskRepo, eventBus: eventBus);

    final workflowRepo = SqliteWorkflowRunRepository(workflowDb);
    final messages = MessageService(baseDir: p.join(tempDir.path, 'sessions'));
    final kv = KvService(filePath: p.join(tempDir.path, 'kv.json'));
    workflows = WorkflowService(
      repository: workflowRepo,
      taskService: tasks,
      messageService: messages,
      eventBus: eventBus,
      kvService: kv,
      dataDir: tempDir.path,
    );
  });

  tearDown(() async {
    await workflows.dispose();
    await tasks.dispose();
    taskDb.close();
    workflowDb.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('WorkflowsPage metadata', () {
    test('route is /workflows', () {
      expect(page.route, '/workflows');
    });

    test('title is Workflows', () {
      expect(page.title, 'Workflows');
    });

    test('navGroup is system', () {
      expect(page.navGroup, 'system');
    });

    test('PageRegistry accepts /workflows route', () {
      final registry = PageRegistry();
      registry.register(page);
      expect(registry.resolve('/workflows'), same(page));
    });
  });

  group('WorkflowsPage /workflows (management page)', () {
    test('returns graceful message when workflowService is null', () async {
      final context = _makeContext();
      final response = await page.handler(_get('/workflows'), context);
      expect(response.statusCode, 200);
      final body = await response.readAsString();
      expect(body, contains('not configured'));
    });

    test('returns 200 with management page HTML when workflowService provided', () async {
      final context = _makeContext(workflowService: workflows, taskService: tasks);
      final response = await page.handler(_get('/workflows'), context);
      expect(response.statusCode, 200);
      final body = await response.readAsString();
      expect(body, contains('workflow-list-page'));
    });

    test('shows "No workflow runs found" when no runs exist', () async {
      final context = _makeContext(workflowService: workflows, taskService: tasks);
      final response = await page.handler(_get('/workflows'), context);
      final body = await response.readAsString();
      expect(body, contains('No workflow runs found'));
    });

    test('shows workflow runs when runs exist', () async {
      final def = _makeDefinition();
      await workflows.start(def, const {});

      final context = _makeContext(workflowService: workflows, taskService: tasks);
      final response = await page.handler(_get('/workflows'), context);
      final body = await response.readAsString();
      expect(body, contains('spec-and-implement'));
    });

    test('status filter passes to service query', () async {
      final def = _makeDefinition();
      await workflows.start(def, const {});
      final paused = (await workflows.list()).first;
      await workflows.pause(paused.id);

      // Running filter should show nothing (only run is paused).
      final context = _makeContext(workflowService: workflows, taskService: tasks);
      final response = await page.handler(_get('/workflows?status=running'), context);
      final body = await response.readAsString();
      expect(body, contains('No workflow runs found'));
    });

    test('definition filter passes to service query', () async {
      final def = _makeDefinition(name: 'fix-bug');
      await workflows.start(def, const {});

      final context = _makeContext(workflowService: workflows, taskService: tasks);
      // Filter for a different definition — should return no runs.
      final response = await page.handler(
        _get('/workflows?definition=spec-and-implement'),
        context,
      );
      final body = await response.readAsString();
      expect(body, contains('No workflow runs found'));
    });

    test('definition browser shows available definitions', () async {
      final source = InMemoryDefinitionSource([_makeDefinition()]);
      final context = _makeContext(
        workflowService: workflows,
        taskService: tasks,
        definitionSource: source,
      );
      final response = await page.handler(_get('/workflows'), context);
      final body = await response.readAsString();
      expect(body, contains('workflow-definitions-section'));
      expect(body, contains('spec-and-implement'));
    });

    test('status filter buttons rendered in page', () async {
      final context = _makeContext(workflowService: workflows, taskService: tasks);
      final response = await page.handler(_get('/workflows'), context);
      final body = await response.readAsString();
      expect(body, contains('Running'));
      expect(body, contains('Completed'));
    });
  });

  group('WorkflowsPage /workflows/<runId>', () {
    test('returns 503 when workflowService is null', () async {
      final context = _makeContext(taskService: tasks);
      final response = await page.handler(_get('/workflows/run-001'), context);
      expect(response.statusCode, 503);
    });

    test('returns 503 when taskService is null', () async {
      final context = _makeContext(workflowService: workflows);
      final response = await page.handler(_get('/workflows/run-001'), context);
      expect(response.statusCode, 503);
    });

    test('returns 404 when run not found', () async {
      final context = _makeContext(workflowService: workflows, taskService: tasks);
      final response = await page.handler(_get('/workflows/nonexistent'), context);
      expect(response.statusCode, 404);
    });

    test('returns 200 with workflow HTML for known run', () async {
      final def = _makeDefinition();
      await workflows.start(def, const {});
      final runs = await workflows.list();
      expect(runs, isNotEmpty);
      final runId = runs.first.id;

      final context = _makeContext(workflowService: workflows, taskService: tasks);
      final response = await page.handler(_get('/workflows/$runId'), context);
      expect(response.statusCode, 200);
      final body = await response.readAsString();
      expect(body, contains('workflow-detail-page'));
      expect(body, contains('spec-and-implement'));
    });

    test('renders step cards for all definition steps', () async {
      final def = _makeDefinition();
      await workflows.start(def, const {});
      final runs = await workflows.list();
      final runId = runs.first.id;

      final context = _makeContext(workflowService: workflows, taskService: tasks);
      final response = await page.handler(_get('/workflows/$runId'), context);
      final body = await response.readAsString();
      expect(RegExp(r'workflow-step-card').allMatches(body).length, 2);
    });
  });

  group('WorkflowsPage /workflows/<runId>/steps/<stepIndex>', () {
    test('returns 400 for invalid step index', () async {
      final context = _makeContext(workflowService: workflows, taskService: tasks);
      final response = await page.handler(
        _get('/workflows/run-001/steps/notanumber'),
        context,
      );
      expect(response.statusCode, 400);
    });

    test('returns 503 when services not configured', () async {
      final context = _makeContext();
      final response = await page.handler(
        _get('/workflows/run-001/steps/0'),
        context,
      );
      expect(response.statusCode, 503);
    });

    test('returns 404 when run not found', () async {
      final context = _makeContext(workflowService: workflows, taskService: tasks);
      final response = await page.handler(
        _get('/workflows/nonexistent/steps/0'),
        context,
      );
      expect(response.statusCode, 404);
    });

    test('returns step detail fragment for known run', () async {
      final def = _makeDefinition();
      await workflows.start(def, const {});
      final runs = await workflows.list();
      final runId = runs.first.id;

      final context = _makeContext(workflowService: workflows, taskService: tasks);
      final response = await page.handler(
        _get('/workflows/$runId/steps/0'),
        context,
      );
      expect(response.statusCode, 200);
      final body = await response.readAsString();
      expect(body, contains('workflow-step-detail-content'));
    });
  });
}
