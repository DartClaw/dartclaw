import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' show FeedbackContext, TurnProgressSnapshot;
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show MessageRedactor;
import 'package:dartclaw_slack/dartclaw_slack.dart';
import 'package:dartclaw_slack/testing.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeChannel;
import 'package:logging/logging.dart';
import 'package:test/test.dart';

const _snapshot = TurnProgressSnapshot(elapsed: Duration.zero, toolCallCount: 0);
const _token = 'xoxb-1111111111-2222222222-AbCdEfGhIjKlMnOpQrStUvWx';

/// One turn's strategy over a fake Web API, with a clock that only moves when the strategy sleeps.
class _Turn {
  new({
    bool streaming = true,
    String? threadTs = '100.1',
    String channel = 'C1',
    bool inChannel = true,
    MessageRedactor? redactor,
  }) {
    strategy = SlackFeedbackStrategy(
      api: api,
      channel: channel,
      threadTs: threadTs,
      streaming: streaming,
      recipientTeamId: inChannel ? 'T1' : null,
      recipientUserId: inChannel ? 'U1' : null,
      redact: redactor?.redact,
      now: () => clock,
      delay: (duration) async {
        sleeps.add(duration);
        clock = clock.add(duration);
      },
    );
  }

  final api = FakeSlackWebApi();
  final sleeps = <Duration>[];
  var clock = DateTime.utc(2026, 1, 1);
  late final SlackFeedbackStrategy strategy;
  final context = FeedbackContext(channel: FakeChannel(), recipientJid: 'C1');

  Future<void> start() => strategy.onTurnStarted(context: context);

  Future<void> delta(String text) => strategy.onTextDelta(context: context, snapshot: _snapshot, text: text);

  Future<bool> complete(String reply) => strategy.onTurnCompleted(context: context, responseText: reply);

  /// Everything Slack was sent as text, so a test can assert on what never left.
  String get everythingSent => [
    for (final start in api.startedStreams) start.markdownText ?? '',
    for (final append in api.appends) append.markdownText,
    for (final stop in api.stops) stop.markdownText ?? '',
    for (final update in api.updates) update.text,
    for (final post in api.posts) post.text,
  ].join('\n');
}

void main() {
  final logs = <LogRecord>[];
  late StreamSubscription<LogRecord> subscription;

  setUp(() {
    logs.clear();
    Logger.root.level = Level.ALL;
    subscription = Logger.root.onRecord.listen(logs.add);
  });

  tearDown(() => subscription.cancel());

  group('a reply streams into its thread (OC01)', () {
    test(
      'one stream is started in the thread with the recipient, appended to, stopped, and nothing is posted',
      () async {
        final turn = _Turn();

        await turn.start();
        await turn.delta('Hello ');
        await turn.delta('world, here is ');
        await turn.delta('the answer. ');
        await turn.delta('Bye');
        final delivered = await turn.complete('Hello world, here is the answer. Bye');

        expect(delivered, isTrue, reason: 'the queue must skip its own send');
        final start = turn.api.startedStreams.single;
        expect(
          (start.channel, start.threadTs, start.recipientTeamId, start.recipientUserId),
          ('C1', '100.1', 'T1', 'U1'),
        );
        final stop = turn.api.stops.single;
        expect(turn.api.appends.every((append) => append.ts == stop.ts), isTrue, reason: 'one stream, one message');
        expect(turn.api.posts, isEmpty, reason: 'no chat.postMessage may carry the reply');
        expect(turn.api.updates, isEmpty, reason: 'the stream already holds exactly the reply');
        expect(turn.everythingSent, isNot(contains('(1/')));
        expect(
          [start.markdownText, ...turn.api.appends.map((a) => a.markdownText), stop.markdownText].join(),
          'Hello world, here is the answer. Bye',
        );
      },
    );

    test('a DM stream carries no recipient', () async {
      final turn = _Turn(inChannel: false, channel: 'D1');

      await turn.delta('Hi there ');
      await turn.complete('Hi there');

      final start = turn.api.startedStreams.single;
      expect((start.recipientTeamId, start.recipientUserId), (null, null));
    });

    test('appends are at least one second apart and at most 12,000 characters', () async {
      final turn = _Turn();
      final word = '${'a' * 99} ';

      for (var i = 0; i < 400; i++) {
        await turn.delta(word);
      }
      await turn.complete(word * 400);

      final writes = [turn.api.startedStreams.single.markdownText!, ...turn.api.appends.map((a) => a.markdownText)];
      expect(writes.length, greaterThan(1));
      expect(writes.every((text) => text.length <= 12000), isTrue);
      expect(turn.sleeps, isNotEmpty);
      expect(turn.sleeps.every((sleep) => sleep > Duration.zero && sleep <= const Duration(seconds: 1)), isTrue);
    });

    test('markup characters in streamed text are escaped so a ping stays inert', () async {
      final turn = _Turn();

      await turn.delta('Tell <!channel> & <@U123> now ');
      await turn.complete('Tell <!channel> & <@U123> now');

      final streamed = turn.api.startedStreams.single.markdownText!;
      expect(streamed, 'Tell &lt;!channel&gt; &amp; &lt;@U123&gt; now ');
      expect(turn.api.updates, isEmpty, reason: 'escaped the same way as the formatted reply, so it is equal');
    });
  });

  group('the stream message ends as exactly the reply (S02)', () {
    test('text from before a tool call is edited away, and a split token never leaves in part', () async {
      final turn = _Turn(redactor: MessageRedactor());
      const reply = 'The key is fine.';

      await turn.delta('Let me look. ');
      await turn.delta('Found $_token');
      await turn.delta(' in the config. ');
      await turn.delta('Checking ');
      final delivered = await turn.complete(reply);

      expect(delivered, isTrue);
      // The redactor itself reveals the first characters of a masked token (`xoxb-111***`); nothing past that.
      expect(turn.everythingSent, isNot(contains('xoxb-1111111111')), reason: 'no call may carry part of the token');
      expect(turn.everythingSent, contains('xoxb-111*** in the config.'));
      expect(turn.api.updates.single.text, reply);
      expect(turn.api.updates.single.ts, turn.api.stops.single.ts);
    });

    test('a token split across two deltas is held back until whitespace follows it', () async {
      final turn = _Turn(redactor: MessageRedactor());

      await turn.delta('key xoxb-1111111111-2222222');
      expect(turn.api.startedStreams.single.markdownText, 'key ', reason: 'only through the last whitespace');
      await turn.delta('222-AbCdEfGhIjKlMnOpQrStUvWx rest ');
      await turn.complete('key rest');

      expect(turn.everythingSent, isNot(contains('xoxb-1111111111-2222222')));
    });

    test('a stream message already equal to the formatted reply is left alone', () async {
      final turn = _Turn();

      await turn.delta('Plain answer ');
      await turn.delta('text.');
      await turn.complete('Plain answer text.');

      expect(turn.api.updates, isEmpty);
    });

    test('a reply with Markdown formatting is edited into its Slack-formatted form', () async {
      final turn = _Turn();

      await turn.delta('Some **bold** text ');
      await turn.complete('Some **bold** text');

      expect(turn.api.updates.single.text, 'Some *bold* text');
    });
  });

  group('no stream without streaming or a thread (S03)', () {
    test('streaming off makes no stream call, reports not delivered, and still shows the status', () async {
      final turn = _Turn(streaming: false);

      await turn.start();
      await turn.delta('text ');
      final delivered = await turn.complete('text');

      expect(delivered, isFalse);
      expect(turn.api.calls, ['assistant.threads.setStatus', 'assistant.threads.setStatus']);
      expect(turn.api.statuses.map((s) => s.status), ['is working...', '']);
    });

    test('a message with no thread makes no stream and no status call', () async {
      final turn = _Turn(threadTs: null);

      await turn.start();
      await turn.delta('text ');
      final delivered = await turn.complete('text');

      expect(delivered, isFalse);
      expect(turn.api.calls, isEmpty);
    });
  });

  group('the assistant status (OC02)', () {
    test('is set at the start and cleared on completion', () async {
      final turn = _Turn();

      await turn.start();
      expect(turn.api.statuses.single, (channel: 'C1', threadTs: '100.1', status: 'is working...'));
      await turn.complete('done');

      expect(turn.api.statuses.last, (channel: 'C1', threadTs: '100.1', status: ''));
    });

    test('is cleared when the turn fails, and the stream that was open is stopped', () async {
      final turn = _Turn();
      await turn.start();
      await turn.delta('partial ');

      await turn.strategy.onTurnFailed();

      expect(turn.api.stops, hasLength(1));
      expect(turn.api.updates, isEmpty, reason: 'there is no reply to write over the partial message');
      expect(turn.api.statuses.last.status, '');
    });

    test('a status call that fails logs a warning and never fails the turn or its reply', () async {
      final turn = _Turn();
      turn.api.onCall = (method) =>
          method == 'assistant.threads.setStatus' ? const SlackApiException('x', errorCode: 'missing_scope') : null;

      await turn.start();
      await turn.delta('Answer ');
      final delivered = await turn.complete('Answer');

      expect(delivered, isTrue);
      expect(logs.where((r) => r.level == Level.WARNING && r.message.contains('assistant status')), isNotEmpty);
    });
  });

  group('a stream that never starts still delivers the reply once (S05)', () {
    test('a start failure logs a warning, leaves no stream message, and reports not delivered', () async {
      final turn = _Turn();
      turn.api.onCall = (method) =>
          method == 'chat.startStream' ? const SlackApiException('x', errorCode: 'missing_scope') : null;

      await turn.delta('Answer ');
      await turn.delta('more ');
      final delivered = await turn.complete('Answer more');

      expect(delivered, isFalse, reason: 'the queue then posts the one complete reply');
      expect(turn.api.calls.where((c) => c == 'chat.startStream'), hasLength(1), reason: 'each turn tries once');
      expect(turn.api.appends, isEmpty);
      expect(turn.api.updates, isEmpty);
      expect(logs.where((r) => r.level == Level.WARNING && r.message.contains('start a Slack stream')), isNotEmpty);
    });

    test('a turn that emitted no text deltas reports not delivered and makes no stream call', () async {
      final turn = _Turn();

      await turn.start();
      final delivered = await turn.complete('Reply written in one go');

      expect(delivered, isFalse);
      expect(turn.api.startedStreams, isEmpty);
      expect(turn.api.stops, isEmpty);
    });
  });

  group('a stream that fails midway still delivers the reply once (S06)', () {
    test('stops the stream, edits the partial message into the complete formatted reply, and warns', () async {
      final turn = _Turn();
      turn.api.onCall = (method) => method == 'chat.appendStream'
          ? const SlackApiException('x', errorCode: 'ratelimited', statusCode: 429)
          : null;

      await turn.delta('Part one ');
      await turn.delta('part two ');
      final delivered = await turn.complete('Part one part two and the **end**');

      expect(delivered, isTrue);
      expect(turn.api.stops, hasLength(1));
      expect(turn.api.updates.single.text, 'Part one part two and the *end*');
      expect(turn.api.updates.single.ts, turn.api.stops.single.ts);
      expect(turn.api.posts, isEmpty);
      expect(logs.where((r) => r.level == Level.WARNING && r.message.contains('failed midway')), isNotEmpty);
    });

    test('when the edit fails too the reply is reported undelivered, so the queue posts it once', () async {
      final turn = _Turn();
      turn.api.onCall = (method) => switch (method) {
        'chat.appendStream' || 'chat.update' => const SlackApiException('x', errorCode: 'internal_error'),
        _ => null,
      };

      await turn.delta('Part one ');
      await turn.delta('part two ');
      final delivered = await turn.complete('Part one part two');

      expect(delivered, isFalse);
      expect(turn.api.posts, isEmpty, reason: 'the strategy leaves the one post to the queue');
    });

    test('a stop that fails still has the message edited into the reply', () async {
      final turn = _Turn();
      turn.api.onCall = (method) => method == 'chat.stopStream' ? const SlackApiException('x') : null;

      await turn.delta('Answer ');
      final delivered = await turn.complete('Answer');

      expect(delivered, isTrue);
      expect(turn.api.updates.single.text, 'Answer');
    });
  });

  group('a reply past the hard limit leaves the stream path (S07)', () {
    test('the first chunk is written over the stream message and the rest are posted in the thread', () async {
      final turn = _Turn();
      final reply = List.filled(9000, 'abcde').join(' '); // 53,999 characters

      await turn.delta('Working on it ');
      final delivered = await turn.complete(reply);

      expect(delivered, isTrue);
      expect(turn.api.stops, hasLength(1));
      final first = turn.api.updates.single;
      expect(first.ts, turn.api.stops.single.ts);
      expect(first.text, startsWith('(1/'));
      expect(first.text.length, lessThanOrEqualTo(4000));
      expect(turn.api.posts, isNotEmpty);
      expect(turn.api.posts.every((post) => post.threadTs == '100.1' && post.text.length <= 4000), isTrue);
      final total = int.parse(RegExp(r'^\(1/(\d+)\)').firstMatch(first.text)!.group(1)!);
      expect(turn.api.posts, hasLength(total - 1));
      expect(turn.api.posts.last.text, startsWith('($total/$total)'));
      final lengthKept = first.text.length + turn.api.posts.fold<int>(0, (sum, post) => sum + post.text.length);
      expect(lengthKept, greaterThanOrEqualTo(reply.length), reason: 'nothing is truncated');
    });
  });
}
