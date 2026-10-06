import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_slack/dartclaw_slack.dart';
import 'package:dartclaw_slack/testing.dart';
import 'package:test/test.dart';

import 'support/slack_harness.dart';

SlackChannel _channel(FakeSlackWebApi api, {String mode = 'events', String? signingSecret = 'secret'}) => SlackChannel(
  config: const SlackConfig(enabled: true),
  api: api,
  dmAccess: DmAccessController(mode: DmAccessMode.open),
  mentionGating: MentionGating(requireMention: true, mentionPatterns: const [], ownJid: ''),
  channelManager: ChannelManager(
    queue: MessageQueue(dispatcher: _noDispatch),
    config: const ChannelConfig.defaults(),
  ),
  mode: mode,
  signingSecret: signingSecret,
);

Future<String> _noDispatch(
  String sessionKey,
  String message, {
  required ChannelType channelType,
  String? senderJid,
  String? senderDisplayName,
  String? groupJid,
  String? recipientId,
  String? threadId,
}) async => 'ok';

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
