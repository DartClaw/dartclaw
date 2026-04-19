import 'dart:convert';

import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

Request _jsonRequest(String method, String path, [Map<String, dynamic>? body]) {
  return Request(
    method,
    Uri.parse('http://localhost$path'),
    body: body == null ? null : jsonEncode(body),
    headers: {'content-type': 'application/json'},
  );
}

void main() {
  late TaskService tasks;
  late Handler handler;

  setUp(() {
    final db = openTaskDbInMemory();
    tasks = TaskService(
      SqliteTaskRepository(db),
      agentExecutionRepository: SqliteAgentExecutionRepository(db),
      executionTransactor: SqliteExecutionRepositoryTransactor(db),
    );
    handler = taskRoutes(tasks).call;
  });

  tearDown(() async {
    await tasks.dispose();
  });

  test('POST /api/tasks persists a provider hint on the created task', () async {
    final response = await handler(
      _jsonRequest('POST', '/api/tasks', {
        'title': 'Provider task',
        'description': 'Use a specific provider.',
        'type': 'research',
        'provider': 'codex',
      }),
    );

    expect(response.statusCode, 201);
    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    // Per S35, provider is canonical on the nested AgentExecution object rather
    // than a top-level Task field.
    final agentExecution = body['agentExecution'] as Map<String, dynamic>?;
    expect(agentExecution?['provider'], 'codex');

    final stored = await tasks.get(body['id'] as String);
    expect(stored?.provider, 'codex');
  });
}
