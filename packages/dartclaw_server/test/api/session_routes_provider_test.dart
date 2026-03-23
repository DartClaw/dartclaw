import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

Request _jsonRequest(String method, String path, [Map<String, dynamic>? body]) {
  return Request(
    method,
    Uri.parse('http://localhost$path'),
    body: body == null ? null : jsonEncode(body),
    headers: {'content-type': 'application/json'},
  );
}

Request _formRequest(String method, String path, Map<String, String> body) {
  return Request(
    method,
    Uri.parse('http://localhost$path'),
    body: Uri(queryParameters: body).query,
    headers: {'content-type': 'application/x-www-form-urlencoded'},
  );
}

Future<String> _errorCode(Response response) async {
  final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
  return body['error']['code'] as String;
}

void main() {
  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  late Directory tempDir;
  late SessionService sessions;
  late MessageService messages;
  late TurnManager turns;
  late AgentHarness primaryWorker;
  late AgentHarness codexWorker;
  late Handler handler;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_session_routes_provider_test_');
    sessions = SessionService(baseDir: tempDir.path);
    messages = MessageService(baseDir: tempDir.path);
    primaryWorker = FakeAgentHarness();
    codexWorker = FakeAgentHarness();
    turns = TurnManager.fromPool(
      pool: HarnessPool(
        runners: [
          TurnRunner(
            harness: primaryWorker,
            messages: messages,
            behavior: BehaviorFileService(workspaceDir: tempDir.path),
            sessions: sessions,
            providerId: 'claude',
          ),
          TurnRunner(
            harness: codexWorker,
            messages: messages,
            behavior: BehaviorFileService(workspaceDir: tempDir.path),
            sessions: sessions,
            providerId: 'codex',
          ),
        ],
      ),
      sessions: sessions,
    );
    handler = sessionRoutes(sessions, messages, turns, primaryWorker).call;
  });

  tearDown(() async {
    await messages.dispose();
    await turns.pool.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('POST /api/sessions persists a provider override for the session', () async {
    final response = await handler(_jsonRequest('POST', '/api/sessions', {'provider': 'codex'}));

    expect(response.statusCode, 201);
    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    expect(body['provider'], 'codex');

    final stored = await sessions.getSession(body['id'] as String);
    expect(stored, isNotNull);
    expect(stored!.provider, 'codex');
  });

  test('POST /api/sessions rejects unavailable providers explicitly', () async {
    final response = await handler(_jsonRequest('POST', '/api/sessions', {'provider': 'bogus'}));

    expect(response.statusCode, 400);
    expect(await _errorCode(response), 'PROVIDER_UNAVAILABLE');
  });

  test('POST /api/sessions/<id>/send returns provider-specific busy error when matching workers are busy', () async {
    final session = await sessions.createSession(provider: 'codex');
    final busyRunner = turns.pool.tryAcquireForProvider('codex');
    expect(busyRunner, isNotNull);
    addTearDown(() => turns.pool.release(busyRunner!));

    final response = await handler(_formRequest('POST', '/api/sessions/${session.id}/send', {'message': 'Hello'}));

    expect(response.statusCode, 409);
    expect(await _errorCode(response), 'AGENT_BUSY_PROVIDER');
  });

  test('POST /api/sessions/<id>/send rejects persisted unavailable providers explicitly', () async {
    final session = await sessions.createSession(provider: 'bogus');

    final response = await handler(_formRequest('POST', '/api/sessions/${session.id}/send', {'message': 'Hello'}));

    expect(response.statusCode, 409);
    expect(await _errorCode(response), 'PROVIDER_UNAVAILABLE');
  });
}
