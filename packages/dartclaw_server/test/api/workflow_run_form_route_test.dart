import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show InMemoryDefinitionSource, WorkflowDefinition, WorkflowRun, WorkflowRunStatus, WorkflowStep, WorkflowVariable;
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'workflow_test_support.dart';

void main() {
  late Database taskDb;
  late SqliteTaskRepository taskRepo;
  late TaskService tasks;
  late FakeWorkflowService workflows;
  late Handler handler;

  setUp(() {
    taskDb = openTaskDbInMemory();
    taskRepo = SqliteTaskRepository(taskDb);
    final eventBus = EventBus();
    tasks = TaskService(taskRepo, eventBus: eventBus);
    workflows = FakeWorkflowService(
      db: sqlite3.openInMemory(),
      taskService: tasks,
      eventBus: eventBus,
      dataDir: '/tmp/workflow-run-form-data',
    );
    workflows.startResult = WorkflowRun(
      id: 'run-1',
      definitionName: 'spec-and-implement',
      status: WorkflowRunStatus.running,
      startedAt: DateTime.utc(2026, 1, 1, 12),
      updatedAt: DateTime.utc(2026, 1, 1, 12),
      definitionJson: const {},
    );
    final definitions = InMemoryDefinitionSource([
      WorkflowDefinition(
        name: 'spec-and-implement',
        description: 'Demo',
        variables: const {'FEATURE': WorkflowVariable(required: true, description: 'Feature to build')},
        steps: const [
          WorkflowStep(id: 'step-1', name: 'Plan', prompts: ['Plan']),
        ],
      ),
    ]);
    handler = workflowRoutes(workflows, tasks, definitions).call;
  });

  tearDown(() async {
    await workflows.dispose();
    await tasks.dispose();
    taskDb.close();
  });

  test('POST /api/workflows/run-form returns HX-Location on success', () async {
    final response = await handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/workflows/run-form'),
        headers: {'content-type': 'application/x-www-form-urlencoded', 'HX-Request': 'true'},
        body: 'definition=spec-and-implement&var_FEATURE=Ship+CLI',
      ),
    );

    expect(response.statusCode, 201);
    expect(response.headers['HX-Location'], startsWith('/workflows/'));
  });

  test('POST /api/workflows/run-form returns swappable 200 fragment for validation errors', () async {
    final response = await handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/workflows/run-form'),
        headers: {'content-type': 'application/x-www-form-urlencoded', 'HX-Request': 'true'},
        body: 'definition=spec-and-implement',
      ),
    );

    // 200 (not 4xx) so HTMX's default responseHandling swaps the fragment into hx-target.
    expect(response.statusCode, 200);
    final body = await response.readAsString();
    expect(body, contains('form-error-text'));
    expect(body, contains('Missing required variable'));
  });

  test('POST /api/workflows/run rejects oversized streamed JSON body', () async {
    final response = await handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/workflows/run'),
        headers: {'content-type': 'application/json'},
        body: Stream<List<int>>.fromIterable([
          utf8.encode('{"definition":"spec-and-implement","variables":{"FEATURE":"'),
          utf8.encode('x' * (256 * 1024)),
          utf8.encode('"}}'),
        ]),
      ),
    );

    expect(response.statusCode, 413);
    expect(await response.readAsString(), contains('REQUEST_TOO_LARGE'));
    expect(workflows.startCalls, isZero);
  });

  test('POST /api/workflows/run-form rejects oversized streamed form body', () async {
    final response = await handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/workflows/run-form'),
        headers: {'content-type': 'application/x-www-form-urlencoded', 'HX-Request': 'true'},
        body: Stream<List<int>>.fromIterable([
          utf8.encode('definition=spec-and-implement&var_FEATURE='),
          utf8.encode('x' * (256 * 1024)),
        ]),
      ),
    );

    expect(response.statusCode, 413);
    expect(await response.readAsString(), contains('REQUEST_TOO_LARGE'));
    expect(workflows.startCalls, isZero);
  });

  test('POST /api/workflows/run-form rejects malformed UTF-8 body', () async {
    final response = await handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/workflows/run-form'),
        headers: {'content-type': 'application/x-www-form-urlencoded', 'HX-Request': 'true'},
        body: Stream<List<int>>.fromIterable([
          [0xff],
        ]),
      ),
    );

    expect(response.statusCode, 400);
    expect(await response.readAsString(), contains('valid UTF-8'));
    expect(workflows.startCalls, isZero);
  });

  test('POST /api/workflows/run-form returns swappable 200 fragment for precondition failures', () async {
    workflows.startError = StateError(
      'Local-path project "alpha" is not safe to mutate: observed branch "feature/local", expected "main", dirty path count 1. Re-run with --allow-dirty-localpath to override.',
    );

    final response = await handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/workflows/run-form'),
        headers: {'content-type': 'application/x-www-form-urlencoded', 'HX-Request': 'true'},
        body: 'definition=spec-and-implement&var_FEATURE=Ship+CLI',
      ),
    );

    // Precondition StateError is a 409 on the JSON API, but the web form needs 200 to swap.
    expect(response.statusCode, 200);
    final body = await response.readAsString();
    expect(body, contains('form-error-text'));
    expect(body, contains('Local-path project'));
  });

  test('POST /api/workflows/run-form returns swappable 200 fragment for remote ref precondition failures', () async {
    workflows.startError = StateError(
      "git fetch failed for \"alpha\" (ref: missing/ref): fatal: couldn't find remote ref",
    );

    final response = await handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/workflows/run-form'),
        headers: {'content-type': 'application/x-www-form-urlencoded', 'HX-Request': 'true'},
        body: 'definition=spec-and-implement&var_FEATURE=Ship+CLI',
      ),
    );

    expect(response.statusCode, 200);
    final body = await response.readAsString();
    expect(body, contains('form-error-text'));
    expect(body, contains('git fetch failed'));
  });
}
