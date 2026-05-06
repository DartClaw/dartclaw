import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show InMemoryDefinitionSource, WorkflowService;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'api_test_helpers.dart';

// ──────────────────────────────────────────────────────────────────────────────
// Test fakes
// ──────────────────────────────────────────────────────────────────────────────

/// Fake [WorkflowService] that extends the concrete class with no-op deps
/// and overrides all public methods to return pre-configured responses.
class FakeWorkflowService extends WorkflowService {
  FakeWorkflowService._super(
    SqliteWorkflowRunRepository repository,
    TaskService taskService,
    MessageService messageService,
    EventBus eventBus,
    KvService kvService,
    String dataDir,
  ) : super(
        repository: repository,
        taskService: taskService,
        messageService: messageService,
        eventBus: eventBus,
        kvService: kvService,
        dataDir: dataDir,
      );

  factory FakeWorkflowService({
    required Database db,
    required TaskService taskService,
    required EventBus eventBus,
    required String dataDir,
  }) {
    final repo = SqliteWorkflowRunRepository(db);
    final messages = MessageService(baseDir: p.join(dataDir, 'sessions'));
    final kv = KvService(filePath: p.join(dataDir, 'kv.json'));
    return FakeWorkflowService._super(repo, taskService, messages, eventBus, kv, dataDir);
  }

  // Configurable responses.
  WorkflowRun? startResult;
  WorkflowRun? getResult;
  List<WorkflowRun> listResult = [];
  WorkflowRun? pauseResult;
  WorkflowRun? resumeResult;
  bool throwOnPause = false;
  bool throwOnResume = false;
  bool throwOnCancel = false;
  Object? startError;
  String? lastProjectId;
  bool lastAllowDirtyLocalPath = false;

  final List<String> calls = [];

  @override
  Future<WorkflowRun> start(
    WorkflowDefinition definition,
    Map<String, String> variables, {
    String? projectId,
    bool allowDirtyLocalPath = false,
    bool headless = false,
  }) async {
    calls.add('start:${definition.name}');
    if (startError != null) {
      throw startError!;
    }
    lastProjectId = projectId;
    lastAllowDirtyLocalPath = allowDirtyLocalPath;
    return startResult!;
  }

  @override
  Future<WorkflowRun?> get(String runId) async {
    calls.add('get:$runId');
    return getResult;
  }

  @override
  Future<List<WorkflowRun>> list({WorkflowRunStatus? status, String? definitionName}) async {
    calls.add('list:$status:$definitionName');
    return listResult;
  }

  @override
  Future<WorkflowRun> pause(String runId) async {
    calls.add('pause:$runId');
    if (throwOnPause) throw StateError('Cannot pause: invalid state');
    return pauseResult!;
  }

  @override
  Future<WorkflowRun> resume(String runId) async {
    calls.add('resume:$runId');
    if (throwOnResume) throw StateError('Cannot resume: invalid state');
    return resumeResult!;
  }

  String? lastCancelFeedback;

  @override
  Future<void> cancel(String runId, {String? feedback}) async {
    calls.add('cancel:$runId');
    lastCancelFeedback = feedback;
    if (throwOnCancel) throw StateError('Cannot cancel: invalid state');
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Test helpers
// ──────────────────────────────────────────────────────────────────────────────

WorkflowDefinition _makeDefinition({
  String name = 'spec-and-implement',
  Map<String, WorkflowVariable>? variables,
  List<WorkflowStep>? steps,
}) {
  return WorkflowDefinition(
    name: name,
    description: 'Research, specify, implement, review.',
    variables:
        variables ??
        {
          'FEATURE': const WorkflowVariable(required: true, description: 'Feature to implement'),
          'PROJECT': const WorkflowVariable(required: false, description: 'Target project', defaultValue: null),
        },
    steps:
        steps ??
        [
          const WorkflowStep(id: 'research', name: 'Research', prompts: ['Research {{FEATURE}}']),
          const WorkflowStep(id: 'spec', name: 'Write Spec', prompts: ['Write spec for {{FEATURE}}']),
          const WorkflowStep(id: 'implement', name: 'Implement', prompts: ['Implement {{FEATURE}}']),
        ],
  );
}

WorkflowRun _makeRun({
  String id = 'run-001',
  String definitionName = 'spec-and-implement',
  WorkflowRunStatus status = WorkflowRunStatus.running,
  int currentStepIndex = 0,
  Map<String, dynamic>? definitionJson,
  Map<String, dynamic>? contextJson,
}) {
  final now = DateTime.parse('2026-03-24T10:00:00Z');
  return WorkflowRun(
    id: id,
    definitionName: definitionName,
    status: status,
    startedAt: now,
    updatedAt: now,
    variablesJson: const {'FEATURE': 'User pagination'},
    definitionJson: definitionJson ?? _makeDefinition().toJson(),
    currentStepIndex: currentStepIndex,
    contextJson: contextJson ?? const {},
  );
}

Task _makeTask({
  required String id,
  required String workflowRunId,
  required int stepIndex,
  TaskStatus status = TaskStatus.accepted,
}) {
  return Task(
    id: id,
    title: 'Step $stepIndex',
    description: 'desc',
    type: TaskType.research,
    status: status,
    createdAt: DateTime.parse('2026-03-24T10:00:00Z'),
    workflowRunId: workflowRunId,
    stepIndex: stepIndex,
  );
}

void main() {
  late Database taskDb;
  late Database workflowDb;
  late SqliteTaskRepository taskRepo;
  late EventBus eventBus;
  late TaskService tasks;
  late FakeWorkflowService workflows;
  late Handler handler;
  late InMemoryDefinitionSource definitions;
  late Directory tempDir;

  setUp(() async {
    taskDb = openTaskDbInMemory();
    workflowDb = sqlite3.openInMemory();
    eventBus = EventBus();
    taskRepo = SqliteTaskRepository(taskDb);
    tasks = TaskService(taskRepo, eventBus: eventBus);
    tempDir = Directory.systemTemp.createTempSync('wf_routes_test_');

    final def = _makeDefinition();
    definitions = InMemoryDefinitionSource([def]);

    workflows = FakeWorkflowService(db: workflowDb, taskService: tasks, eventBus: eventBus, dataDir: tempDir.path);
    workflows.startResult = _makeRun();
    workflows.getResult = _makeRun();
    workflows.listResult = [_makeRun()];
    workflows.pauseResult = _makeRun(status: WorkflowRunStatus.paused);
    workflows.resumeResult = _makeRun(status: WorkflowRunStatus.running);

    handler = workflowRoutes(workflows, tasks, definitions).call;
  });

  tearDown(() async {
    // Dispose workflow service first — it calls task list during shutdown.
    await workflows.dispose();
    await tasks.dispose();
    await eventBus.dispose();
    workflowDb.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  // ──────────────────────────────────────────────────────────────────────────
  // POST /api/workflows/run
  // ──────────────────────────────────────────────────────────────────────────

  group('POST /api/workflows/run', () {
    test('creates run with valid definition and variables', () async {
      final response = await handler(
        jsonRequest('POST', '/api/workflows/run', {
          'definition': 'spec-and-implement',
          'variables': {'FEATURE': 'User pagination'},
        }),
      );

      expect(response.statusCode, 201);
      final body = decodeObject(await response.readAsString());
      expect(body['id'], 'run-001');
      expect(body['status'], 'running');
      expect(workflows.calls, contains('start:spec-and-implement'));
    });

    test('returns 400 for missing definition field', () async {
      final response = await handler(jsonRequest('POST', '/api/workflows/run', {'variables': {}}));

      expect(response.statusCode, 400);
      expect(await errorCode(response), 'INVALID_INPUT');
    });

    test('returns 400 when definition field is not a string', () async {
      final response = await handler(jsonRequest('POST', '/api/workflows/run', {'definition': 42}));

      expect(response.statusCode, 400);
      expect(await errorCode(response), 'INVALID_INPUT');
    });

    test('returns 404 for unknown definition name', () async {
      final response = await handler(
        jsonRequest('POST', '/api/workflows/run', {'definition': 'does-not-exist', 'variables': {}}),
      );

      expect(response.statusCode, 404);
      expect(await errorCode(response), 'DEFINITION_NOT_FOUND');
    });

    test('returns 400 for missing required variable', () async {
      // FEATURE is required and has no default.
      final response = await handler(
        jsonRequest('POST', '/api/workflows/run', {'definition': 'spec-and-implement', 'variables': {}}),
      );

      expect(response.statusCode, 400);
      final body = decodeObject(await response.readAsString());
      final error = body['error'] as Map<String, dynamic>;
      expect(error['code'], 'INVALID_INPUT');
      expect((error['details']['missingVariables'] as List), contains('FEATURE'));
    });

    test('returns 400 for invalid JSON body', () async {
      final response = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/workflows/run'),
          body: '{ not valid json',
          headers: {'content-type': 'application/json'},
        ),
      );

      expect(response.statusCode, 400);
      expect(await errorCode(response), 'INVALID_INPUT');
    });

    test('returns 400 when variables field is not a map', () async {
      final response = await handler(
        jsonRequest('POST', '/api/workflows/run', {'definition': 'spec-and-implement', 'variables': 'not-a-map'}),
      );

      expect(response.statusCode, 400);
      final body = decodeObject(await response.readAsString());
      final error = body['error'] as Map<String, dynamic>;
      expect(error['code'], 'INVALID_INPUT');
      expect(error['details']['field'], 'variables');
    });

    test('passes project to service', () async {
      final response = await handler(
        jsonRequest('POST', '/api/workflows/run', {
          'definition': 'spec-and-implement',
          'variables': {'FEATURE': 'Pagination'},
          'project': 'my-project',
        }),
      );

      expect(response.statusCode, 201);
      expect(workflows.lastProjectId, 'my-project');
    });

    test('passes allowDirtyLocalPath to the workflow service', () async {
      final response = await handler(
        jsonRequest('POST', '/api/workflows/run', {
          'definition': 'spec-and-implement',
          'variables': {'FEATURE': 'Pagination'},
          'allowDirtyLocalPath': true,
        }),
      );

      expect(response.statusCode, 201);
      expect(workflows.lastAllowDirtyLocalPath, isTrue);
    });

    test('local-path preflight state errors return workflow precondition failed', () async {
      workflows.startError = StateError(
        'Local-path project "alpha" is not safe to mutate: observed branch "feature/local", expected "main", dirty path count 1. Re-run with --allow-dirty-localpath to override.',
      );

      final response = await handler(
        jsonRequest('POST', '/api/workflows/run', {
          'definition': 'spec-and-implement',
          'variables': {'FEATURE': 'Pagination'},
        }),
      );

      expect(response.statusCode, 409);
      expect(await errorCode(response), 'WORKFLOW_PRECONDITION_FAILED');
    });

    test('remote strict ref failures return workflow precondition failed', () async {
      workflows.startError = StateError(
        "git fetch failed for \"alpha\" (ref: missing/ref): fatal: couldn't find remote ref",
      );

      final response = await handler(
        jsonRequest('POST', '/api/workflows/run', {
          'definition': 'spec-and-implement',
          'variables': {'FEATURE': 'Pagination'},
        }),
      );

      expect(response.statusCode, 409);
      expect(await errorCode(response), 'WORKFLOW_PRECONDITION_FAILED');
    });

    test('optional variable with default can be omitted', () async {
      // PROJECT has no default (null) and is not required — should succeed without it.
      final response = await handler(
        jsonRequest('POST', '/api/workflows/run', {
          'definition': 'spec-and-implement',
          'variables': {'FEATURE': 'Pagination'},
        }),
      );

      expect(response.statusCode, 201);
    });

    test('definition with default value succeeds when not provided', () async {
      final defWithDefault = WorkflowDefinition(
        name: 'with-defaults',
        description: 'Has optional var with default.',
        variables: {
          'FEATURE': const WorkflowVariable(required: true, description: 'Feature'),
          'MODE': const WorkflowVariable(required: true, description: 'Mode', defaultValue: 'fast'),
        },
        steps: [
          const WorkflowStep(id: 's1', name: 'Step 1', prompts: ['Run {{FEATURE}}']),
        ],
      );
      final src = InMemoryDefinitionSource([defWithDefault]);
      final h = workflowRoutes(workflows, tasks, src).call;

      final response = await h(
        jsonRequest('POST', '/api/workflows/run', {
          'definition': 'with-defaults',
          'variables': {'FEATURE': 'Search'},
        }),
      );

      expect(response.statusCode, 201);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // GET /api/workflows/runs
  // ──────────────────────────────────────────────────────────────────────────

  group('GET /api/workflows/runs', () {
    test('returns all runs', () async {
      workflows.listResult = [_makeRun(), _makeRun(id: 'run-002')];

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs')));

      expect(response.statusCode, 200);
      final body = decodeList(await response.readAsString());
      expect(body, hasLength(2));
      expect(workflows.calls, contains('list:null:null'));
    });

    test('filters by status query param', () async {
      workflows.listResult = [];

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs?status=running')));

      expect(response.statusCode, 200);
      expect(workflows.calls, contains('list:${WorkflowRunStatus.running}:null'));
    });

    test('filters by definition query param', () async {
      workflows.listResult = [];

      final response = await handler(
        Request('GET', Uri.parse('http://localhost/api/workflows/runs?definition=spec-and-implement')),
      );

      expect(response.statusCode, 200);
      expect(workflows.calls, contains('list:null:spec-and-implement'));
    });

    test('returns empty array when no runs', () async {
      workflows.listResult = [];

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs')));

      expect(response.statusCode, 200);
      final body = decodeList(await response.readAsString());
      expect(body, isEmpty);
    });

    test('ignores unknown status query param', () async {
      workflows.listResult = [];

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs?status=unknown')));

      // Unknown status → treated as null filter (no error).
      expect(response.statusCode, 200);
      expect(workflows.calls, contains('list:null:null'));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // GET /api/workflows/runs/<id>
  // ──────────────────────────────────────────────────────────────────────────

  group('GET /api/workflows/runs/<id>', () {
    test('returns enriched run detail with steps', () async {
      workflows.getResult = _makeRun(currentStepIndex: 2);

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs/run-001')));

      expect(response.statusCode, 200);
      final body = decodeObject(await response.readAsString());
      expect(body['id'], 'run-001');
      final steps = body['steps'] as List;
      expect(steps, hasLength(3)); // 3 steps in test definition
      expect(steps[0]['id'], 'research');
      expect(steps[0]['index'], 0);
      expect(body['childTaskIds'], isA<List<dynamic>>());
    });

    test('returns 404 for non-existent run', () async {
      workflows.getResult = null;

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs/no-such-run')));

      expect(response.statusCode, 404);
      expect(await errorCode(response), 'WORKFLOW_RUN_NOT_FOUND');
    });

    test('derives step status from child tasks', () async {
      workflows.getResult = _makeRun(currentStepIndex: 1);

      // Insert tasks for step 0 (completed) and step 1 (running).
      await taskRepo.insert(_makeTask(id: 't-0', workflowRunId: 'run-001', stepIndex: 0, status: TaskStatus.accepted));
      await taskRepo.insert(_makeTask(id: 't-1', workflowRunId: 'run-001', stepIndex: 1, status: TaskStatus.running));

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs/run-001')));

      expect(response.statusCode, 200);
      final body = decodeObject(await response.readAsString());
      final steps = body['steps'] as List;

      expect(steps[0]['status'], 'completed'); // accepted → completed
      expect(steps[0]['taskId'], 't-0');
      expect(steps[1]['status'], 'running');
      expect(steps[1]['taskId'], 't-1');
      expect(steps[2]['status'], 'pending'); // no task yet
      expect(steps[2]['taskId'], isNull);
    });

    test('pending steps have no taskId', () async {
      workflows.getResult = _makeRun(currentStepIndex: 0, status: WorkflowRunStatus.paused);

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs/run-001')));

      expect(response.statusCode, 200);
      final body = decodeObject(await response.readAsString());
      final steps = body['steps'] as List;
      expect(steps.every((s) => s['taskId'] == null), isTrue);
    });

    test('current step with no task yet shows running if run is running', () async {
      workflows.getResult = _makeRun(currentStepIndex: 1, status: WorkflowRunStatus.running);

      // Only step 0 has a task; step 1 hasn't spawned one yet.
      await taskRepo.insert(_makeTask(id: 't-0', workflowRunId: 'run-001', stepIndex: 0, status: TaskStatus.accepted));

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs/run-001')));

      expect(response.statusCode, 200);
      final body = decodeObject(await response.readAsString());
      final steps = body['steps'] as List;
      expect(steps[1]['status'], 'running'); // current step, no task yet
    });

    test('skipped outcome in run context is surfaced for taskless steps', () async {
      workflows.getResult = _makeRun(
        currentStepIndex: 1,
        status: WorkflowRunStatus.running,
        contextJson: const {'step.research.outcome': 'skipped'},
      );

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs/run-001')));

      expect(response.statusCode, 200);
      final body = decodeObject(await response.readAsString());
      final steps = body['steps'] as List;
      expect(steps[0]['status'], 'skipped');
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // POST /api/workflows/runs/<id>/pause
  // ──────────────────────────────────────────────────────────────────────────

  group('POST /api/workflows/runs/<id>/pause', () {
    test('pauses running workflow', () async {
      workflows.getResult = _makeRun(status: WorkflowRunStatus.running);
      workflows.pauseResult = _makeRun(status: WorkflowRunStatus.paused);

      final response = await handler(Request('POST', Uri.parse('http://localhost/api/workflows/runs/run-001/pause')));

      expect(response.statusCode, 200);
      final body = decodeObject(await response.readAsString());
      expect(body['status'], 'paused');
    });

    test('returns 404 for non-existent run', () async {
      workflows.getResult = null;

      final response = await handler(Request('POST', Uri.parse('http://localhost/api/workflows/runs/no-such/pause')));

      expect(response.statusCode, 404);
      expect(await errorCode(response), 'WORKFLOW_RUN_NOT_FOUND');
    });

    test('returns 409 for invalid transition', () async {
      workflows.getResult = _makeRun(status: WorkflowRunStatus.running);
      workflows.throwOnPause = true;

      final response = await handler(Request('POST', Uri.parse('http://localhost/api/workflows/runs/run-001/pause')));

      expect(response.statusCode, 409);
      expect(await errorCode(response), 'INVALID_TRANSITION');
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // POST /api/workflows/runs/<id>/resume
  // ──────────────────────────────────────────────────────────────────────────

  group('POST /api/workflows/runs/<id>/resume', () {
    test('resumes paused workflow', () async {
      workflows.getResult = _makeRun(status: WorkflowRunStatus.paused);
      workflows.resumeResult = _makeRun(status: WorkflowRunStatus.running);

      final response = await handler(Request('POST', Uri.parse('http://localhost/api/workflows/runs/run-001/resume')));

      expect(response.statusCode, 200);
      final body = decodeObject(await response.readAsString());
      expect(body['status'], 'running');
    });

    test('returns 404 for non-existent run', () async {
      workflows.getResult = null;

      final response = await handler(Request('POST', Uri.parse('http://localhost/api/workflows/runs/no-such/resume')));

      expect(response.statusCode, 404);
      expect(await errorCode(response), 'WORKFLOW_RUN_NOT_FOUND');
    });

    test('returns 409 for invalid transition', () async {
      workflows.getResult = _makeRun(status: WorkflowRunStatus.running);
      workflows.throwOnResume = true;

      final response = await handler(Request('POST', Uri.parse('http://localhost/api/workflows/runs/run-001/resume')));

      expect(response.statusCode, 409);
      expect(await errorCode(response), 'INVALID_TRANSITION');
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // POST /api/workflows/runs/<id>/cancel
  // ──────────────────────────────────────────────────────────────────────────

  group('POST /api/workflows/runs/<id>/cancel', () {
    test('cancels active workflow', () async {
      workflows.getResult = _makeRun(status: WorkflowRunStatus.running);

      final response = await handler(Request('POST', Uri.parse('http://localhost/api/workflows/runs/run-001/cancel')));

      expect(response.statusCode, 204);
      expect(workflows.calls, contains('cancel:run-001'));
    });

    test('returns 404 for non-existent run', () async {
      workflows.getResult = null;

      final response = await handler(Request('POST', Uri.parse('http://localhost/api/workflows/runs/no-such/cancel')));

      expect(response.statusCode, 404);
      expect(await errorCode(response), 'WORKFLOW_RUN_NOT_FOUND');
    });

    test('returns 409 for already terminal run', () async {
      workflows.getResult = _makeRun(status: WorkflowRunStatus.completed);

      final response = await handler(Request('POST', Uri.parse('http://localhost/api/workflows/runs/run-001/cancel')));

      expect(response.statusCode, 409);
      expect(await errorCode(response), 'INVALID_TRANSITION');
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // GET /api/workflows/definitions
  // ──────────────────────────────────────────────────────────────────────────

  group('GET /api/workflows/definitions', () {
    test('returns all definitions as summaries', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/definitions')));

      expect(response.statusCode, 200);
      final body = decodeList(await response.readAsString());
      expect(body, hasLength(1));
      final def = body.first as Map<String, dynamic>;
      expect(def['name'], 'spec-and-implement');
      expect(def['description'], isNotEmpty);
      expect(def['stepCount'], 3);
      expect(def['hasLoops'], false);
    });

    test('summary includes variables with required flag', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/definitions')));

      expect(response.statusCode, 200);
      final body = decodeList(await response.readAsString());
      final variables = (body.first as Map<String, dynamic>)['variables'] as Map<String, dynamic>;
      expect(variables['FEATURE']['required'], true);
      expect(variables['PROJECT']['required'], false);
    });

    test('returns empty array when no definitions', () async {
      final h = workflowRoutes(workflows, tasks, InMemoryDefinitionSource([])).call;

      final response = await h(Request('GET', Uri.parse('http://localhost/api/workflows/definitions')));

      expect(response.statusCode, 200);
      final body = decodeList(await response.readAsString());
      expect(body, isEmpty);
    });

    test('summary includes hasLoops true when definition has loops', () async {
      final defWithLoop = WorkflowDefinition(
        name: 'loopy',
        description: 'Has loops.',
        steps: [
          const WorkflowStep(id: 's1', name: 'Step 1', prompts: ['Do it']),
        ],
        loops: [
          const WorkflowLoop(id: 'loop1', steps: ['s1'], maxIterations: 3, exitGate: 'done == "yes"'),
        ],
      );
      final src = InMemoryDefinitionSource([defWithLoop]);
      final h = workflowRoutes(workflows, tasks, src).call;

      final response = await h(Request('GET', Uri.parse('http://localhost/api/workflows/definitions')));

      expect(response.statusCode, 200);
      final body = decodeList(await response.readAsString());
      expect((body.first as Map<String, dynamic>)['hasLoops'], true);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // GET /api/workflows/definitions/<name>
  // ──────────────────────────────────────────────────────────────────────────

  group('GET /api/workflows/definitions/<name>', () {
    test('returns authored YAML for known name', () async {
      final response = await handler(
        Request('GET', Uri.parse('http://localhost/api/workflows/definitions/spec-and-implement')),
      );

      expect(response.statusCode, 200);
      expect(response.headers['content-type'], contains('application/yaml'));
      final body = await response.readAsString();
      expect(body, startsWith('name: spec-and-implement'));
      expect(body, contains('description:'));
      expect(body, contains('steps:'));
    });

    test('authored YAML includes variables and step prompts', () async {
      final response = await handler(
        Request('GET', Uri.parse('http://localhost/api/workflows/definitions/spec-and-implement')),
      );

      expect(response.statusCode, 200);
      final body = await response.readAsString();
      expect(body, contains('variables:'));
      expect(body, contains('FEATURE:'));
      expect(body, contains('prompt:'));
    });

    test('returns 404 for unknown definition name', () async {
      final response = await handler(
        Request('GET', Uri.parse('http://localhost/api/workflows/definitions/does-not-exist')),
      );

      expect(response.statusCode, 404);
      expect(await errorCode(response), 'DEFINITION_NOT_FOUND');
    });

    test('summary listing stays JSON while detail returns YAML', () async {
      final summaryResponse = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/definitions')));
      final detailResponse = await handler(
        Request('GET', Uri.parse('http://localhost/api/workflows/definitions/spec-and-implement')),
      );

      expect(summaryResponse.statusCode, 200);
      expect(detailResponse.statusCode, 200);

      final summaryList = decodeList(await summaryResponse.readAsString());
      final summaryEntry = summaryList.first as Map<String, dynamic>;
      expect(summaryEntry.containsKey('steps'), isFalse);

      final detail = await detailResponse.readAsString();
      expect(detail, startsWith('name: spec-and-implement'));
    });
  });

  group('GET /api/workflows/runs/<id>/events', () {
    Future<Map<String, dynamic>> nextPayload(StreamIterator<String> iterator) async {
      final hasFrame = await iterator.moveNext().timeout(const Duration(seconds: 1));
      expect(hasFrame, isTrue);
      final dataLine = iterator.current.trim().split('\n').first;
      expect(dataLine, startsWith('data: '));
      return jsonDecode(dataLine.substring('data: '.length)) as Map<String, dynamic>;
    }

    Future<Map<String, dynamic>> nextPayloadOfType(StreamIterator<String> iterator, String type) async {
      for (var i = 0; i < 20; i++) {
        final payload = await nextPayload(iterator);
        if (payload['type'] == type) {
          return payload;
        }
      }
      fail('Did not receive SSE payload type=$type');
    }

    test('emits map_iteration_completed and map_step_completed payloads for run', () async {
      handler = workflowRoutes(workflows, tasks, definitions, eventBus: eventBus).call;
      workflows.getResult = _makeRun(id: 'run-001');
      await tasks.create(
        id: 'task-map-step',
        title: 'Map step',
        description: 'desc',
        type: TaskType.coding,
        workflowRunId: 'run-001',
        stepIndex: 0,
      );

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs/run-001/events')));
      expect(response.statusCode, 200);
      final iterator = StreamIterator(response.read().transform(utf8.decoder));
      addTearDown(iterator.cancel);

      final connected = await nextPayload(iterator);
      expect(connected['type'], 'connected');

      eventBus.fire(
        MapIterationCompletedEvent(
          runId: 'run-001',
          stepId: 's2',
          iterationIndex: 3,
          totalIterations: 10,
          itemId: 'item-7',
          taskId: 'task-map-step',
          success: true,
          tokenCount: 120,
          timestamp: DateTime.parse('2026-03-24T10:00:00Z'),
        ),
      );
      final mapIteration = await nextPayloadOfType(iterator, 'map_iteration_completed');
      expect(mapIteration['runId'], 'run-001');
      expect(mapIteration['stepId'], 's2');
      expect(mapIteration['iterationIndex'], 3);
      expect(mapIteration['totalIterations'], 10);
      expect(mapIteration['itemId'], 'item-7');
      expect(mapIteration['taskId'], 'task-map-step');
      expect(mapIteration['success'], true);
      expect(mapIteration['tokenCount'], 120);

      eventBus.fire(
        MapStepCompletedEvent(
          runId: 'run-001',
          stepId: 's2',
          stepName: 'fanout',
          totalIterations: 10,
          successCount: 9,
          failureCount: 1,
          cancelledCount: 0,
          totalTokens: 1200,
          timestamp: DateTime.parse('2026-03-24T10:00:01Z'),
        ),
      );
      final mapStep = await nextPayloadOfType(iterator, 'map_step_completed');
      expect(mapStep['runId'], 'run-001');
      expect(mapStep['stepId'], 's2');
      expect(mapStep['stepName'], 'fanout');
      expect(mapStep['totalIterations'], 10);
      expect(mapStep['successCount'], 9);
      expect(mapStep['failureCount'], 1);
      expect(mapStep['cancelledCount'], 0);
      expect(mapStep['totalTokens'], 1200);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // S03 (0.16.1): Approval gate — run detail enrichment and cancel with feedback
  // ──────────────────────────────────────────────────────────────────────────

  group('S03 (0.16.1): approval run detail and cancel feedback', () {
    WorkflowRun makeApprovalPausedRun({String stepId = 'gate'}) {
      final def = WorkflowDefinition(
        name: 'approval-wf',
        description: 'With approval gate.',
        steps: [
          WorkflowStep(id: stepId, name: 'Gate', type: 'approval', prompts: ['Approve?']),
          const WorkflowStep(id: 'next', name: 'Next', prompts: ['Continue']),
        ],
        variables: const {},
      );
      final now = DateTime.parse('2026-03-24T10:00:00Z');
      return WorkflowRun(
        id: 'run-approval',
        definitionName: 'approval-wf',
        status: WorkflowRunStatus.paused,
        startedAt: now,
        updatedAt: now,
        currentStepIndex: 1,
        definitionJson: def.toJson(),
        contextJson: {
          'data': <String, dynamic>{},
          'variables': <String, dynamic>{},
          '$stepId.approval.status': 'pending',
          '$stepId.approval.message': 'Approve?',
          '$stepId.approval.requested_at': '2026-03-24T10:00:00.000Z',
          '$stepId.tokenCount': 0,
          '_approval.pending.stepId': stepId,
          '_approval.pending.stepIndex': 0,
        },
      );
    }

    test('GET run detail includes isApprovalPaused=true and pendingApprovalStepId', () async {
      workflows.getResult = makeApprovalPausedRun();

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs/run-approval')));

      expect(response.statusCode, 200);
      final body = decodeObject(await response.readAsString());
      expect(body['isApprovalPaused'], isTrue);
      expect(body['pendingApprovalStepId'], equals('gate'));
    });

    test('GET run detail includes approval sub-object for approval step', () async {
      workflows.getResult = makeApprovalPausedRun();

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs/run-approval')));

      expect(response.statusCode, 200);
      final body = decodeObject(await response.readAsString());
      final steps = body['steps'] as List;
      final gateStep = steps.first as Map<String, dynamic>;
      expect(gateStep['type'], equals('approval'));
      expect(gateStep['status'], equals('awaiting_approval'));
      final approval = gateStep['approval'] as Map<String, dynamic>;
      expect(approval['status'], equals('pending'));
      expect(approval['message'], equals('Approve?'));
    });

    test('GET run detail preserves timed_out approval status', () async {
      final timedOut = makeApprovalPausedRun().copyWith(
        status: WorkflowRunStatus.cancelled,
        contextJson: {
          'data': <String, dynamic>{},
          'variables': <String, dynamic>{},
          'gate.status': 'cancelled',
          'gate.approval.status': 'timed_out',
          'gate.approval.message': 'Approve?',
          'gate.approval.cancel_reason': 'timeout',
          'gate.tokenCount': 0,
        },
      );
      workflows.getResult = timedOut;

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs/run-approval')));

      expect(response.statusCode, 200);
      final body = decodeObject(await response.readAsString());
      final steps = body['steps'] as List;
      final gateStep = steps.first as Map<String, dynamic>;
      expect(gateStep['status'], equals('timed_out'));
      final approval = gateStep['approval'] as Map<String, dynamic>;
      expect(approval['status'], equals('timed_out'));
      expect(approval['cancelReason'], equals('timeout'));
    });

    test('GET run detail — non-approval run has isApprovalPaused=false', () async {
      workflows.getResult = _makeRun(status: WorkflowRunStatus.running);

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs/run-001')));

      expect(response.statusCode, 200);
      final body = decodeObject(await response.readAsString());
      expect(body['isApprovalPaused'], isFalse);
      expect(body['pendingApprovalStepId'], isNull);
    });

    test('POST cancel with JSON feedback body passes feedback to service', () async {
      workflows.getResult = makeApprovalPausedRun();

      final response = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/workflows/runs/run-approval/cancel'),
          body: '{"feedback": "Not ready"}',
          headers: {'content-type': 'application/json'},
        ),
      );

      expect(response.statusCode, 204);
      expect(workflows.lastCancelFeedback, equals('Not ready'));
    });

    test('POST cancel without JSON body passes null feedback', () async {
      workflows.getResult = _makeRun(status: WorkflowRunStatus.running);

      final response = await handler(Request('POST', Uri.parse('http://localhost/api/workflows/runs/run-001/cancel')));

      expect(response.statusCode, 204);
      expect(workflows.lastCancelFeedback, isNull);
    });
  });
}
