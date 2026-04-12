import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart' show TaskService;
import 'package:dartclaw_server/src/api/chat_command_handler.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart'
    show SqliteTaskRepository, SqliteWorkflowRunRepository, openTaskDbInMemory;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show InMemoryDefinitionSource, WorkflowDefinitionSource, WorkflowService;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Database taskDb;
  late Database workflowDb;
  late TaskService tasks;
  late _FakeWorkflowService workflows;
  late SessionService sessions;
  late Directory tempDir;
  late WorkflowDefinitionSource definitions;

  setUp(() async {
    taskDb = openTaskDbInMemory();
    workflowDb = sqlite3.openInMemory();
    tempDir = Directory.systemTemp.createTempSync('chat-command-handler-test_');

    final taskRepo = SqliteTaskRepository(taskDb);
    final eventBus = EventBus();
    tasks = TaskService(taskRepo, eventBus: eventBus);
    sessions = SessionService(baseDir: p.join(tempDir.path, 'sessions'));
    workflows = _FakeWorkflowService(db: workflowDb, taskService: tasks, eventBus: eventBus, dataDir: tempDir.path);
    workflows.startResult = WorkflowRun(
      id: 'run-1',
      definitionName: 'code-review',
      status: WorkflowRunStatus.running,
      startedAt: DateTime.utc(2026, 1, 1, 12),
      updatedAt: DateTime.utc(2026, 1, 1, 12),
      definitionJson: const {},
    );
    definitions = InMemoryDefinitionSource([
      WorkflowDefinition(
        name: 'code-review',
        description: 'Review a change',
        variables: const {
          'PR_NUMBER': WorkflowVariable(required: true, description: 'Pull request number'),
          'REPO': WorkflowVariable(required: true, description: 'Repository slug'),
        },
        steps: const [
          WorkflowStep(id: 'step-1', name: 'Review', prompts: ['Review the change']),
        ],
      ),
    ]);
  });

  tearDown(() async {
    await workflows.dispose();
    await tasks.dispose();
    taskDb.close();
    workflowDb.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('/workflow list returns a workflow card', () async {
    final session = await sessions.createSession();
    final handler = ChatCommandHandler(workflows: workflows, definitions: definitions);

    final response = await handler.handle(
      Request('POST', Uri.parse('http://localhost/api/sessions/${session.id}/send')),
      session,
      '/workflow list',
    );

    expect(response, isNotNull);
    expect(response!.statusCode, 200);
    expect(await response.readAsString(), contains('code-review'));
  });

  test('/workflow run starts a workflow and returns a link card', () async {
    final session = await sessions.createSession();
    final handler = ChatCommandHandler(workflows: workflows, definitions: definitions);

    final response = await handler.handle(
      Request('POST', Uri.parse('http://localhost/api/sessions/${session.id}/send')),
      session,
      '/workflow run code-review PR_NUMBER=42 REPO=owner/repo',
    );

    expect(response, isNotNull);
    final body = await response!.readAsString();
    expect(body, contains('Workflow started'));
    expect(body, contains('Open workflow run'));
    expect(workflows.calls, contains('start:code-review'));
  });

  test('duplicate workflow chat commands are rejected within cooldown', () async {
    final session = await sessions.createSession();
    final fakeNow = <DateTime>[DateTime.utc(2026, 1, 1, 12, 0, 0), DateTime.utc(2026, 1, 1, 12, 0, 5)];
    final handler = ChatCommandHandler(workflows: workflows, definitions: definitions, now: () => fakeNow.removeAt(0));

    final first = await handler.handle(
      Request('POST', Uri.parse('http://localhost/api/sessions/${session.id}/send')),
      session,
      '/workflow run code-review PR_NUMBER=42 REPO=owner/repo',
    );
    final second = await handler.handle(
      Request('POST', Uri.parse('http://localhost/api/sessions/${session.id}/send')),
      session,
      '/workflow run code-review PR_NUMBER=42 REPO=owner/repo',
    );

    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(await second!.readAsString(), contains('already handled recently'));
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
    final messages = MessageService(baseDir: p.join(dataDir, 'sessions'));
    final kv = KvService(filePath: p.join(dataDir, 'kv.json'));
    return _FakeWorkflowService._super(repo, taskService, messages, eventBus, kv, dataDir);
  }

  final List<String> calls = <String>[];
  WorkflowRun? startResult;
  final List<WorkflowRun> activeRuns = <WorkflowRun>[];

  @override
  Future<WorkflowRun> start(
    WorkflowDefinition definition,
    Map<String, String> variables, {
    String? projectId,
    bool headless = false,
  }) async {
    calls.add('start:${definition.name}');
    final run = startResult!;
    activeRuns.add(run.copyWith(definitionName: definition.name, variablesJson: variables));
    return run;
  }

  @override
  Future<List<WorkflowRun>> list({WorkflowRunStatus? status, String? definitionName}) async {
    return activeRuns.where((run) => definitionName == null || run.definitionName == definitionName).toList();
  }
}
