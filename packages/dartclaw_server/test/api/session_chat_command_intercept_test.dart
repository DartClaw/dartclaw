import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_server/dartclaw_server.dart' hide TurnManager;
import 'package:dartclaw_server/src/api/chat_command_handler.dart';
import 'package:dartclaw_server/src/auth/request_auth_context.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart' show SqliteTaskRepository, openTaskDbInMemory;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide FakeTurnManager, TurnManager;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        InMemoryDefinitionSource,
        WorkflowDefinition,
        WorkflowDefinitionSource,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowStep,
        WorkflowVariable;
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../session_turn_manager_test_support.dart';
import 'workflow_test_support.dart';

void main() {
  late Directory tempDir;
  late SessionService sessions;
  late MessageService messages;
  late FakeAgentHarness worker;
  late FakeTurnManager turns;
  late Handler handler;
  late FakeWorkflowService workflows;
  late WorkflowDefinitionSource definitions;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('session-chat-command-test_');
    sessions = SessionService(baseDir: tempDir.path);
    messages = MessageService(baseDir: tempDir.path);
    worker = FakeAgentHarness();
    turns = FakeTurnManager(messages, worker);

    final eventBus = EventBus();
    final taskDb = openTaskDbInMemory();
    final taskRepo = SqliteTaskRepository(taskDb);
    final tasks = TaskService(taskRepo, eventBus: eventBus);
    workflows = FakeWorkflowService(
      db: sqlite3.openInMemory(),
      taskService: tasks,
      eventBus: eventBus,
      dataDir: tempDir.path,
    );
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
      withAdminAuthContext(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sessions/${session.id}/send'),
          body: 'message=%2Fworkflow+run+code-review+PR_NUMBER%3D42+REPO%3Downer%2Frepo',
          headers: {'content-type': 'application/x-www-form-urlencoded'},
        ),
      ),
    );

    expect(response.statusCode, 200);
    final body = await response.readAsString();
    expect(body, contains('Workflow started'));
    expect(await messages.getMessages(session.id), isEmpty);
    expect(turns.reserveCalled, isFalse);
  });

  test('non-admin workflow run commands are rejected before message persistence', () async {
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
    expect(body, contains('Workflow run requires admin access'));
    expect(await messages.getMessages(session.id), isEmpty);
    expect(turns.reserveCalled, isFalse);
  });

  test('invalid workflow chat commands still intercept without persisting messages', () async {
    final session = await sessions.createSession();

    final response = await handler(
      withAdminAuthContext(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sessions/${session.id}/send'),
          body: 'message=%2Fworkflow+run+code-review+PR_NUMBER%3D42',
          headers: {'content-type': 'application/x-www-form-urlencoded'},
        ),
      ),
    );

    expect(response.statusCode, 200);
    final body = await response.readAsString();
    expect(body, contains('Missing required variable(s)'));
    expect(body, contains('REPO'));
    expect(await messages.getMessages(session.id), isEmpty);
    expect(turns.reserveCalled, isFalse);
  });

  test('command discovery exposes workflow run for admin writable sessions', () async {
    final session = await sessions.createSession();

    final response = await handler(
      withAdminAuthContext(Request('GET', Uri.parse('http://localhost/api/sessions/${session.id}/commands'))),
    );

    expect(response.statusCode, 200);
    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    final commands = body['commands'] as List<dynamic>;
    expect(
      commands,
      contains(predicate((command) => (command as Map<String, dynamic>)['insertText'] == '/workflow list')),
    );
    expect(
      commands,
      contains(predicate((command) => (command as Map<String, dynamic>)['insertText'] == '/workflow run ')),
    );
  });

  test('command discovery hides workflow run without admin permission', () async {
    final session = await sessions.createSession();

    final response = await handler(Request('GET', Uri.parse('http://localhost/api/sessions/${session.id}/commands')));

    expect(response.statusCode, 200);
    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    final commands = body['commands'] as List<dynamic>;
    expect(
      commands,
      contains(predicate((command) => (command as Map<String, dynamic>)['insertText'] == '/workflow list')),
    );
    expect(
      commands,
      isNot(contains(predicate((command) => (command as Map<String, dynamic>)['insertText'] == '/workflow run '))),
    );
  });

  test('command discovery hides commands for archived sessions', () async {
    final session = await sessions.createSession(type: SessionType.archive);

    final response = await handler(Request('GET', Uri.parse('http://localhost/api/sessions/${session.id}/commands')));

    expect(response.statusCode, 200);
    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    expect(body['commands'], isEmpty);
  });
}
