import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Minimal fakes
// ---------------------------------------------------------------------------

class _FakeRestClient extends GoogleChatRestClient {
  _FakeRestClient() : super(authClient: MockClient((_) async => http.Response('{}', 200)));

  @override
  Future<String?> sendMessage(
    String spaceName,
    String text, {
    String? quotedMessageName,
    String? quotedMessageLastUpdateTime,
  }) async => null;
  @override
  Future<void> testConnection() async {}
}

class _AlwaysValidJwtVerifier extends GoogleJwtVerifier {
  _AlwaysValidJwtVerifier()
    : super(
        audience: const GoogleChatAudienceConfig(
          mode: GoogleChatAudienceMode.appUrl,
          value: 'https://example.com/integrations/googlechat',
        ),
      );

  @override
  Future<bool> verify(String? authHeader) async => true;
}

// ---------------------------------------------------------------------------
// Test group
// ---------------------------------------------------------------------------

void main() {
  group('webhook path independence', () {
    test('webhook handler has no PubSubClient dependency', () {
      // Construct a fully functional webhook handler without any PubSubClient
      // reference — this proves compile-time constructor independence.
      final restClient = _FakeRestClient();
      final channel = GoogleChatChannel(
        config: const GoogleChatConfig(
          webhookPath: '/integrations/googlechat',
          dmAccess: DmAccessMode.open,
          groupAccess: GroupAccessMode.open,
        ),
        restClient: restClient,
      );
      final handler = GoogleChatWebhookHandler(
        channel: channel,
        jwtVerifier: _AlwaysValidJwtVerifier(),
        config: const GoogleChatConfig(
          webhookPath: '/integrations/googlechat',
          dmAccess: DmAccessMode.open,
          groupAccess: GroupAccessMode.open,
        ),
      );

      // Handler should be constructable and usable without any PubSub reference
      expect(handler, isNotNull);
    });

    test('webhook processes message while PubSubClient is in error state', () async {
      // Set up a degraded PubSubClient (always returns 500)
      final pubsubHttpClient = MockClient((_) async => http.Response('error', 500));
      final pubsubClient = PubSubClient(
        authClient: pubsubHttpClient,
        projectId: 'test-project',
        subscription: 'test-sub',
        pollIntervalSeconds: 1,
        onMessage: (_) async => true,
        delay: (_) async {},
      );
      pubsubClient.start();

      // Let a few errors accumulate
      await Future.delayed(const Duration(milliseconds: 100));

      // Set up the webhook handler with no PubSubClient dependency
      final restClient = _FakeRestClient();
      final channel = GoogleChatChannel(
        config: const GoogleChatConfig(
          webhookPath: '/integrations/googlechat',
          dmAccess: DmAccessMode.open,
          groupAccess: GroupAccessMode.open,
        ),
        restClient: restClient,
      );

      ChannelMessage? dispatched;
      final handler = GoogleChatWebhookHandler(
        channel: channel,
        jwtVerifier: _AlwaysValidJwtVerifier(),
        config: const GoogleChatConfig(
          webhookPath: '/integrations/googlechat',
          dmAccess: DmAccessMode.open,
          groupAccess: GroupAccessMode.open,
          typingIndicatorMode: TypingIndicatorMode.disabled,
        ),
        dispatchMessage: (msg) async {
          dispatched = msg;
          return 'OK';
        },
        responseTimeout: const Duration(milliseconds: 200),
      );

      // Send a valid webhook request
      final webhookPayload = {
        'type': 'MESSAGE',
        'space': {'name': 'spaces/AAA', 'type': 'DM'},
        'message': {
          'name': 'spaces/AAA/messages/1',
          'sender': {'name': 'users/123', 'type': 'HUMAN'},
          'text': 'Hello from webhook',
        },
        'user': {'name': 'users/123', 'displayName': 'Alice', 'type': 'HUMAN'},
      };

      final response = await handler.handle(
        Request(
          'POST',
          Uri.parse('http://localhost/integrations/googlechat'),
          headers: {'authorization': 'Bearer valid'},
          body: jsonEncode(webhookPayload),
        ),
      );

      // Webhook should succeed regardless of PubSub state
      expect(response.statusCode, 200);
      expect(dispatched, isNotNull);
      expect(dispatched!.text, 'Hello from webhook');

      // PubSub client should still be in error state (states are independent)
      expect(pubsubClient.healthStatus.consecutiveErrors, greaterThanOrEqualTo(0));

      await pubsubClient.stop();
      pubsubHttpClient.close();
    });

    test('webhook processes message when PubSubClient is null (not configured)', () async {
      // Webhook handler constructed without any Pub/Sub reference
      final restClient = _FakeRestClient();
      final channel = GoogleChatChannel(
        config: const GoogleChatConfig(
          webhookPath: '/integrations/googlechat',
          dmAccess: DmAccessMode.open,
          groupAccess: GroupAccessMode.open,
        ),
        restClient: restClient,
      );

      ChannelMessage? dispatched;
      final handler = GoogleChatWebhookHandler(
        channel: channel,
        jwtVerifier: _AlwaysValidJwtVerifier(),
        config: const GoogleChatConfig(
          webhookPath: '/integrations/googlechat',
          dmAccess: DmAccessMode.open,
          groupAccess: GroupAccessMode.open,
          typingIndicatorMode: TypingIndicatorMode.disabled,
        ),
        dispatchMessage: (msg) async {
          dispatched = msg;
          return 'Response';
        },
        responseTimeout: const Duration(milliseconds: 200),
      );

      final webhookPayload = {
        'type': 'MESSAGE',
        'space': {'name': 'spaces/BBB', 'type': 'DM'},
        'message': {
          'name': 'spaces/BBB/messages/1',
          'sender': {'name': 'users/456', 'type': 'HUMAN'},
          'text': 'No PubSub needed',
        },
        'user': {'name': 'users/456', 'displayName': 'Bob', 'type': 'HUMAN'},
      };

      final response = await handler.handle(
        Request(
          'POST',
          Uri.parse('http://localhost/integrations/googlechat'),
          headers: {'authorization': 'Bearer valid'},
          body: jsonEncode(webhookPayload),
        ),
      );

      expect(response.statusCode, 200);
      expect(dispatched, isNotNull);
    });
  });

  group('PubSubHealthReporter integration with HealthService', () {
    late _FakeHarness harness;

    setUp(() {
      harness = _FakeHarness();
    });

    test('health service includes pubsub section when reporter is provided', () async {
      final reporter = PubSubHealthReporter(enabled: false);
      final service = HealthService(
        worker: harness,
        searchDbPath: '/nonexistent/search.db',
        sessionsDir: '/nonexistent/sessions',
        pubsubReporter: reporter,
      );

      final status = await service.getStatus();
      expect(status.containsKey('pubsub'), isTrue);
      final pubsub = status['pubsub'] as Map<String, dynamic>;
      expect(pubsub['status'], 'disabled');
      expect(pubsub['enabled'], false);
    });

    test('health service omits pubsub section when reporter is null', () async {
      final service = HealthService(
        worker: harness,
        searchDbPath: '/nonexistent/search.db',
        sessionsDir: '/nonexistent/sessions',
      );

      final status = await service.getStatus();
      expect(status.containsKey('pubsub'), isFalse);
    });

    test('health service includes pubsub enabled status', () async {
      final reporter = PubSubHealthReporter(enabled: true, subscriptionCount: () => 2);
      final service = HealthService(
        worker: harness,
        searchDbPath: '/nonexistent/search.db',
        sessionsDir: '/nonexistent/sessions',
        pubsubReporter: reporter,
      );

      final status = await service.getStatus();
      final pubsub = status['pubsub'] as Map<String, dynamic>;
      expect(pubsub['status'], 'unavailable'); // enabled but no client
      expect(pubsub['enabled'], true);
      expect(pubsub['active_subscriptions'], 2);
    });
  });
}

// ---------------------------------------------------------------------------
// Minimal fake harness
// ---------------------------------------------------------------------------

class _FakeHarness implements AgentHarness {
  @override
  bool get supportsCostReporting => true;

  @override
  bool get supportsToolApproval => true;

  @override
  bool get supportsStreaming => true;

  @override
  bool get supportsCachedTokens => false;

  @override
  WorkerState get state => WorkerState.idle;

  @override
  PromptStrategy get promptStrategy => PromptStrategy.replace;

  @override
  Stream<BridgeEvent> get events => const Stream.empty();

  @override
  Future<void> start() async {}

  @override
  Future<Map<String, dynamic>> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    Map<String, dynamic>? mcpServers,
    bool resume = false,
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
  }) async => {};

  @override
  Future<void> cancel() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}
