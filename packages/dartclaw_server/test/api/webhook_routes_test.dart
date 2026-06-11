import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide GoogleJwtVerifier, HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
import 'package:dartclaw_server/src/auth/auth_utils.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../whatsapp_test_support.dart';

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
void main() {
  late WhatsAppChannel channel;

  setUp(() {
    channel = WhatsAppChannel(
      gowa: FakeGowaManager(),
      config: WhatsAppConfig(enabled: true),
      dmAccess: DmAccessController(mode: DmAccessMode.open),
      mentionGating: MentionGating(requireMention: false, mentionPatterns: [], ownJid: ''),
      channelManager: FakeChannelManager(),
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
          config: const GoogleChatConfig(
            webhookPath: '/integrations/googlechat',
            typingIndicatorMode: TypingIndicatorMode.disabled,
          ),
          restClient: FakeGoogleChatRestClient(),
        ),
        jwtVerifier: FakeGoogleJwtVerifier(),
        config: const GoogleChatConfig(
          webhookPath: '/integrations/googlechat',
          typingIndicatorMode: TypingIndicatorMode.disabled,
        ),
        channelManager: FakeChannelManager(),
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
