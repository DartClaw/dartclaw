import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show InMemoryDefinitionSource, WorkflowService;
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Database taskDb;
  late SqliteTaskRepository taskRepo;
  late TaskService tasks;
  late _FakeWorkflowService workflows;
  late Handler handler;

  setUp(() {
    taskDb = openTaskDbInMemory();
    taskRepo = SqliteTaskRepository(taskDb);
    final eventBus = EventBus();
    tasks = TaskService(taskRepo, eventBus: eventBus);
    workflows = _FakeWorkflowService(
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

  test('POST /api/workflows/run-form returns html validation errors', () async {
    final response = await handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/workflows/run-form'),
        headers: {'content-type': 'application/x-www-form-urlencoded', 'HX-Request': 'true'},
        body: 'definition=spec-and-implement',
      ),
    );

    expect(response.statusCode, 400);
    expect(await response.readAsString(), contains('Missing required variable'));
  });
}

class _FakeWorkflowService extends WorkflowService {
  _FakeWorkflowService._super(
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

  factory _FakeWorkflowService({
    required Database db,
    required TaskService taskService,
    required EventBus eventBus,
    required String dataDir,
  }) {
    final repo = SqliteWorkflowRunRepository(db);
    final messages = MessageService(baseDir: '$dataDir/sessions');
    final kv = KvService(filePath: '$dataDir/kv.json');
    return _FakeWorkflowService._super(repo, taskService, messages, eventBus, kv, dataDir);
  }

  WorkflowRun? startResult;

  @override
  Future<WorkflowRun> start(
    WorkflowDefinition definition,
    Map<String, String> variables, {
    String? projectId,
    bool headless = false,
  }) async {
    return startResult!;
  }
}
