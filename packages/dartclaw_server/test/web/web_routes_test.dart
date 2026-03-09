import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

class _FakeGowaManager extends GowaManager {
  _FakeGowaManager({required this.running, required this.loggedIn, this.pairedJidValue})
    : super(executable: '', host: '', port: 0, webhookUrl: '', osName: '');

  final bool running;
  final bool loggedIn;
  final String? pairedJidValue;

  @override
  bool get isRunning => running;

  @override
  String? get pairedJid => pairedJidValue;

  @override
  Future<GowaStatus> getStatus() async => (isConnected: loggedIn, isLoggedIn: loggedIn, deviceId: pairedJidValue);
}

class _FakeSignalCliManager extends SignalCliManager {
  _FakeSignalCliManager({required this.running, required this.registered})
    : super(executable: '', host: '', port: 0, phoneNumber: '');

  final bool running;
  final bool registered;

  @override
  bool get isRunning => running;

  @override
  Future<bool> isAccountRegistered() async => registered;
}

void main() {
  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

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
      // Title in <title> tag and sidebar tl:text are fully entity-escaped.
      expect(body, contains('&lt;script&gt;'));
      // Ensure <script>alert does NOT appear in text content (outside attributes).
      // In properly-quoted attribute values (e.g. input value="..."), <> are
      // safe per HTML5 spec and do not execute.
      expect(body, isNot(RegExp(r'>[^<]*<script>alert')));
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

  group('GET /settings/channels/<type>', () {
    test('renders WhatsApp detail page when pairing is still needed', () async {
      final handler = webRoutes(
        sessions,
        messages,
        whatsAppChannel: WhatsAppChannel(
          gowa: _FakeGowaManager(running: true, loggedIn: false),
          config: const WhatsAppConfig(enabled: true),
          dmAccess: DmAccessController(mode: DmAccessMode.open),
          mentionGating: MentionGating(requireMention: false, mentionPatterns: [], ownJid: ''),
          workspaceDir: tempDir.path,
        ),
      ).call;

      final res = await handler(Request('GET', Uri.parse('http://localhost/settings/channels/whatsapp')));
      final body = await res.readAsString();

      expect(res.statusCode, equals(200));
      expect(body, contains('Pairing needed'));
      expect(body, contains('Pairing / Registration'));
      expect(body, isNot(contains('Disconnect')));
    });

    test('renders WhatsApp detail page when connected', () async {
      final handler = webRoutes(
        sessions,
        messages,
        whatsAppChannel: WhatsAppChannel(
          gowa: _FakeGowaManager(running: true, loggedIn: true, pairedJidValue: '15551234567:4@s.whatsapp.net'),
          config: const WhatsAppConfig(enabled: true),
          dmAccess: DmAccessController(mode: DmAccessMode.pairing),
          mentionGating: MentionGating(requireMention: false, mentionPatterns: [], ownJid: ''),
          workspaceDir: tempDir.path,
        ),
      ).call;

      final res = await handler(Request('GET', Uri.parse('http://localhost/settings/channels/whatsapp')));
      final body = await res.readAsString();

      expect(res.statusCode, equals(200));
      expect(body, contains('WhatsApp'));
      expect(body, contains('Pairing / Registration'));
      expect(body, isNot(contains('This page covers access policy and routing')));
    });

    test('renders Signal detail page when pairing is still needed', () async {
      final handler = webRoutes(
        sessions,
        messages,
        signalChannel: SignalChannel(
          sidecar: _FakeSignalCliManager(running: true, registered: false),
          config: const SignalConfig(enabled: true),
          dmAccess: DmAccessController(mode: DmAccessMode.open),
          mentionGating: SignalMentionGating(requireMention: false, mentionPatterns: const [], ownNumber: ''),
          dataDir: tempDir.path,
        ),
      ).call;

      final res = await handler(Request('GET', Uri.parse('http://localhost/settings/channels/signal')));
      final body = await res.readAsString();

      expect(res.statusCode, equals(200));
      expect(body, contains('Pairing needed'));
      expect(body, contains('Pairing / Registration'));
      expect(body, isNot(contains('Disconnect')));
    });
  });

  // -------------------------------------------------------------------------
  group('Security headers and SPA fragment behaviour', () {
    test('Vary: HX-Request header present on responses', () async {
      final pipeline = const Pipeline()
          .addMiddleware(securityHeadersMiddleware())
          .addHandler(webRoutes(sessions, messages).call);
      final res = await pipeline(Request('GET', Uri.parse('http://localhost/')));
      expect(res.headers['vary'], contains('HX-Request'));
    });

    test('HX-Request: true returns fragment without DOCTYPE', () async {
      final session = await sessions.createSession();
      final res = await handler(
        Request('GET', Uri.parse('http://localhost/sessions/${session.id}'), headers: {'HX-Request': 'true'}),
      );
      expect(res.statusCode, equals(200));
      final body = await res.readAsString();
      expect(body, isNot(contains('<!DOCTYPE html>')));
      expect(body, contains('id="main-content"'));
    });
  });
}
