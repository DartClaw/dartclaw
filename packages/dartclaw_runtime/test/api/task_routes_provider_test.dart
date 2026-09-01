import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

import 'api_test_helpers.dart';

void main() {
  late TaskService tasks;
  late ApiRouteTestClient client;

  setUp(() {
    final db = openTaskDbInMemory();
    tasks = TaskService(
      SqliteTaskRepository(db),
      agentExecutionRepository: SqliteAgentExecutionRepository(db),
      executionTransactor: SqliteExecutionRepositoryTransactor(db),
    );
    client = ApiRouteTestClient(taskRoutes(tasks).call);
  });

  tearDown(() async {
    await tasks.dispose();
  });

  test('POST /api/tasks persists a provider hint on the created task', () async {
    final body = await client.expectJsonObject(
      'POST',
      '/api/tasks',
      json: {'title': 'Provider task', 'description': 'Use a specific provider.', 'provider': 'codex'},
      status: 201,
    );

    // Per S35, provider is canonical on the nested AgentExecution object rather
    // than a top-level Task field.
    final agentExecution = body['agentExecution'] as Map<String, dynamic>?;
    expect(agentExecution?['provider'], 'codex');

    final stored = await tasks.get(body['id'] as String);
    expect(stored?.provider, 'codex');
  });

  test('POST /api/tasks refuses research with explicit-profile remediation', () async {
    final response = await client.request(
      'POST',
      '/api/tasks',
      json: {'title': 'Research', 'description': 'Describe the work', 'type': 'research'},
    );
    expect(response.statusCode, 400);
    expect(await response.readAsString(), allOf(contains('type'), contains('securityProfile'), contains('research')));
    expect(await tasks.list(), isEmpty);
  });

  test('POST /api/tasks persists top-level securityProfile and reserves its configJson key', () async {
    final created = await client.expectJsonObject(
      'POST',
      '/api/tasks',
      json: {'title': 'Restricted task', 'description': 'Describe the work', 'securityProfile': 'restricted'},
      status: 201,
    );
    expect(created['configJson'], containsPair('securityProfile', 'restricted'));

    expect(
      await client.expectJsonErrorCode(
        'POST',
        '/api/tasks',
        json: {
          'title': 'Smuggled profile',
          'description': 'Describe the work',
          'configJson': {'securityProfile': 'restricted'},
        },
        status: 400,
      ),
      'INVALID_INPUT',
    );
  });
}
