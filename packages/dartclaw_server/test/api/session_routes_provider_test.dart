import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_server/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_server/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../test_utils.dart';
import '../execution_coordinator_test_support.dart';
import 'api_test_helpers.dart' show jsonRequest;

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
    turns = turnManagerForRunners([
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
    ], sessions: sessions);
    handler = sessionRoutes(sessions, messages, turns, primaryWorker).call;
  });

  tearDown(() async {
    await messages.dispose();
    await turns.executions.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('POST /api/sessions rejects provider overrides on interactive sessions', () async {
    final response = await handler(jsonRequest('POST', '/api/sessions', {'provider': 'codex'}));

    expect(response.statusCode, 400);
    expect(await _errorCode(response), 'PROVIDER_OVERRIDE_UNSUPPORTED');
  });

  test('POST /api/sessions rejects unavailable providers explicitly', () async {
    final response = await handler(jsonRequest('POST', '/api/sessions', {'provider': 'bogus'}));

    expect(response.statusCode, 400);
    expect(await _errorCode(response), 'PROVIDER_OVERRIDE_UNSUPPORTED');
  });

  test('POST /api/sessions/<id>/send returns provider-specific busy error when matching workers are busy', () async {
    final session = await sessions.createSession(type: SessionType.logicalAgent, provider: 'codex');
    final busyLease = await turns.executions.acquire(
      ExecutionRequest(
        surface: ExecutionSurface.task,
        providerId: 'codex',
        sessionId: 'busy',
        fingerprint: turns.executions.fingerprintFor('codex', 'workspace'),
      ),
    );
    expect(busyLease, isNotNull);
    addTearDown(busyLease!.release);

    final response = await handler(_formRequest('POST', '/api/sessions/${session.id}/send', {'message': 'Hello'}));

    expect(response.statusCode, 409);
    expect(await _errorCode(response), 'AGENT_BUSY_PROVIDER');
  });

  test('POST /api/sessions/<id>/send rejects persisted unavailable providers explicitly', () async {
    final session = await sessions.createSession(type: SessionType.logicalAgent, provider: 'bogus');

    final response = await handler(_formRequest('POST', '/api/sessions/${session.id}/send', {'message': 'Hello'}));

    expect(response.statusCode, 409);
    expect(await _errorCode(response), 'PROVIDER_UNAVAILABLE');
  });
}
