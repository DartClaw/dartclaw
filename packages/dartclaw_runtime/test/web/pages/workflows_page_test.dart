import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:io';

import 'package:dartclaw_workflow/testing.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowTaskType;

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_runtime/src/templates/sidebar.dart';
import 'package:dartclaw_runtime/src/web/pages/workflows_page.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        SqliteWorkflowRunRepository,
        WorkflowDefinition,
        WorkflowDefinitionSource,
        WorkflowRun,
        WorkflowService,
        WorkflowStep,
        WorkflowVariable;
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
      WorkflowStep(id: 'research', name: 'Research', taskType: WorkflowTaskType.approval, prompts: ['research']),
      WorkflowStep(id: 'implement', name: 'Implement', taskType: WorkflowTaskType.approval, prompts: ['implement']),
    ],
  );
}

final _emptySidebarData = (
  main: null,
  dmChannels: <SidebarSession>[],
  groupChannels: <SidebarSession>[],
  activeEntries: <SidebarSession>[],
  archivedEntries: <SidebarSession>[],
  activeTasks: <SidebarActiveTask>[],
  activeWorkflows: <SidebarActiveWorkflow>[],
  showChannels: false,
  tasksEnabled: false,
  activeSessionId: null,
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
    taskService: taskService,
    workflowService: workflowService,
    definitionSource: definitionSource,
    sidebarData: () async => _emptySidebarData,
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
  late SqliteWorkflowRunRepository workflowRepo;
  late TaskService tasks;
  late WorkflowService workflows;
  late Directory tempDir;

  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  setUp(() async {
    page = WorkflowsPage();
    taskDb = openTaskDbInMemory();
    workflowDb = sqlite3.openInMemory();
    tempDir = Directory.systemTemp.createTempSync('wf_page_test_');

    final taskRepo = SqliteTaskRepository(taskDb);
    final eventBus = EventBus();
    tasks = TaskService(taskRepo, eventBus: eventBus);

    workflowRepo = SqliteWorkflowRunRepository(workflowDb);
    final messages = MessageService(baseDir: p.join(tempDir.path, 'sessions'));
    final kv = KvService(filePath: p.join(tempDir.path, 'kv.json'));
    workflows = WorkflowService.lifecycleOnly(
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

    test('declares detail, step detail, and step card routes', () {
      expect(page.declaredRoutes, const [
        (method: 'GET', path: '/workflows/<runId>'),
        (method: 'GET', path: '/workflows/<runId>/steps/<stepIndex>'),
        (method: 'GET', path: '/workflows/<runId>/steps/<stepIndex>/card'),
      ]);
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

    test('S03 malformed stored definition reports an absent step count on list and detail', () async {
      final now = DateTime.parse('2026-03-24T10:00:00Z');
      await workflowRepo.insert(
        WorkflowRun(
          id: 'run-malformed',
          definitionName: 'broken-definition',
          status: WorkflowRunStatus.completed,
          startedAt: now,
          updatedAt: now,
          definitionJson: const {'name': 42},
        ),
      );
      final context = _makeContext(workflowService: workflows, taskService: tasks);
      final list = await (await page.handler(_get('/workflows'), context)).readAsString();
      final detail = await (await page.handler(_get('/workflows/run-malformed'), context)).readAsString();
      expect(list, contains('class="value-absent"'));
      expect(detail, contains('class="value-absent"'));
      expect(detail, isNot(contains('class="meter"')));
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
      final response = await page.handler(_get('/workflows?definition=spec-and-implement'), context);
      final body = await response.readAsString();
      expect(body, contains('No workflow runs found'));
    });

    test('empty definition filter shows all workflows while retaining status', () async {
      final now = DateTime.now();
      for (final name in ['first-workflow', 'second-workflow']) {
        await workflowRepo.insert(
          WorkflowRun(
            id: 'run-$name',
            definitionName: name,
            status: WorkflowRunStatus.running,
            startedAt: now,
            updatedAt: now,
            definitionJson: _makeDefinition(name: name).toJson(),
          ),
        );
      }
      final context = _makeContext(workflowService: workflows, taskService: tasks);

      final response = await page.handler(_get('/workflows?status=running&definition='), context);
      final body = await response.readAsString();

      expect(body, contains('first-workflow'));
      expect(body, contains('second-workflow'));
      expect(body, contains('name="status" value="running"'));
      expect(body, contains('<option value="">All workflows</option>'));
    });

    test('definition filter is declared in markup and keeps active status', () async {
      final definitions = InMemoryDefinitionSource([_makeDefinition()]);
      final context = _makeContext(workflowService: workflows, taskService: tasks, definitionSource: definitions);
      final response = await page.handler(_get('/workflows?status=running'), context);
      final body = await response.readAsString();

      expect(body, contains('name="status" value="running"'));
      expect(body, contains('id="workflow-definition-filter" name="definition"'));
      expect(body, contains('hx-get="/workflows"'));
      expect(body, contains('hx-include="closest form"'));
    });

    test('definition browser shows available definitions', () async {
      final source = InMemoryDefinitionSource([_makeDefinition()]);
      final context = _makeContext(workflowService: workflows, taskService: tasks, definitionSource: source);
      final response = await page.handler(_get('/workflows'), context);
      final body = await response.readAsString();
      expect(body, contains('workflow-definitions-section'));
      expect(body, contains('spec-and-implement'));
    });

    test('definition browser renders variable hints without loading prompt bodies', () async {
      final source = InMemoryDefinitionSource([
        WorkflowDefinition(
          name: 'my-workflow',
          description: 'A workflow',
          variables: const {'FEATURE': WorkflowVariable(required: true, description: 'Feature to implement')},
          steps: const [
            WorkflowStep(id: 's1', name: 'Step 1', prompts: ['long prompt body']),
          ],
        ),
      ]);
      final context = _makeContext(workflowService: workflows, taskService: tasks, definitionSource: source);
      final response = await page.handler(_get('/workflows'), context);
      final body = await response.readAsString();
      expect(body, contains('my-workflow'));
      expect(body, contains('FEATURE'));
      expect(body, contains('Feature to implement'));
      // Prompt body must NOT appear in the browser listing.
      expect(body, isNot(contains('long prompt body')));
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
      expect(RegExp(r'class="pipeline-step ').allMatches(body).length, 2);
    });

    test('renders timed-out approval state without flattening it to pending', () async {
      final now = DateTime.parse('2026-03-24T10:00:00Z');
      final def = WorkflowDefinition(
        name: 'approval-wf',
        description: 'With approval gate.',
        steps: const [
          WorkflowStep(id: 'gate', name: 'Gate', taskType: WorkflowTaskType.approval, prompts: ['Approve?']),
          WorkflowStep(id: 'next', name: 'Next', prompts: ['Continue']),
        ],
      );
      await workflowRepo.insert(
        WorkflowRun(
          id: 'run-timeout',
          definitionName: 'approval-wf',
          status: WorkflowRunStatus.cancelled,
          startedAt: now,
          updatedAt: now,
          currentStepIndex: 1,
          definitionJson: def.toJson(),
          contextJson: {
            'data': <String, dynamic>{},
            'variables': <String, dynamic>{},
            'gate.status': 'cancelled',
            'gate.approval.status': 'timed_out',
            'gate.approval.message': 'Approve?',
            'gate.approval.cancel_reason': 'timeout',
            'gate.tokenCount': 0,
          },
        ),
      );

      final context = _makeContext(workflowService: workflows, taskService: tasks);
      final response = await page.handler(_get('/workflows/run-timeout'), context);
      final body = await response.readAsString();

      expect(response.statusCode, 200);
      expect(body, contains('timed_out'));
      expect(body, contains('timeout'));
    });
  });

  group('WorkflowsPage /workflows/<runId>/steps/<stepIndex>', () {
    test('returns 400 for invalid step index', () async {
      final context = _makeContext(workflowService: workflows, taskService: tasks);
      final response = await page.handler(_get('/workflows/run-001/steps/notanumber'), context);
      expect(response.statusCode, 400);
    });

    test('returns 400 for negative step index', () async {
      final context = _makeContext(workflowService: workflows, taskService: tasks);
      final response = await page.handler(_get('/workflows/run-001/steps/-1'), context);
      expect(response.statusCode, 400);
      expect(await response.readAsString(), 'Invalid step index');
    });

    test('returns 400 for out-of-range step index', () async {
      await workflows.start(_makeDefinition(), const {});
      final runId = (await workflows.list()).first.id;
      final context = _makeContext(workflowService: workflows, taskService: tasks);
      final response = await page.handler(_get('/workflows/$runId/steps/2'), context);
      expect(response.statusCode, 400);
      expect(await response.readAsString(), 'Invalid step index');
    });

    test('returns 503 when services not configured', () async {
      final context = _makeContext();
      final response = await page.handler(_get('/workflows/run-001/steps/0'), context);
      expect(response.statusCode, 503);
    });

    test('returns 404 when run not found', () async {
      final context = _makeContext(workflowService: workflows, taskService: tasks);
      final response = await page.handler(_get('/workflows/nonexistent/steps/0'), context);
      expect(response.statusCode, 404);
    });

    test('returns step detail fragment for known run', () async {
      final def = _makeDefinition();
      await workflows.start(def, const {});
      final runs = await workflows.list();
      final runId = runs.first.id;

      final context = _makeContext(workflowService: workflows, taskService: tasks);
      final response = await page.handler(_get('/workflows/$runId/steps/0'), context);
      expect(response.statusCode, 200);
      final body = await response.readAsString();
      expect(body, contains('workflow-step-detail-content'));
    });
  });

  group('WorkflowsPage step card fragment', () {
    test('matches the full page card and carries progress out of band', () async {
      await workflows.start(_makeDefinition(), const {});
      final runId = (await workflows.list()).first.id;
      final context = _makeContext(workflowService: workflows, taskService: tasks);
      final full = await (await page.handler(_get('/workflows/$runId'), context)).readAsString();
      final response = await page.handler(_get('/workflows/$runId/steps/0/card'), context);
      final fragment = await response.readAsString();
      final cardStart = full.indexOf('<li class="pipeline-step');
      final cardEnd = full.indexOf('</li>', cardStart) + '</li>'.length;

      expect(response.statusCode, 200);
      expect(cardStart, greaterThanOrEqualTo(0));
      expect(fragment, startsWith(full.substring(cardStart, cardEnd)));
      expect(fragment, contains('id="workflow-step-0"'));
      expect(fragment, contains('data-step-index="0"'));
      expect(fragment, contains('data-step-id="research"'));
      expect(fragment, contains('data-step-status='));
      expect(fragment, contains('id="workflow-progress"'));
      expect(fragment, contains('hx-swap-oob="outerHTML"'));
      expect(fragment, contains('<span>0</span> / <span>2</span> steps complete'));
    });

    test('refuses an out-of-range card like the step detail route', () async {
      await workflows.start(_makeDefinition(), const {});
      final runId = (await workflows.list()).first.id;
      final context = _makeContext(workflowService: workflows, taskService: tasks);

      final response = await page.handler(_get('/workflows/$runId/steps/2/card'), context);

      expect(response.statusCode, 400);
      expect(await response.readAsString(), 'Invalid step index');
    });
  });
}
