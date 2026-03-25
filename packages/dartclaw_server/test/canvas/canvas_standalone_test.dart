import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

class _NoopTurnManager extends TurnManager {
  _NoopTurnManager({required super.messages, required super.worker})
    : super(behavior: BehaviorFileService(workspaceDir: '/tmp/dartclaw-canvas-standalone-test'));
}

void main() {
  group('canvas standalone page', () {
    late Directory tempDir;
    late SessionService sessions;
    late MessageService messages;
    late FakeAgentHarness worker;
    late TurnManager turns;
    late CanvasService canvasService;
    late Handler handler;

    setUpAll(() {
      initTemplates('packages/dartclaw_server/lib/src/templates');
    });

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('dartclaw_canvas_standalone_test_');
      sessions = SessionService(baseDir: tempDir.path);
      messages = MessageService(baseDir: tempDir.path);
      worker = FakeAgentHarness();
      turns = _NoopTurnManager(messages: messages, worker: worker);
      canvasService = CanvasService();
      handler = canvasRoutes(canvasService: canvasService, turns: turns, sessions: sessions).call;
    });

    tearDown(() async {
      await canvasService.dispose();
      await messages.dispose();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    tearDownAll(() {
      resetTemplates();
    });

    test('interact token renders standalone page with CSP and nickname dialog', () async {
      final token = canvasService.createShareToken(SessionKey.webSession(), permission: CanvasPermission.interact);
      final response = await handler(Request('GET', Uri.parse('http://localhost/${token.token}')));
      final body = await response.readAsString();

      expect(response.statusCode, 200);
      expect(response.headers['content-type'], 'text/html; charset=utf-8');
      expect(response.headers['content-security-policy'], contains("default-src 'none'"));
      expect(body, contains('id="canvas-content"'));
      expect(body, contains('data-stream-url="/canvas/${token.token}/stream"'));
      expect(body, contains('data-action-url="/canvas/${token.token}/action"'));
      expect(body, contains('id="nickname-dialog"'));
      expect(body, isNot(contains('<script src=')));
      expect(body, isNot(contains('<link rel=')));
    });

    test('view-only token omits nickname dialog and marks body as view only', () async {
      final token = canvasService.createShareToken('canvas-view', permission: CanvasPermission.view);
      final response = await handler(Request('GET', Uri.parse('http://localhost/${token.token}')));
      final body = await response.readAsString();

      expect(response.statusCode, 200);
      expect(body, contains('canvas-view-only'));
      expect(body, isNot(contains('id="nickname-dialog"')));
    });

    test('invalid token returns 404', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/not-a-token')));
      expect(response.statusCode, 404);
    });
  });
}
