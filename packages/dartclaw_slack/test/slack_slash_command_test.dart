import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_slack/dartclaw_slack.dart';
import 'package:test/test.dart';

import 'support/slack_harness.dart';

const _responseUrl = 'https://hooks.slack.com/commands/T1/42/secret-path';

/// Stands in for the runtime's reserved-command handler: it answers the way the
/// real one does, with the message id and the thread on the reply.
class _Handler {
  final handled = <ChannelMessage>[];

  Future<String?> call(ChannelMessage message, Channel channel) async {
    final text = message.text.trim();
    if (!text.startsWith('/') && text != 'stop!') return null;
    handled.add(message);
    final threadId = message.threadId;
    await channel.sendMessage(
      resolveRecipientId(message),
      ChannelResponse(
        text: 'handled ${message.text}',
        metadata: {sourceMessageIdMetadataKey: message.id, 'threadId': ?threadId},
      ),
    );
    return 'executed';
  }
}

Map<String, dynamic> _slash(String command, {String text = '', String user = 'U1', String channel = 'C1'}) => {
  'command': command,
  'text': text,
  'user_id': user,
  'channel_id': channel,
  'response_url': _responseUrl,
  'trigger_id': 'trigger',
};

void main() {
  late SlackHarness harness;
  late _Handler handler;

  setUp(() async {
    handler = _Handler();
    harness = await SlackHarness.start(reservedCommands: handler.call);
  });

  tearDown(() => harness.close());

  Future<String> sendSlash(Map<String, dynamic> payload) async {
    final id = harness.server.sendSlashCommand(payload);
    await harness.deliver(const []);
    return id;
  }

  test('each reserved command reaches the handler as a message from that sender in that conversation', () async {
    for (final command in ['/stop', '/pause', '/resume']) {
      await sendSlash(_slash(command));
    }

    expect(handler.handled.map((m) => m.text), ['/stop', '/pause', '/resume']);
    for (final message in handler.handled) {
      expect(message.senderJid, 'U1');
      expect(message.groupJid, 'C1');
      expect(message.channelType, ChannelType.slack);
      expect(message.threadId, isNull, reason: 'a slash payload carries no thread');
      expect(message.metadata, isNot(contains('threadName')), reason: 'the Google Chat binding key is never stamped');
    }
  });

  test('the envelope is acknowledged at once with no body', () async {
    final id = await sendSlash(_slash('/stop'));

    expect(harness.server.acknowledgementFrames.first, {'envelope_id': id});
  });

  test('the handler reply is the ephemeral response through response_url, not a channel post', () async {
    await sendSlash(_slash('/pause'));

    expect(harness.api.ephemerals.single.url, Uri.parse(_responseUrl));
    expect(harness.api.ephemerals.single.text, 'handled /pause');
    expect(harness.api.posts, isEmpty);
  });

  test('a refusal from the handler is delivered the same way', () async {
    final refusing = await SlackHarness.start(
      reservedCommands: (message, channel) async {
        await channel.sendMessage(
          resolveRecipientId(message),
          ChannelResponse(
            text: 'Only admin senders can use this command.',
            metadata: {sourceMessageIdMetadataKey: message.id},
          ),
        );
        return 'rejected';
      },
    );
    addTearDown(refusing.close);
    refusing.server.sendSlashCommand(_slash('/stop', user: 'U2'));
    await refusing.deliver(const []);

    expect(refusing.api.ephemerals.single.text, 'Only admin senders can use this command.');
    expect(refusing.api.posts, isEmpty);
  });

  test('a channel outside the allowlist is acknowledged but its command is not executed', () async {
    final id = await sendSlash(_slash('/stop', channel: 'C9'));

    expect(harness.server.acknowledgements, contains(id));
    expect(handler.handled, isEmpty);
    expect(harness.api.ephemerals, isEmpty);
  });

  test('a DM sender that dm_access refuses is acknowledged but not executed', () async {
    final id = await sendSlash(_slash('/stop', user: 'U9', channel: 'D9'));

    expect(harness.server.acknowledgements, contains(id));
    expect(handler.handled, isEmpty);
  });

  test('an allowlisted channel needs no mention for a slash command', () async {
    await sendSlash(_slash('/stop'));

    expect(handler.handled, hasLength(1));
  });

  test('a slash command in a DM from an allowed sender is executed with no group', () async {
    await sendSlash(_slash('/stop', channel: 'D1'));

    expect(handler.handled.single.groupJid, isNull);
  });

  test('stop! typed in a thread reaches the handler and its reply lands in that thread', () async {
    await harness.deliver([
      message(channel: 'C1', user: 'U1', text: 'start', ts: '10.1', mention: true),
      message(channel: 'C1', user: 'U1', text: 'stop!', ts: '10.2', threadTs: '10.1'),
    ]);

    expect(handler.handled.map((m) => m.text), ['stop!']);
    final reply = harness.api.posts.single;
    expect((reply.channel, reply.text, reply.threadTs), ('C1', 'handled stop!', '10.1'));
    expect(harness.api.ephemerals, isEmpty);
  });

  test('stop! typed in a DM is answered inside that DM thread', () async {
    await harness.deliver([message(channel: 'D1', user: 'U1', text: 'stop!', ts: '20.1')]);

    final reply = harness.api.posts.single;
    expect((reply.channel, reply.threadTs), ('D1', '20.1'));
  });

  test('a failed ephemeral answer is logged and dropped without failing the command', () async {
    harness.api.ephemeralError = const SlackApiException('response URL expired');

    await sendSlash(_slash('/stop'));

    expect(handler.handled, hasLength(1));
    expect(harness.api.ephemerals, isEmpty);
  });
}
