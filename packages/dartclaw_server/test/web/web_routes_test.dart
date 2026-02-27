import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/web/web_routes.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late SessionService sessions;
  late MessageService messages;
  late Handler handler;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_web_test_');
    sessions = SessionService(baseDir: tempDir.path);
    messages = MessageService(baseDir: tempDir.path);
    handler = webRoutes(sessions, messages).call;
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  // -------------------------------------------------------------------------
  group('GET /', () {
    test('redirects to existing session when sessions exist', () async {
      final session = await sessions.createSession();
      final res = await handler(Request('GET', Uri.parse('http://localhost/')));
      expect(res.statusCode, equals(302));
      expect(res.headers['location'], contains('/sessions/${session.id}'));
    });

    test('returns 200 with empty state when no sessions exist', () async {
      final res = await handler(Request('GET', Uri.parse('http://localhost/')));
      expect(res.statusCode, equals(200));
    });

    test('GET / with no sessions contains "No sessions yet" text', () async {
      final res = await handler(Request('GET', Uri.parse('http://localhost/')));
      final body = await res.readAsString();
      expect(body, contains('No sessions yet'));
    });
  });

  // -------------------------------------------------------------------------
  group('GET /sessions/<id>', () {
    test('returns 200 with HTML content-type', () async {
      final session = await sessions.createSession();
      final res = await handler(Request('GET', Uri.parse('http://localhost/sessions/${session.id}')));
      expect(res.statusCode, equals(200));
      expect(res.headers['content-type'], contains('text/html'));
    });

    test('returns 404 for unknown session id', () async {
      final res = await handler(Request('GET', Uri.parse('http://localhost/sessions/nonexistent')));
      expect(res.statusCode, equals(404));
    });

    test('response body contains session structure', () async {
      final session = await sessions.createSession();
      final res = await handler(Request('GET', Uri.parse('http://localhost/sessions/${session.id}')));
      final body = await res.readAsString();
      expect(body, anyOf(contains('class="shell"'), contains('class="sidebar"'), contains('class="chat-area"')));
    });

    test('response body escapes XSS in session title', () async {
      final session = await sessions.createSession();
      await sessions.updateTitle(session.id, '<script>alert(1)</script>');
      final res = await handler(Request('GET', Uri.parse('http://localhost/sessions/${session.id}')));
      final body = await res.readAsString();
      expect(body, contains('&lt;script&gt;'));
      expect(body, isNot(contains('<script>alert')));
    });

    test('response body contains messages section', () async {
      final session = await sessions.createSession();
      await messages.insertMessage(sessionId: session.id, role: 'user', content: 'Hello');
      final res = await handler(Request('GET', Uri.parse('http://localhost/sessions/${session.id}')));
      final body = await res.readAsString();
      expect(body, anyOf(contains('msg-user'), contains('msg-assistant')));
    });

    test('response contains data-session-id attribute', () async {
      final session = await sessions.createSession();
      final res = await handler(Request('GET', Uri.parse('http://localhost/sessions/${session.id}')));
      final body = await res.readAsString();
      expect(body, contains('data-session-id'));
    });
  });

  // -------------------------------------------------------------------------
  group('GET /sessions/<id>/messages-html', () {
    test('returns 200 with HTML content-type', () async {
      final session = await sessions.createSession();
      final res = await handler(Request('GET', Uri.parse('http://localhost/sessions/${session.id}/messages-html')));
      expect(res.statusCode, equals(200));
      expect(res.headers['content-type'], contains('text/html'));
    });

    test('returns 404 for unknown session id', () async {
      final res = await handler(Request('GET', Uri.parse('http://localhost/sessions/nonexistent/messages-html')));
      expect(res.statusCode, equals(404));
    });

    test('returns empty state for no messages', () async {
      final session = await sessions.createSession();
      final res = await handler(Request('GET', Uri.parse('http://localhost/sessions/${session.id}/messages-html')));
      final body = await res.readAsString();
      expect(body, contains('empty-state'));
    });

    test('returns message list when messages exist', () async {
      final session = await sessions.createSession();
      await messages.insertMessage(sessionId: session.id, role: 'user', content: 'Hello');
      final res = await handler(Request('GET', Uri.parse('http://localhost/sessions/${session.id}/messages-html')));
      final body = await res.readAsString();
      expect(body, contains('msg-user'));
    });

    test('assistant message has data-markdown attribute', () async {
      final session = await sessions.createSession();
      await messages.insertMessage(sessionId: session.id, role: 'assistant', content: 'Hi there');
      final res = await handler(Request('GET', Uri.parse('http://localhost/sessions/${session.id}/messages-html')));
      final body = await res.readAsString();
      expect(body, contains('data-markdown'));
    });
  });
}
