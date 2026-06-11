import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
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
      json: {
        'title': 'Provider task',
        'description': 'Use a specific provider.',
        'type': 'research',
        'provider': 'codex',
      },
      status: 201,
    );

    // Per S35, provider is canonical on the nested AgentExecution object rather
    // than a top-level Task field.
    final agentExecution = body['agentExecution'] as Map<String, dynamic>?;
    expect(agentExecution?['provider'], 'codex');

    final stored = await tasks.get(body['id'] as String);
    expect(stored?.provider, 'codex');
  });
}
