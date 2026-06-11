import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart' show TaskService;
import 'package:dartclaw_server/src/api/chat_command_handler.dart';
import 'package:dartclaw_server/src/auth/request_auth_context.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart' show SqliteTaskRepository, openTaskDbInMemory;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        InMemoryDefinitionSource,
        WorkflowDefinition,
        WorkflowDefinitionSource,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowStep,
        WorkflowVariable;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'workflow_test_support.dart';

void main() {
  late Database taskDb;
  late Database workflowDb;
  late TaskService tasks;
  late FakeWorkflowService workflows;
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
    workflows = FakeWorkflowService(db: workflowDb, taskService: tasks, eventBus: eventBus, dataDir: tempDir.path);
    workflows.validateRequiredVars = true;
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

    final response = await handler.handle(_adminSendRequest(session.id), session, '/workflow list');

    expect(response, isNotNull);
    expect(response!.statusCode, 200);
    expect(await response.readAsString(), contains('code-review'));
  });

  test('/workflow run starts a workflow and returns a link card', () async {
    final session = await sessions.createSession();
    final handler = ChatCommandHandler(workflows: workflows, definitions: definitions);

    final response = await handler.handle(
      _adminSendRequest(session.id),
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
      _adminSendRequest(session.id),
      session,
      '/workflow run code-review PR_NUMBER=42 REPO=owner/repo',
    );
    final second = await handler.handle(
      _adminSendRequest(session.id),
      session,
      '/workflow run code-review PR_NUMBER=42 REPO=owner/repo',
    );

    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(await second!.readAsString(), contains('already handled recently'));
  });

  test('/workflow run returns an error card when required variables are missing', () async {
    final session = await sessions.createSession();
    final handler = ChatCommandHandler(workflows: workflows, definitions: definitions);

    final response = await handler.handle(
      _adminSendRequest(session.id),
      session,
      '/workflow run code-review PR_NUMBER=42',
    );

    expect(response, isNotNull);
    final body = await response!.readAsString();
    expect(body, contains('Required variable'));
    expect(body, contains('REPO'));
    expect(workflows.calls, isEmpty);
  });
}

Request _adminSendRequest(String sessionId) {
  return withAdminAuthContext(Request('POST', Uri.parse('http://localhost/api/sessions/$sessionId/send')));
}
