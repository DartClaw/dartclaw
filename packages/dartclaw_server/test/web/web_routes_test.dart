import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
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

String _sessionCostPayload({
  required int inputTokens,
  required int outputTokens,
  required int totalTokens,
  required double estimatedCostUsd,
  required int turnCount,
  String? provider,
  int? cachedInputTokens,
}) {
  final payload = <String, dynamic>{
    'input_tokens': inputTokens,
    'output_tokens': outputTokens,
    'total_tokens': totalTokens,
    'estimated_cost_usd': estimatedCostUsd,
    'turn_count': turnCount,
  };
  if (provider != null) {
    payload['provider'] = provider;
  }
  if (cachedInputTokens != null) {
    payload['cached_input_tokens'] = cachedInputTokens;
  }
  return jsonEncode(payload);
}

void main() {
  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  late Directory tempDir;
  late KvService kvService;
  late SessionService sessions;
  late MessageService messages;
  late Handler handler;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_web_test_');
    kvService = KvService(filePath: '${tempDir.path}/kv.json');
    sessions = SessionService(baseDir: tempDir.path);
    messages = MessageService(baseDir: tempDir.path);
    handler = webRoutes(sessions, messages, kvService: kvService).call;
  });

  tearDown(() async {
    await kvService.dispose();
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

    test('GET / with no sessions contains "No chats yet" text', () async {
      final res = await handler(Request('GET', Uri.parse('http://localhost/')));
      final body = await res.readAsString();
      expect(body, contains('No chats yet'));
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

    test('crash banner uses icon system dismiss button', () async {
      handler = webRoutes(
        sessions,
        messages,
        kvService: kvService,
        workerStateGetter: () => WorkerState.crashed,
      ).call;
      final session = await sessions.createSession();

      final res = await handler(Request('GET', Uri.parse('http://localhost/sessions/${session.id}')));
      final body = await res.readAsString();

      expect(body, contains('Agent interrupted'));
      expect(body, contains('class="dismiss" aria-label="Dismiss" data-icon="x"'));
      expect(body, isNot(contains('&#10005;')));
    });

    test('recovery banner uses icon system dismiss button', () async {
      final session = await sessions.createSession();
      handler = webRoutes(
        sessions,
        messages,
        kvService: kvService,
        turns: _RecoveryNoticeTurns({session.id}),
      ).call;

      final res = await handler(Request('GET', Uri.parse('http://localhost/sessions/${session.id}')));
      final body = await res.readAsString();

      expect(body, contains('recovered from an interrupted turn'));
      expect(body, contains('class="dismiss" aria-label="Dismiss" data-icon="x"'));
      expect(body, isNot(contains('&#10005;')));
    });

    test('initial session page renders tail-window pagination state', () async {
      final session = await sessions.createSession();
      for (var i = 1; i <= 250; i++) {
        await messages.insertMessage(
          sessionId: session.id,
          role: 'user',
          content: 'Message ${i.toString().padLeft(3, '0')}',
        );
      }

      final res = await handler(Request('GET', Uri.parse('http://localhost/sessions/${session.id}')));
      final body = await res.readAsString();

      expect(body, contains('Load earlier messages'));
      expect(body, contains('data-earliest-cursor="51"'));
      expect(body, contains('<p>Message 250</p>'));
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

    test('default load returns only the last 200 messages', () async {
      final session = await sessions.createSession();
      for (var i = 1; i <= 250; i++) {
        await messages.insertMessage(
          sessionId: session.id,
          role: 'user',
          content: 'Message ${i.toString().padLeft(3, '0')}',
        );
      }

      final res = await handler(Request('GET', Uri.parse('http://localhost/sessions/${session.id}/messages-html')));
      final body = await res.readAsString();

      expect(body, isNot(contains('<p>Message 001</p>')));
      expect(body, contains('<p>Message 051</p>'));
      expect(body, contains('<p>Message 250</p>'));
    });

    test('before query returns earlier messages without duplicates', () async {
      final session = await sessions.createSession();
      for (var i = 1; i <= 60; i++) {
        await messages.insertMessage(
          sessionId: session.id,
          role: 'user',
          content: 'Message ${i.toString().padLeft(3, '0')}',
        );
      }

      final res = await handler(
        Request('GET', Uri.parse('http://localhost/sessions/${session.id}/messages-html?before=51')),
      );
      final body = await res.readAsString();

      expect(body, contains('<p>Message 001</p>'));
      expect(body, contains('<p>Message 050</p>'));
      expect(body, isNot(contains('<p>Message 051</p>')));
      expect(res.headers['x-dartclaw-earliest-cursor'], '1');
      expect(res.headers['x-dartclaw-has-earlier-messages'], 'false');
    });
  });

  group('GET /sessions/<id>/info', () {
    test('renders stored per-session token totals when usage exists', () async {
      final session = await sessions.createSession();
      await messages.insertMessage(sessionId: session.id, role: 'user', content: 'hello');
      await messages.insertMessage(sessionId: session.id, role: 'assistant', content: 'world');
      await kvService.set(
        'session_cost:${session.id}',
        '{"input_tokens":3,"output_tokens":7,"total_tokens":10,"estimated_cost_usd":0.1,"turn_count":1}',
      );

      final res = await handler(Request('GET', Uri.parse('http://localhost/sessions/${session.id}/info')));
      final body = await res.readAsString();

      expect(res.statusCode, equals(200));
      expect(body, contains('>3<'));
      expect(body, contains('>7<'));
      expect(body, contains('>10<'));
    });

    test('renders Claude cost totals and cached token data from session usage records', () async {
      final session = await sessions.createSession();
      await messages.insertMessage(sessionId: session.id, role: 'user', content: 'hello');
      await messages.insertMessage(sessionId: session.id, role: 'assistant', content: 'world');
      await kvService.set(
        'session_cost:${session.id}',
        _sessionCostPayload(
          inputTokens: 14,
          outputTokens: 6,
          totalTokens: 20,
          estimatedCostUsd: 0.42,
          turnCount: 1,
          provider: 'claude',
          cachedInputTokens: 12,
        ),
      );

      final res = await handler(Request('GET', Uri.parse('http://localhost/sessions/${session.id}/info')));
      final body = await res.readAsString();

      expect(res.statusCode, equals(200));
      expect(body, contains(r'$0.42'));
      expect(body, contains('Cached Input'));
      expect(body, contains('12'));
      expect(body, isNot(contains('cost unavailable')));
    });

    test('renders Codex cost fallback with cached token data and explanatory tooltip', () async {
      final session = await sessions.createSession();
      await messages.insertMessage(sessionId: session.id, role: 'user', content: 'hello');
      await messages.insertMessage(sessionId: session.id, role: 'assistant', content: 'world');
      await kvService.set(
        'session_cost:${session.id}',
        _sessionCostPayload(
          inputTokens: 24,
          outputTokens: 9,
          totalTokens: 33,
          estimatedCostUsd: 0.0,
          turnCount: 2,
          provider: 'codex',
          cachedInputTokens: 17,
        ),
      );

      final res = await handler(Request('GET', Uri.parse('http://localhost/sessions/${session.id}/info')));
      final body = await res.readAsString();

      expect(res.statusCode, equals(200));
      expect(body, contains('cost unavailable'));
      expect(
        body,
        contains('This provider does not report USD cost. Token counts are tracked for governance budgets.'),
      );
      expect(body, contains('Cached Input'));
      expect(body, contains('17'));
    });

    test('defaults legacy session usage records without provider data to Claude-style cost display', () async {
      final session = await sessions.createSession();
      await messages.insertMessage(sessionId: session.id, role: 'user', content: 'hello');
      await messages.insertMessage(sessionId: session.id, role: 'assistant', content: 'world');
      await kvService.set(
        'session_cost:${session.id}',
        _sessionCostPayload(inputTokens: 4, outputTokens: 6, totalTokens: 10, estimatedCostUsd: 0.10, turnCount: 1),
      );

      final res = await handler(Request('GET', Uri.parse('http://localhost/sessions/${session.id}/info')));
      final body = await res.readAsString();

      expect(res.statusCode, equals(200));
      expect(body, contains(r'$0.10'));
      expect(body, isNot(contains('cost unavailable')));
      expect(body, isNot(contains('Cached Input')));
    });

    test('uses the configured default provider for legacy session usage records', () async {
      final handlerWithCodexDefault = webRoutes(
        sessions,
        messages,
        kvService: kvService,
        config: const DartclawConfig(agent: AgentConfig(provider: 'codex')),
      ).call;
      final session = await sessions.createSession();
      await messages.insertMessage(sessionId: session.id, role: 'user', content: 'hello');
      await messages.insertMessage(sessionId: session.id, role: 'assistant', content: 'world');
      await kvService.set(
        'session_cost:${session.id}',
        _sessionCostPayload(inputTokens: 4, outputTokens: 6, totalTokens: 10, estimatedCostUsd: 0.10, turnCount: 1),
      );

      final res = await handlerWithCodexDefault(Request('GET', Uri.parse('http://localhost/sessions/${session.id}/info')));
      final body = await res.readAsString();

      expect(res.statusCode, equals(200));
      expect(body, contains('cost unavailable'));
      expect(body, isNot(contains(r'$0.10')));
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

  test('settings page reflects configured Google Chat even when channel is not connected', () async {
    final handler = webRoutes(
      sessions,
      messages,
      config: const DartclawConfig(
        channels: ChannelConfig(
          channelConfigs: {
            'google_chat': {'enabled': true, 'require_mention': true, 'dm_access': 'open', 'group_access': 'disabled'},
          },
        ),
      ),
    ).call;

    final res = await handler(Request('GET', Uri.parse('http://localhost/settings')));
    final body = await res.readAsString();

    expect(res.statusCode, equals(200));
    expect(body, contains('Google Chat Channel'));
    expect(body, contains('Configured'));
  });

  group('login routes', () {
    test('GET /login preserves next path and token hint in the form', () async {
      final res = await handler(Request('GET', Uri.parse('http://localhost/login?next=%2Ftasks&token=abc123')));
      final body = await res.readAsString();

      expect(res.statusCode, equals(200));
      expect(body, contains('name="next"'));
      expect(body, contains('value="/tasks"'));
      expect(body, contains('value="abc123"'));
    });

    test('POST /login redirects to provided next path on success', () async {
      final handler = webRoutes(
        sessions,
        messages,
        tokenService: TokenService(token: 'a' * 64),
        gatewayToken: 'a' * 64,
      ).call;

      final res = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/login'),
          headers: {'content-type': 'application/x-www-form-urlencoded'},
          body: 'token=${'a' * 64}&next=%2Ftasks%3Fstatus%3Dreview',
        ),
      );

      expect(res.statusCode, equals(302));
      expect(res.headers['location'], '/tasks?status=review');
      expect(res.headers['set-cookie'], contains('dart_session='));
    });

    test('POST /login can set Secure cookie flag', () async {
      final handler = webRoutes(
        sessions,
        messages,
        tokenService: TokenService(token: 'a' * 64),
        gatewayToken: 'a' * 64,
        cookieSecure: true,
      ).call;

      final res = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/login'),
          headers: {'content-type': 'application/x-www-form-urlencoded'},
          body: 'token=${'a' * 64}',
        ),
      );

      expect(res.statusCode, equals(302));
      expect(res.headers['set-cookie'], contains('Secure'));
    });

    test('POST /login fires FailedAuthEvent on invalid token', () async {
      final eventBus = EventBus();
      addTearDown(eventBus.dispose);
      final events = <FailedAuthEvent>[];
      final sub = eventBus.on<FailedAuthEvent>().listen(events.add);
      addTearDown(sub.cancel);

      final handler = webRoutes(
        sessions,
        messages,
        tokenService: TokenService(token: 'a' * 64),
        gatewayToken: 'a' * 64,
        eventBus: eventBus,
      ).call;

      final res = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/login'),
          headers: {'content-type': 'application/x-www-form-urlencoded'},
          body: 'token=wrong',
        ),
      );

      expect(res.statusCode, equals(200));
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));
      expect(events.single.source, 'login');
      expect(events.single.reason, 'invalid_login_token');
      expect(events.single.limited, isFalse);
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

class _RecoveryNoticeTurns implements TurnManager {
  _RecoveryNoticeTurns(this._sessionIds);

  final Set<String> _sessionIds;

  @override
  bool consumeRecoveryNotice(String sessionId) => _sessionIds.remove(sessionId);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not implemented in _RecoveryNoticeTurns');
}
