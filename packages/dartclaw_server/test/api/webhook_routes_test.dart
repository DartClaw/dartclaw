import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_core/src/channel/channel_config.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_server/src/auth/auth_utils.dart';
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Minimal test doubles — WhatsApp
// ---------------------------------------------------------------------------
class _FakeGowaManager extends GowaManager {
  _FakeGowaManager()
    : super(
        executable: 'whatsapp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          return _NeverExitProcess();
        },
      );

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> sendText(String jid, String text) async {}

  @override
  Future<void> sendMedia(String jid, String filePath, {String? caption}) async {}

  @override
  Future<GowaStatus> getStatus() async => (isConnected: false, isLoggedIn: false, deviceId: null);

  @override
  Future<GowaLoginQr> getLoginQr() async => (url: null, durationSeconds: 60);
}

class _FakeChannelManager extends ChannelManager {
  _FakeChannelManager()
    : super(
        queue: MessageQueue(dispatcher: (_, _, {senderJid}) async => '', maxConcurrentTurns: 1),
        config: const ChannelConfig.defaults(),
      );

  @override
  void handleInboundMessage(ChannelMessage message) {}
}

class _FakeGoogleChatRestClient extends GoogleChatRestClient {
  _FakeGoogleChatRestClient() : super(authClient: MockClient((request) async => throw UnimplementedError()));
}

class _FakeGoogleJwtVerifier extends GoogleJwtVerifier {
  _FakeGoogleJwtVerifier()
    : super(
        audience: const GoogleChatAudienceConfig(
          mode: GoogleChatAudienceMode.appUrl,
          value: 'https://example.com/integrations/googlechat',
        ),
      );

  @override
  Future<bool> verify(String? authHeader) async => true;
}

class _NeverExitProcess implements Process {
  @override
  int get pid => 1;
  @override
  IOSink get stdin => _NullIOSink();
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  Future<int> get exitCode => Future.value(0);
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

class _NullIOSink implements IOSink {
  @override
  Encoding get encoding => utf8;
  @override
  set encoding(Encoding value) {}
  @override
  void add(List<int> data) {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) => Future.value();
  @override
  Future<void> close() => Future.value();
  @override
  Future<void> get done => Future.value();
  @override
  Future<void> flush() => Future.value();
  @override
  void write(Object? object) {}
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {}
  @override
  void writeCharCode(int charCode) {}
  @override
  void writeln([Object? object = '']) {}
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
void main() {
  late WhatsAppChannel channel;

  setUp(() {
    channel = WhatsAppChannel(
      gowa: _FakeGowaManager(),
      config: WhatsAppConfig(enabled: true),
      dmAccess: DmAccessController(mode: DmAccessMode.open),
      mentionGating: MentionGating(requireMention: false, mentionPatterns: [], ownJid: ''),
      channelManager: _FakeChannelManager(),
      workspaceDir: '/tmp',
    );
  });

  group('webhook secret validation', () {
    test('correct secret returns 200', () async {
      final router = webhookRoutes(whatsApp: channel, webhookSecret: 'abc');
      final handler = const Pipeline().addHandler(router.call);
      final response = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/webhook/whatsapp?secret=abc'),
          body: '{"event":"message","payload":{}}',
        ),
      );
      expect(response.statusCode, 200);
    });

    test('wrong secret returns 403', () async {
      final eventBus = EventBus();
      addTearDown(eventBus.dispose);
      final events = <FailedAuthEvent>[];
      final sub = eventBus.on<FailedAuthEvent>().listen(events.add);
      addTearDown(sub.cancel);

      final router = webhookRoutes(whatsApp: channel, webhookSecret: 'abc', eventBus: eventBus);
      final handler = const Pipeline().addHandler(router.call);
      final response = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/webhook/whatsapp?secret=wrong'),
          body: '{"event":"message","payload":{}}',
        ),
      );
      expect(response.statusCode, 403);
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));
      expect(events.single.source, 'webhook');
      expect(events.single.reason, 'invalid_webhook_secret');
      expect(events.single.limited, isFalse);
    });

    test('missing secret returns 403', () async {
      final router = webhookRoutes(whatsApp: channel, webhookSecret: 'abc');
      final handler = const Pipeline().addHandler(router.call);
      final response = await handler(
        Request('POST', Uri.parse('http://localhost/webhook/whatsapp'), body: '{"event":"message","payload":{}}'),
      );
      expect(response.statusCode, 403);
    });

    test('null webhookSecret accepts all requests', () async {
      final router = webhookRoutes(whatsApp: channel, webhookSecret: null);
      final handler = const Pipeline().addHandler(router.call);
      final response = await handler(
        Request('POST', Uri.parse('http://localhost/webhook/whatsapp'), body: '{"event":"message","payload":{}}'),
      );
      expect(response.statusCode, 200);
    });
  });

  group('WhatsApp webhook payload size limit', () {
    test('returns 413 when Content-Length exceeds limit', () async {
      final router = webhookRoutes(whatsApp: channel, webhookSecret: null);
      final handler = const Pipeline().addHandler(router.call);
      final response = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/webhook/whatsapp'),
          body: '',
          headers: {'content-length': '${maxWebhookPayloadBytes + 1}'},
        ),
      );
      expect(response.statusCode, 413);
    });

    test('returns 413 when body exceeds limit', () async {
      final router = webhookRoutes(whatsApp: channel, webhookSecret: null);
      final handler = const Pipeline().addHandler(router.call);
      final oversizedBody = 'x' * (maxWebhookPayloadBytes + 1);
      final response = await handler(
        Request('POST', Uri.parse('http://localhost/webhook/whatsapp'), body: oversizedBody),
      );
      expect(response.statusCode, 413);
    });

    test('accepts body within limit', () async {
      final router = webhookRoutes(whatsApp: channel, webhookSecret: null);
      final handler = const Pipeline().addHandler(router.call);
      final response = await handler(
        Request('POST', Uri.parse('http://localhost/webhook/whatsapp'), body: '{"event":"message","payload":{}}'),
      );
      expect(response.statusCode, 200);
    });
  });

  test('mounts Google Chat webhook at configured path', () async {
    final router = webhookRoutes(
      googleChat: GoogleChatWebhookHandler(
        channel: GoogleChatChannel(
          config: const GoogleChatConfig(webhookPath: '/integrations/googlechat', typingIndicator: false),
          restClient: _FakeGoogleChatRestClient(),
        ),
        jwtVerifier: _FakeGoogleJwtVerifier(),
        config: const GoogleChatConfig(webhookPath: '/integrations/googlechat', typingIndicator: false),
        channelManager: _FakeChannelManager(),
      ),
    );
    final handler = const Pipeline().addHandler(router.call);

    final response = await handler(
      Request(
        'POST',
        Uri.parse('http://localhost/integrations/googlechat'),
        headers: {'authorization': 'Bearer token'},
        body: jsonEncode({
          'type': 'MESSAGE',
          'space': {'name': 'spaces/AAAA', 'type': 'DM'},
          'message': {
            'name': 'spaces/AAAA/messages/BBBB',
            'text': 'hello',
            'sender': {'name': 'users/123', 'type': 'HUMAN'},
          },
          'user': {'name': 'users/123', 'displayName': 'Alice'},
        }),
      ),
    );

    expect(response.statusCode, 200);
  });
}
