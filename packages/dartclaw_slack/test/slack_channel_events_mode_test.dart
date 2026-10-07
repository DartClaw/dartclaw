import 'dart:convert';
import 'dart:typed_data';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_slack/dartclaw_slack.dart';
import 'package:dartclaw_slack/testing.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show RecordingMessageQueue;
import 'package:test/test.dart';

import 'support/slack_harness.dart';

SlackChannel _channel(FakeSlackWebApi api, {String mode = 'events', String? signingSecret = 'secret'}) =>
    bareSlackChannel(api, mode: mode, signingSecret: signingSecret);

void main() {
  late FakeSocketModeServer server;
  late FakeSlackWebApi api;

  setUp(() async {
    server = FakeSocketModeServer();
    await server.start();
    addTearDown(server.stop);
    api = FakeSlackWebApi(socketUrl: server.url);
  });

  test('events mode verifies the bot token at connect and opens no socket', () async {
    final channel = _channel(api);
    addTearDown(channel.disconnect);

    await channel.connect();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(api.authTestCalls, 1);
    expect(channel.mentionGating.ownJid, 'UBOT');
    expect(server.attemptCount, 0);
    expect(channel.connectionState, SocketModeState.disconnected);
    expect(channel.eventsHandler, isNotNull);
  });

  test('events mode fails loudly on a rejected token', () async {
    api.authError = const SlackApiException('Slack API auth.test failed: token_revoked', errorCode: 'token_revoked');
    final channel = _channel(api);

    await expectLater(channel.connect, throwsA(isA<SlackApiException>()));
    expect(server.attemptCount, 0);
  });

  test(
    'a signed DM before the bot token is verified is answered 503 and starts no turn, until connect succeeds',
    () async {
      api.authError = const SlackApiException('Slack API auth.test failed: token_revoked', errorCode: 'token_revoked');
      final queue = RecordingMessageQueue(debounceWindow: Duration.zero);
      addTearDown(queue.dispose);
      final manager = ChannelManager(queue: queue, config: const ChannelConfig.defaults());
      final channel = SlackChannel(
        config: const SlackConfig(enabled: true),
        api: api,
        dmAccess: DmAccessController(mode: DmAccessMode.open),
        mentionGating: MentionGating(requireMention: true, mentionPatterns: const [], ownJid: ''),
        channelManager: manager,
        mode: 'events',
        signingSecret: 'secret',
      );
      addTearDown(channel.disconnect);
      manager.registerChannel(channel);
      final handler = channel.eventsHandler!;

      Future<SlackEventsResponse> post(String text, String ts) {
        final body = utf8.encode(jsonEncode(eventCallback(message(channel: 'D1', user: 'U1', text: text, ts: ts))));
        return handler.handle(Uint8List.fromList(body), signedSlackHeaders('secret', body));
      }

      await expectLater(channel.connect, throwsA(isA<SlackApiException>()));
      final refused = await post('before auth', '1700000000.000100');
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(refused.statusCode, 503, reason: 'a non-2xx answer is what makes Slack redeliver the event');
      expect(queue.enqueued, isEmpty, reason: 'a turn whose reply cannot post must not run');

      api.authError = null;
      await channel.connect();
      final accepted = await post('after auth', '1700000001.000100');
      for (var i = 0; i < 100 && queue.enqueued.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(accepted.statusCode, 200);
      expect([for (final turn in queue.enqueued) turn.message.text], ['after auth']);
    },
  );

  test('socket mode exposes no events handler, so the runtime mounts no route', () {
    expect(_channel(api, mode: 'socket', signingSecret: null).eventsHandler, isNull);
  });

  test('a signed request through the events handler reaches the same dispatch a socket envelope does', () async {
    final harness = await SlackHarness.start(mode: 'events');
    addTearDown(harness.close);

    final event = message(channel: 'D1', user: 'U1', text: 'hi', ts: '1700000000.000100');

    final response = await harness.post(utf8.encode(jsonEncode(eventCallback(event))));
    await harness.until(() => harness.turns.length == 1);

    expect(response.statusCode, 200);
    expect(harness.turns.single.message.text, 'hi');
    expect(harness.server.attemptCount, 0);
  });

  test('events mode without a signing secret and an unknown mode are refused at construction', () {
    expect(() => _channel(api, signingSecret: null), throwsArgumentError);
    expect(() => _channel(api, signingSecret: ''), throwsArgumentError);
    expect(() => _channel(api, mode: 'webhook'), throwsArgumentError);
  });

  test('disconnect works in events mode and closes the API client', () async {
    final channel = _channel(api);
    await channel.connect();

    await channel.disconnect();

    expect(api.closed, isTrue);
  });
}
