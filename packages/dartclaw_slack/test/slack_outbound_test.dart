import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_slack/dartclaw_slack.dart';
import 'package:dartclaw_slack/testing.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'support/slack_harness.dart';

String _only(List<ChannelResponse> chunks) => chunks.single.text;

void main() {
  late FakeSlackWebApi api;
  late SlackChannel channel;

  setUp(() {
    api = FakeSlackWebApi();
    channel = bareSlackChannel(api);
  });

  group('formatting', () {
    test('Markdown becomes mrkdwn with <url|label> links', () {
      final text = _only(channel.formatResponse('**bold** and _soft_ and ~~gone~~ see [the docs](https://x.dev/a)'));

      expect(text, '*bold* and _soft_ and ~gone~ see <https://x.dev/a|the docs>');
    });

    test('a literal <!channel>, <@U123> and & cannot ping, link or open an entity', () {
      final text = _only(channel.formatResponse('ping <!channel> and <@U123> and R&D, a < b > c'));

      expect(text, 'ping &lt;!channel&gt; and &lt;@U123&gt; and R&amp;D, a &lt; b &gt; c');
      expect(text, isNot(contains('<')));
    });

    test('an ampersand inside a link URL is escaped for Slack and the link survives', () {
      final text = _only(channel.formatResponse('[q](https://x.dev/s?a=1&b=2)'));

      expect(text, '<https://x.dev/s?a=1&amp;b=2|q>');
    });

    test('code keeps its content, with <, > and & escaped like any other text', () {
      final text = _only(channel.formatResponse('run `a && b` then\n```\nif (a < b) {}\n```'));

      expect(text, contains('`a &amp;&amp; b`'));
      expect(text, contains('if (a &lt; b) {}'));
    });

    test('an answer over 4,000 characters is chunked with (n/total) indicators, none over 4,000', () {
      final paragraph = '${List.filled(40, 'lorem ipsum').join(' ')} see [source](https://x.dev/page?id=1&n=2)\n\n';
      final chunks = channel.formatResponse(paragraph * 30);

      expect(chunks.length, greaterThan(1));
      for (final (index, chunk) in chunks.indexed) {
        expect(chunk.text.length, lessThanOrEqualTo(4000), reason: 'chunk $index');
        expect(chunk.text, startsWith('(${index + 1}/${chunks.length}) '));
      }
    });

    test('no link is split across chunks', () {
      final paragraph = '${List.filled(30, 'word').join(' ')} [label](https://x.dev/${'p' * 60})\n\n';
      final chunks = channel.formatResponse(paragraph * 40);

      expect(chunks.length, greaterThan(1));
      final all = chunks.map((chunk) => chunk.text).join('\n');
      expect(RegExp('<https://x.dev/p{60}\\|label>').allMatches(all), hasLength(40));
      for (final chunk in chunks) {
        expect('<'.allMatches(chunk.text).length, '>'.allMatches(chunk.text).length);
      }
    });

    test('leading whitespace is trimmed and an empty answer yields nothing to send', () {
      expect(_only(channel.formatResponse('\n\n  hello')), 'hello');
    });
  });

  group('sending', () {
    test('a reply is posted into the thread its metadata names', () async {
      await channel.sendMessage('C1', const ChannelResponse(text: 'hi', metadata: {threadIdMetadataKey: '1.5'}));

      expect(api.posts.single, (channel: 'C1', text: 'hi', threadTs: '1.5', blocks: null));
    });

    test('a reply without a thread is posted to the conversation', () async {
      await channel.sendMessage('C1', const ChannelResponse(text: 'hi'));

      expect(api.posts.single.threadTs, isNull);
    });

    test('an empty reply posts nothing', () async {
      await channel.sendMessage('C1', const ChannelResponse(text: ''));

      expect(api.posts, isEmpty);
    });

    for (final code in ['channel_not_found', 'thread_not_found', 'ratelimited']) {
      test('$code is logged as a warning and the chunk is dropped without failing the caller', () async {
        final records = <LogRecord>[];
        final subscription = Logger.root.onRecord.listen(records.add);
        addTearDown(subscription.cancel);
        api.onPost = (channel, threadTs) =>
            SlackApiException('Slack API chat.postMessage failed: $code', errorCode: code);

        await channel.sendMessage('C1', const ChannelResponse(text: 'lost', metadata: {threadIdMetadataKey: '1.5'}));

        expect(records.where((r) => r.level == Level.WARNING).single.message, contains(code));
      });
    }

    test('after a failed chunk the later chunks are still tried', () async {
      var failNext = true;
      api.onPost = (channel, threadTs) {
        if (!failNext) return null;
        failNext = false;
        return const SlackApiException('channel_not_found', errorCode: 'channel_not_found');
      };
      final chunks = channel.formatResponse(('word ' * 150 + '\n\n') * 12);
      expect(chunks.length, greaterThan(1));

      for (final chunk in chunks) {
        await channel.sendMessage(
          'C1',
          ChannelResponse(text: chunk.text, metadata: const {threadIdMetadataKey: '1.5'}),
        );
      }

      expect(api.posts.map((post) => post.text), chunks.skip(1).map((chunk) => chunk.text));
    });

    test('the session keeps its reply when the post fails: the queue sees a normal delivery', () async {
      api.onPost = (channel, threadTs) => const SlackApiException('channel_not_found', errorCode: 'channel_not_found');
      final delivered = <String>[];
      final queue = MessageQueue(
        debounceWindow: Duration.zero,
        defaultRetryPolicy: const RetryPolicy(maxAttempts: 3, baseDelay: Duration.zero),
        dispatcher:
            (
              sessionKey,
              message, {
              required ChannelType channelType,
              String? senderJid,
              String? senderDisplayName,
              String? groupJid,
              String? recipientId,
              String? threadId,
              List<ChannelAttachment> attachments = const [],
            }) async {
              delivered.add(message);
              return 'the answer';
            },
      );
      addTearDown(queue.dispose);

      queue.enqueue(
        ChannelMessage(
          channelType: ChannelType.slack,
          senderJid: 'U1',
          groupJid: 'C1',
          text: 'question',
          metadata: const {'spaceName': 'C1', threadIdMetadataKey: '1.5'},
        ),
        channel,
        'session',
      );
      await pumpEventQueue(times: 200);

      expect(delivered, ['question'], reason: 'the turn ran once and was not retried because the post failed');
    });
  });

  test('a thread the bot posted in is remembered, so a later unmentioned reply needs no Slack lookup', () async {
    final harness = await SlackHarness.start();
    addTearDown(harness.close);

    await harness.channel.sendMessage('C1', const ChannelResponse(text: 'hi', metadata: {threadIdMetadataKey: '5.1'}));
    await harness.deliver([message(channel: 'C1', user: 'U2', text: 'thanks', ts: '5.2', threadTs: '5.1')]);

    expect(harness.turns.single.message.text, 'thanks');
    expect(harness.api.repliesCalls, isEmpty);
  });
}
