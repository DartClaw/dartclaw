import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_server/src/api/chat_command_handler.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart'
    show SqliteTaskRepository, SqliteWorkflowRunRepository, openTaskDbInMemory;
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show InMemoryDefinitionSource, WorkflowDefinitionSource, WorkflowService;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

class _FakeTurnManager extends TurnManager {
  _FakeTurnManager(MessageService messages, AgentHarness worker)
    : super(
        messages: messages,
        worker: worker,
        behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent'),
      );

  bool reserveCalled = false;

  @override
  Future<String> reserveTurn(
    String sessionId, {
    String agentName = 'main',
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
    bool isHumanInput = false,
    BehaviorFileService? behaviorOverride,
    PromptScope? promptScope,
  }) async {
    reserveCalled = true;
    return 'turn-1';
  }

  @override
  void executeTurn(
    String sessionId,
    String turnId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
    bool resume = false,
  }) {}

  @override
  void releaseTurn(String sessionId, String turnId) {}

  @override
  bool isActive(String sessionId) => false;

  @override
  String? activeTurnId(String sessionId) => null;

  @override
  bool isActiveTurn(String sessionId, String turnId) => false;

  @override
  TurnOutcome? recentOutcome(String sessionId, String turnId) => null;

  @override
  Future<TurnOutcome> waitForOutcome(String sessionId, String turnId) => Completer<TurnOutcome>().future;

  @override
  Future<void> cancelTurn(String sessionId) async {}
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

  WorkflowRun? startResult;

  @override
  Future<WorkflowRun> start(
    WorkflowDefinition definition,
    Map<String, String> variables, {
    String? projectId,
    bool allowDirtyLocalPath = false,
    bool headless = false,
  }) async {
    for (final entry in definition.variables.entries) {
      if (entry.value.required && !variables.containsKey(entry.key)) {
        throw ArgumentError('Required variable "${entry.key}" not provided');
      }
    }
    return startResult!;
  }
}

void main() {
  late Directory tempDir;
  late SessionService sessions;
  late MessageService messages;
  late FakeAgentHarness worker;
  late _FakeTurnManager turns;
  late Handler handler;
  late _FakeWorkflowService workflows;
  late WorkflowDefinitionSource definitions;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('session-chat-command-test_');
    sessions = SessionService(baseDir: tempDir.path);
    messages = MessageService(baseDir: tempDir.path);
    worker = FakeAgentHarness();
    turns = _FakeTurnManager(messages, worker);

    final eventBus = EventBus();
    final taskDb = openTaskDbInMemory();
    final taskRepo = SqliteTaskRepository(taskDb);
    final tasks = TaskService(taskRepo, eventBus: eventBus);
    workflows = _FakeWorkflowService(
      db: sqlite3.openInMemory(),
      taskService: tasks,
      eventBus: eventBus,
      dataDir: tempDir.path,
    );
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
        description: 'Review a pull request',
        variables: const {'PR_NUMBER': WorkflowVariable(required: true), 'REPO': WorkflowVariable(required: true)},
        steps: const [
          WorkflowStep(id: 'step-1', name: 'Review', prompts: ['Review']),
        ],
      ),
    ]);

    handler = sessionRoutes(
      sessions,
      messages,
      turns,
      worker,
      chatCommandHandler: ChatCommandHandler(workflows: workflows, definitions: definitions),
    ).call;
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('workflow chat commands are intercepted before message persistence', () async {
    final session = await sessions.createSession();

    final response = await handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/sessions/${session.id}/send'),
        body: 'message=%2Fworkflow+run+code-review+PR_NUMBER%3D42+REPO%3Downer%2Frepo',
        headers: {'content-type': 'application/x-www-form-urlencoded'},
      ),
    );

    expect(response.statusCode, 200);
    final body = await response.readAsString();
    expect(body, contains('Workflow started'));
    expect(await messages.getMessages(session.id), isEmpty);
    expect(turns.reserveCalled, isFalse);
  });

  test('invalid workflow chat commands still intercept without persisting messages', () async {
    final session = await sessions.createSession();

    final response = await handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/sessions/${session.id}/send'),
        body: 'message=%2Fworkflow+run+code-review+PR_NUMBER%3D42',
        headers: {'content-type': 'application/x-www-form-urlencoded'},
      ),
    );

    expect(response.statusCode, 200);
    final body = await response.readAsString();
    expect(body, contains('Required variable'));
    expect(body, contains('REPO'));
    expect(await messages.getMessages(session.id), isEmpty);
    expect(turns.reserveCalled, isFalse);
  });
}
