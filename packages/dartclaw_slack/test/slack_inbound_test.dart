import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_slack/dartclaw_slack.dart';
import 'package:dartclaw_slack/testing.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'support/slack_harness.dart';

void main() {
  late SlackHarness harness;

  Future<SlackHarness> start({
    SlackConfig? config,
    SessionScopeConfig scopes = const SessionScopeConfig.defaults(),
    List<GroupEntry> groupRows = const [],
    String Function(String)? answer,
  }) async => harness = await SlackHarness.start(config: config, scopes: scopes, groupRows: groupRows, answer: answer);

  tearDown(() => harness.close());

  group('direct messages', () {
    test('a top-level DM opens a thread session, and the reply lands in that thread', () async {
      await start(answer: (text) => 'answer to $text');

      await harness.deliver([message(channel: 'D1', user: 'U1', text: 'hello', ts: '100.000100')]);
      await harness.until(() => harness.api.posts.any((post) => post.channel == 'D1'));

      final turn = harness.turns.single;
      expect(turn.sessionKey, endsWith(':thread:100.000100'));
      expect(turn.message.threadId, '100.000100');
      final reply = harness.api.posts.singleWhere((post) => post.channel == 'D1');
      expect((reply.text, reply.threadTs), ('answer to hello', '100.000100'));
    });

    test('a reply inside the thread continues the session, and a new top-level DM opens another', () async {
      await start();

      await harness.deliver([
        message(channel: 'D1', user: 'U1', text: 'first', ts: '100.000100'),
        message(channel: 'D1', user: 'U1', text: 'follow-up', ts: '100.000200', threadTs: '100.000100'),
        message(channel: 'D1', user: 'U1', text: 'second topic', ts: '101.000100'),
      ]);

      final keys = harness.turns.map((turn) => turn.sessionKey).toList();
      expect(keys[0], keys[1]);
      expect(keys[2], isNot(keys[0]));
    });

    test('a DM needs no mention', () async {
      await start();

      await harness.deliver([message(channel: 'D1', user: 'U1', text: 'plain', ts: '100.1')]);

      expect(harness.turns, hasLength(1));
    });
  });

  group('DM access modes', () {
    SlackConfig configFor(DmAccessMode mode) => SlackConfig(
      enabled: true,
      dmAccess: mode,
      dmAllowlist: const [
        GroupEntry(id: 'U1'),
        GroupEntry(id: 'UZ'),
      ],
      groupAccess: GroupAccessMode.allowlist,
      groupAllowlist: const [GroupEntry(id: 'C1')],
    );

    final stranger = message(channel: 'D9', user: 'U9', text: 'let me in', ts: '100.1');
    final member = message(channel: 'D1', user: 'U1', text: 'it is me', ts: '101.1');

    test('pairing answers an unknown sender with a code and admits the allowlisted one', () async {
      await start(config: configFor(DmAccessMode.pairing));

      await harness.deliver([stranger, member]);

      expect(harness.dmAccess.pendingCount, 1);
      final pairing = harness.api.posts.singleWhere((post) => post.channel == 'D9');
      expect(pairing.text, contains(harness.dmAccess.pendingPairings.single.code));
      expect(pairing.threadTs, isNull);
      expect(harness.turns.map((turn) => turn.message.senderJid), ['U1']);
    });

    test('allowlist drops an unknown sender silently', () async {
      await start(config: configFor(DmAccessMode.allowlist));

      await harness.deliver([stranger, member]);

      expect(harness.api.posts, isEmpty);
      expect(harness.turns.map((turn) => turn.message.senderJid), ['U1']);
    });

    test('disabled drops every DM silently', () async {
      await start(config: configFor(DmAccessMode.disabled));

      await harness.deliver([stranger, member]);

      expect(harness.api.posts, isEmpty);
      expect(harness.turns, isEmpty);
    });

    test('open admits an unknown sender', () async {
      await start(config: configFor(DmAccessMode.open));

      await harness.deliver([stranger, member]);

      expect(harness.turns.map((turn) => turn.message.senderJid), ['U9', 'U1']);
    });
  });

  group('channels', () {
    test('a mention opens a thread; a reply without a mention continues it', () async {
      await start();

      await harness.deliver([
        message(channel: 'C1', user: 'U1', text: 'help me', ts: '200.000100', mention: true),
        message(channel: 'C1', user: 'U2', text: 'me too', ts: '200.000200', threadTs: '200.000100'),
      ]);

      final turns = harness.turns;
      expect(turns, hasLength(2));
      expect(turns[0].message.groupJid, 'C1');
      expect(turns[0].sessionKey, contains(':thread:200.000100'));
      expect(turns[1].sessionKey, turns[0].sessionKey, reason: 'group_scope shared: one session per thread');
      expect(harness.api.repliesCalls, isEmpty, reason: 'the bot started the thread, so Slack is not asked');
    });

    test('under per_member scope each member has one session per thread', () async {
      await start(
        scopes: const SessionScopeConfig(dmScope: DmScope.perContact, groupScope: GroupScope.perMember),
      );

      await harness.deliver([
        message(channel: 'C1', user: 'U1', text: 'one', ts: '200.1', mention: true),
        message(channel: 'C1', user: 'U2', text: 'two', ts: '200.2', threadTs: '200.1'),
        message(channel: 'C1', user: 'U1', text: 'three', ts: '200.3', threadTs: '200.1'),
        message(channel: 'C1', user: 'U1', text: 'other thread', ts: '201.1', mention: true),
      ]);

      final keys = harness.turns.map((turn) => turn.sessionKey).toList();
      expect(keys[0], keys[2]);
      expect(keys[1], isNot(keys[0]));
      expect(keys[3], isNot(keys[0]));
      expect({...keys}, hasLength(3));
    });

    test('the mention text reaches the turn without the bot token', () async {
      await start();

      await harness.deliver([message(channel: 'C1', user: 'U1', text: 'help me', ts: '200.1', mention: true)]);

      expect(harness.turns.single.message.text, 'help me');
      expect(harness.turns.single.message.mentionedJids, [botUserId]);
    });

    test('a bot token in text without blocks counts as the mention', () async {
      await start();
      final event = message(channel: 'C1', user: 'U1', text: 'help', ts: '200.1', mention: true)..remove('blocks');

      await harness.deliver([event]);

      expect(harness.turns.single.message.text, 'help');
    });

    test('mention_patterns also count as naming the bot', () async {
      await start(
        config: const SlackConfig(
          enabled: true,
          groupAccess: GroupAccessMode.allowlist,
          groupAllowlist: [GroupEntry(id: 'C1')],
          dmAccess: DmAccessMode.allowlist,
          dmAllowlist: [
            GroupEntry(id: 'U1'),
            GroupEntry(id: 'UZ'),
          ],
          mentionPatterns: [r'\bdartclaw\b'],
        ),
      );

      await harness.deliver([message(channel: 'C1', user: 'U1', text: 'hey dartclaw, status?', ts: '200.1')]);

      expect(harness.turns, hasLength(1));
    });

    test('with require_mention off a top-level message starts a thread', () async {
      await start(
        config: const SlackConfig(
          enabled: true,
          groupAccess: GroupAccessMode.allowlist,
          groupAllowlist: [GroupEntry(id: 'C1')],
          dmAccess: DmAccessMode.allowlist,
          dmAllowlist: [GroupEntry(id: 'UZ')],
          requireMention: false,
        ),
      );

      await harness.deliver([message(channel: 'C1', user: 'U1', text: 'unprompted', ts: '200.1')]);

      expect(harness.turns.single.sessionKey, endsWith(':thread:200.1'));
    });
  });

  group('unrelated traffic', () {
    test(
      'no mention, an unjoined thread, an unlisted channel and disabled groups start no turn and post nothing',
      () async {
        await start();

        await harness.deliver([
          message(channel: 'C1', user: 'U1', text: 'chatter', ts: '300.1'),
          message(channel: 'C1', user: 'U2', text: 'reply in a human thread', ts: '300.3', threadTs: '300.2'),
          message(channel: 'C9', user: 'U1', text: 'not allowlisted', ts: '300.4', mention: true),
        ]);
        expect(harness.turns, isEmpty);
        expect(harness.api.posts, isEmpty);

        await harness.close();
        await start(
          config: const SlackConfig(
            enabled: true,
            dmAccess: DmAccessMode.allowlist,
            dmAllowlist: [GroupEntry(id: 'UZ')],
          ),
        );
        await harness.deliver([message(channel: 'C1', user: 'U1', text: 'groups are off', ts: '301.1', mention: true)]);
        expect(harness.turns, isEmpty);
        expect(harness.api.posts, isEmpty);
      },
    );

    test('traffic that is dropped costs no Slack API call, neither a thread lookup nor a name lookup', () async {
      await start();

      await harness.deliver([
        message(channel: 'C9', user: 'U1', text: 'reply', ts: '300.4', threadTs: '300.1'),
        message(channel: 'C1', user: 'U1', text: 'no mention', ts: '300.5'),
        message(channel: 'D9', user: 'U9', text: 'stranger', ts: '300.6'),
      ]);

      expect(harness.api.repliesCalls, isEmpty);
      expect(harness.api.displayNameCalls, isEmpty);
    });
  });

  group('thread participation', () {
    test('after a restart the bot confirms its part in a thread once, however many replies follow', () async {
      await start();
      harness.api.threads['C1:400.1'] = [
        {'user': 'U1', 'ts': '400.1', 'text': 'question'},
        {'user': botUserId, 'bot_id': 'BBOT', 'ts': '400.2', 'text': 'answer'},
      ];

      await harness.deliver([
        message(channel: 'C1', user: 'U2', text: 'one', ts: '400.3', threadTs: '400.1'),
        message(channel: 'C1', user: 'U2', text: 'two', ts: '400.4', threadTs: '400.1'),
        message(channel: 'C1', user: 'U1', text: 'three', ts: '400.5', threadTs: '400.1'),
      ]);

      expect(harness.turns, hasLength(3));
      expect(harness.turns.map((turn) => turn.sessionKey).toSet(), hasLength(1));
      expect(harness.api.repliesCalls, ['C1:400.1']);
    });

    test('a thread the bot is not in is also asked about only once', () async {
      await start();
      harness.api.threads['C1:500.1'] = [
        {'user': 'U1', 'ts': '500.1', 'text': 'human thread'},
      ];

      await harness.deliver([
        message(channel: 'C1', user: 'U2', text: 'one', ts: '500.2', threadTs: '500.1'),
        message(channel: 'C1', user: 'U2', text: 'two', ts: '500.3', threadTs: '500.1'),
      ]);

      expect(harness.turns, isEmpty);
      expect(harness.api.repliesCalls, ['C1:500.1']);
    });

    test('a mention later in a thread the bot was ruled out of admits it from then on', () async {
      await start();

      await harness.deliver([
        message(channel: 'C1', user: 'U2', text: 'no mention', ts: '500.2', threadTs: '500.1'),
        message(channel: 'C1', user: 'U1', text: 'now with a mention', ts: '500.3', threadTs: '500.1', mention: true),
        message(channel: 'C1', user: 'U2', text: 'no mention again', ts: '500.4', threadTs: '500.1'),
      ]);

      expect(harness.turns.map((turn) => turn.message.text), ['now with a mention', 'no mention again']);
    });

    test('a failed participation check ignores the reply instead of guessing', () async {
      await start();
      harness.api.repliesError = const SlackApiException('missing_scope', errorCode: 'missing_scope');

      await harness.deliver([message(channel: 'C1', user: 'U2', text: 'reply', ts: '400.3', threadTs: '400.1')]);

      expect(harness.turns, isEmpty);
    });

    test('a mention inside a human thread keys the session by that thread and imports no history', () async {
      await start();

      await harness.deliver([
        message(channel: 'C1', user: 'U1', text: 'can you weigh in?', ts: '600.5', threadTs: '600.1', mention: true),
      ]);

      final turn = harness.turns.single;
      expect(turn.sessionKey, endsWith(':thread:600.1'));
      expect(turn.message.text, 'can you weigh in?');
      expect(harness.api.repliesCalls, isEmpty);
    });
  });

  group('one turn per message', () {
    final mentioned = message(channel: 'C1', user: 'U1', text: 'from the message event', ts: '700.1', mention: true);
    final appMention = {
      'type': 'app_mention',
      'channel': 'C1',
      'user': 'U1',
      'text': '<@$botUserId> from the app_mention event',
      'ts': '700.1',
    };

    test('an app_mention and a message with the same timestamp start exactly one turn, from the message', () async {
      await start();

      await harness.deliver([appMention, mentioned]);
      expect(harness.turns.map((turn) => turn.message.text), ['from the message event']);
    });

    test('the order of arrival does not matter', () async {
      await start();

      await harness.deliver([mentioned, appMention]);

      expect(harness.turns.map((turn) => turn.message.text), ['from the message event']);
    });
  });

  group('non-conversational events', () {
    test(
      'own, bot, edited, deleted, join and unknown events start no turn, and every envelope is acknowledged',
      () async {
        await start();
        final sent = [
          message(channel: 'C1', user: botUserId, text: 'my own message', ts: '800.1', mention: true),
          message(channel: 'C1', user: 'U1', text: 'integration', ts: '800.2', mention: true, botId: 'BOTHER'),
          {
            'type': 'message',
            'subtype': 'message_changed',
            'channel': 'C1',
            'ts': '800.3',
            'message': {'user': 'U1', 'text': 'edited <@$botUserId>', 'ts': '800.1'},
          },
          {'type': 'message', 'subtype': 'message_deleted', 'channel': 'C1', 'ts': '800.4', 'deleted_ts': '800.1'},
          {
            'type': 'message',
            'subtype': 'channel_join',
            'channel': 'C1',
            'user': 'U1',
            'text': 'joined',
            'ts': '800.5',
          },
          {'type': 'reaction_added', 'user': 'U1', 'reaction': 'eyes', 'event_ts': '800.6'},
        ];

        await harness.deliver(sent);
        await harness.server.waitForAcknowledgements(sent.length + 1);

        expect(harness.turns, isEmpty);
        expect(harness.api.posts, isEmpty);
        expect(
          harness.logs.any(
            (r) => r.level == Level.FINE && r.message.contains('unknown Slack event type "reaction_added"'),
          ),
          isTrue,
        );
      },
    );

    test('a file_share message takes the file in with its text', () async {
      await start();
      const url = 'https://files.slack.com/files-pri/T1-F1/a.png';
      harness.api.fileHost.files[url] = FakeSlackFile(bytes: [1, 2, 3], contentType: 'image/png');

      await harness.deliver([
        message(
          channel: 'D1',
          user: 'U1',
          text: 'see attached',
          ts: '810.1',
          subtype: 'file_share',
          files: [
            {'id': 'F1', 'name': 'a.png', 'mimetype': 'image/png', 'size': 3, 'url_private_download': url},
          ],
        ),
      ]);
      await harness.until(() => harness.turns.isNotEmpty);

      final turn = harness.turns.single.message;
      expect(turn.text, 'see attached');
      expect(turn.attachments.single.filename, 'a.png');
      expect(turn.attachments.single.bytes, [1, 2, 3]);
    });
  });

  group('what the turn sees', () {
    test('entities are decoded and the sender is named from users.info', () async {
      await start();
      harness.api.displayNames['U1'] = 'Alice Example';

      await harness.deliver([
        message(channel: 'C1', user: 'U1', text: 'R&amp;D &lt;3 &gt; QA', ts: '900.1', mention: true),
      ]);

      final message_ = harness.turns.single.message;
      expect(message_.text, 'R&D <3 > QA');
      expect(message_.senderDisplayName, 'Alice Example');
    });

    test('a failed name lookup falls back to the user ID', () async {
      await start();

      await harness.deliver([message(channel: 'D1', user: 'U1', text: 'hi', ts: '900.1')]);

      expect(harness.turns.single.message.senderDisplayName, 'U1');
    });

    test('the message carries what routing needs: sender, conversation, timestamp', () async {
      await start();

      await harness.deliver([message(channel: 'D1', user: 'U1', text: 'hi', ts: '1700000000.000100')]);

      final message_ = harness.turns.single.message;
      expect(message_.channelType, ChannelType.slack);
      expect(message_.senderJid, 'U1');
      expect(message_.groupJid, isNull);
      expect(message_.metadata['spaceName'], 'D1');
      expect(message_.timestamp, DateTime.fromMillisecondsSinceEpoch(1700000000000));
    });
  });

  group('allowlist rows', () {
    test('a row with an agent keys the session by that agent and an unbound row stays on main', () async {
      await start(
        groupRows: const [GroupEntry(id: 'C2', agent: 'eng-bot')],
        config: const SlackConfig(
          enabled: true,
          dmAccess: DmAccessMode.allowlist,
          dmAllowlist: [GroupEntry(id: 'UZ')],
          groupAccess: GroupAccessMode.allowlist,
          groupAllowlist: [
            GroupEntry(id: 'C1'),
            GroupEntry(id: 'C2', agent: 'eng-bot'),
          ],
        ),
      );

      await harness.deliver([
        message(channel: 'C2', user: 'U1', text: 'bound', ts: '1.1', mention: true),
        message(channel: 'C1', user: 'U1', text: 'unbound', ts: '2.1', mention: true),
      ]);

      expect(harness.turns[0].sessionKey, startsWith('agent:eng-bot:'));
      expect(harness.turns[1].sessionKey, startsWith('agent:main:'));
    });
  });

  group('ownership', () {
    test('the channel claims Slack user, channel and DM IDs and nothing else', () async {
      await start();

      for (final jid in ['U123ABC', 'W123ABC', 'C123ABC', 'G123ABC', 'D123ABC']) {
        expect(harness.channel.ownsJid(jid), isTrue, reason: jid);
      }
      for (final jid in ['spaces/AAAA', 'users/123', '+46701234567', '123@s.whatsapp.net', 'u123', 'U', '']) {
        expect(harness.channel.ownsJid(jid), isFalse, reason: jid);
      }
    });

    test('connect verifies the token, learns the bot user and exposes the connection', () async {
      await start();

      expect(harness.api.authTestCalls, 1);
      expect(harness.channel.mentionGating.ownJid, botUserId);
      expect(harness.channel.connectionState, SocketModeState.connected);
      expect(harness.channel.lastConnectedAt, isNotNull);
    });

    test('a socket that cannot be opened never fails connect, and the connection comes up once it can', () async {
      final server = FakeSocketModeServer();
      await server.start();
      addTearDown(server.stop);
      final api = FakeSlackWebApi(socketUrl: server.url)
        ..socketUrlError = const SlackApiException('Slack API apps.connections.open failed: ratelimited');
      final channel = bareSlackChannel(
        api,
        reconnectDelay: (_) => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      addTearDown(channel.disconnect);

      await channel.connect();
      expect(channel.connectionState, isNot(SocketModeState.connected));

      api.socketUrlError = null;
      await server.waitForConnections(1);
      expect(api.authTestCalls, 1);
    });

    test('connect fails loudly on a rejected token and never opens the socket', () async {
      final server = FakeSocketModeServer();
      await server.start();
      addTearDown(server.stop);
      final api = FakeSlackWebApi(socketUrl: server.url)..authError = const SlackApiException('invalid_auth');
      final channel = bareSlackChannel(api);

      await expectLater(channel.connect(), throwsA(isA<SlackApiException>()));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(server.attemptCount, 0);
    });
  });
}
