import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_workflow/testing.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show WorkflowDefinition, WorkflowRun, WorkflowStep, WorkflowVariable;
import 'package:dartclaw_testing/dartclaw_testing.dart' show InMemoryTaskRepository;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'workflow_test_support.dart';

void main() {
  late InMemoryTaskRepository taskRepo;
  late TaskService tasks;
  late FakeWorkflowService workflows;
  late Handler handler;

  setUp(() async {
    taskRepo = InMemoryTaskRepository();
    final eventBus = EventBus();
    tasks = TaskService(taskRepo, eventBus: eventBus);
    workflows = FakeWorkflowService(taskService: tasks, eventBus: eventBus, dataDir: '/tmp/workflow-run-form-data');
    workflows.startResult = WorkflowRun(
      id: 'run-1',
      definitionName: 'story-and-implement',
      status: WorkflowRunStatus.running,
      startedAt: DateTime.utc(2026, 1, 1, 12),
      updatedAt: DateTime.utc(2026, 1, 1, 12),
      definitionJson: const {},
    );
    final definitions = InMemoryDefinitionSource([
      WorkflowDefinition(
        name: 'story-and-implement',
        description: 'Demo',
        variables: const {'FEATURE': WorkflowVariable(required: true, description: 'Feature to build')},
        steps: const [
          WorkflowStep(id: 'step-1', name: 'Plan', prompts: ['Plan']),
        ],
      ),
    ]);
    handler = workflowRoutes(workflows, tasks, definitions, runControl: testRunControl(workflows)).call;
  });

  tearDown(() async {
    await workflows.dispose();
    await tasks.dispose();
  });

  test('POST /api/workflows/run-form returns HX-Location on success', () async {
    final response = await handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/workflows/run-form'),
        headers: {'content-type': 'application/x-www-form-urlencoded', 'HX-Request': 'true'},
        body: 'definition=story-and-implement&var_FEATURE=Ship+CLI',
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
        body: 'definition=story-and-implement',
      ),
    );

    // 200 (not 4xx) so HTMX's default responseHandling swaps the fragment into hx-target.
    expect(response.statusCode, 200);
    final body = await response.readAsString();
    expect(body, contains('form-error-text'));
    expect(body, contains('Missing required variable'));
  });

  Future<Response> postJson(Object body) async => handler(
    Request(
      'POST',
      Uri.parse('http://localhost/api/workflows/run'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode(body),
    ),
  );

  Future<Response> postForm(String body) async => handler(
    Request(
      'POST',
      Uri.parse('http://localhost/api/workflows/run-form'),
      headers: {'content-type': 'application/x-www-form-urlencoded', 'HX-Request': 'true'},
      body: body,
    ),
  );

  test('an unregistered definition is one resolution rendered two ways', () async {
    final jsonResult = await postJson({'definition': 'nope'});
    final formResult = await postForm('definition=nope');

    expect(jsonResult.statusCode, 404);
    final error = (jsonDecode(await jsonResult.readAsString()) as Map<String, dynamic>)['error'] as Map;
    expect(error['code'], 'DEFINITION_NOT_FOUND');
    expect(error['message'], 'Workflow definition not found: nope');

    // Same sentence, swappable 200 fragment — HTMX drops the body on a 4xx.
    expect(formResult.statusCode, 200);
    final fragment = await formResult.readAsString();
    expect(fragment, contains('form-error-text'));
    expect(fragment, contains('Workflow definition not found: nope'));
    expect(workflows.startCalls, isZero);
  });

  test('a missing required variable is named by the same validation on both encodings', () async {
    final jsonResult = await postJson({'definition': 'story-and-implement'});
    final formResult = await postForm('definition=story-and-implement');

    expect(jsonResult.statusCode, 400);
    final error = (jsonDecode(await jsonResult.readAsString()) as Map<String, dynamic>)['error'] as Map;
    expect(error['code'], 'INVALID_INPUT');
    expect((error['details'] as Map)['missingVariables'], ['FEATURE']);

    expect(formResult.statusCode, 200);
    expect(await formResult.readAsString(), contains(error['message'] as String));
    expect(workflows.startCalls, isZero);
  });

  test('POST /api/workflows/run rejects oversized streamed JSON body', () async {
    final response = await handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/workflows/run'),
        headers: {'content-type': 'application/json'},
        body: Stream<List<int>>.fromIterable([
          utf8.encode('{"definition":"story-and-implement","variables":{"FEATURE":"'),
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
          utf8.encode('definition=story-and-implement&var_FEATURE='),
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
    workflows.startError = const WorkflowStartPreconditionException('Workflow cannot start until alpha is clean.');

    final response = await handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/workflows/run-form'),
        headers: {'content-type': 'application/x-www-form-urlencoded', 'HX-Request': 'true'},
        body: 'definition=story-and-implement&var_FEATURE=Ship+CLI',
      ),
    );

    // Precondition failures are 409 on the JSON API, but the web form needs 200 to swap.
    expect(response.statusCode, 200);
    final body = await response.readAsString();
    expect(body, contains('form-error-text'));
    expect(body, contains('Workflow cannot start'));
  });

  test('POST /api/workflows/run-form returns swappable 200 fragment for remote ref precondition failures', () async {
    workflows.startError = const WorkflowStartPreconditionException('Requested branch is unavailable.');

    final response = await handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/workflows/run-form'),
        headers: {'content-type': 'application/x-www-form-urlencoded', 'HX-Request': 'true'},
        body: 'definition=story-and-implement&var_FEATURE=Ship+CLI',
      ),
    );

    expect(response.statusCode, 200);
    final body = await response.readAsString();
    expect(body, contains('form-error-text'));
    expect(body, contains('Requested branch is unavailable'));
  });

  group('run origin', () {
    test('the run form records surface web with no channel fields', () async {
      final response = await postForm('definition=story-and-implement&var_FEATURE=Ship+CLI');

      expect(response.statusCode, 201);
      expect(workflows.lastOrigin?.toJson(), {
        'surface': 'web',
        'channelType': null,
        'recipientId': null,
        'threadId': null,
        'sessionKey': null,
        'senderId': null,
      });
    });

    test('the JSON API records api, or cli on the cli marker', () async {
      await postJson({
        'definition': 'story-and-implement',
        'variables': {'FEATURE': 'x'},
      });
      expect(workflows.lastOrigin?.surface, 'api');

      await postJson({
        'definition': 'story-and-implement',
        'variables': {'FEATURE': 'x'},
        'surface': 'cli',
      });
      expect(workflows.lastOrigin?.surface, 'cli');
      expect(workflows.startCalls, 2);
    });

    test('any other surface marker is refused with INVALID_INPUT and creates no run', () async {
      for (final marker in <Object?>['slack', 'web', 'api', 'googlechat', 'CLI', '', 42, true]) {
        final response = await postJson({
          'definition': 'story-and-implement',
          'variables': {'FEATURE': 'x'},
          'surface': marker,
        });

        expect(response.statusCode, 400, reason: '$marker');
        final error = (jsonDecode(await response.readAsString()) as Map<String, dynamic>)['error'] as Map;
        expect(error['code'], 'INVALID_INPUT', reason: '$marker');
        expect((error['details'] as Map)['field'], 'surface', reason: '$marker');
      }
      expect(workflows.startCalls, isZero);
    });

    test('no request field can set recipient, thread, session, sender or channel type', () async {
      await postJson({
        'definition': 'story-and-implement',
        'variables': {'FEATURE': 'x'},
        'surface': 'cli',
        'channelType': 'slack',
        'recipientId': 'C123',
        'threadId': '1700000000.000100',
        'sessionKey': 'agent:main:channel:slack:C123',
        'senderId': 'U999',
        'origin': {'surface': 'slack', 'senderId': 'U999'},
      });

      final origin = workflows.lastOrigin!;
      expect(origin.surface, 'cli');
      expect([
        origin.channelType,
        origin.recipientId,
        origin.threadId,
        origin.sessionKey,
        origin.senderId,
      ], everyElement(isNull));
    });
  });
}
