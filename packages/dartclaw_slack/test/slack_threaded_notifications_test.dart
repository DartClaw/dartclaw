import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        ChannelNotification,
        ChannelNotificationAction,
        ChannelNotificationKind,
        ChannelResponse,
        ThreadedNotifications,
        runActionNonceKey,
        runActionRunIdKey,
        runActionStepIdKey,
        runApproveActionId,
        runRejectActionId;
import 'package:dartclaw_slack/dartclaw_slack.dart';
import 'package:test/test.dart';

import 'support/slack_harness.dart';

void main() {
  late SlackHarness harness;
  late ThreadedNotifications threaded;

  setUp(() async {
    harness = await SlackHarness.start();
    threaded = harness.channel.threadedNotifications!;
  });

  tearDown(() => harness.close());

  List<Map<String, dynamic>> blocksOf(ChannelResponse response) =>
      (response.structuredPayload!['blocks'] as List).cast<Map<String, dynamic>>();

  String textOf(Map<String, dynamic> block) => (block['text'] as Map<String, dynamic>)['text'] as String;

  group('extractThread', () {
    test('a thread reply is conversation-qualified by the thread it belongs to', () async {
      await harness.deliver([
        message(channel: 'C1', user: 'U2', text: 'hi', ts: '100.2', threadTs: '100.1', mention: true),
      ]);

      expect(threaded.extractThread(harness.turns.single.message.metadata), 'C1:100.1');
    });

    test('a top-level message opens a thread under its own ts', () async {
      await harness.deliver([message(channel: 'C1', user: 'U1', text: 'hi', ts: '200.1', mention: true)]);

      expect(threaded.extractThread(harness.turns.single.message.metadata), 'C1:200.1');
    });

    test('a slash command or an empty value carries no thread', () {
      expect(threaded.extractThread({'spaceName': 'C1'}), isNull);
      expect(threaded.extractThread({'spaceName': '', 'threadId': '1.1'}), isNull);
      expect(threaded.extractThread({'spaceName': 'C1', 'threadId': ''}), isNull);
      expect(threaded.extractThread({'threadName': 'spaces/AAA/threads/T'}), isNull);
    });
  });

  group('render', () {
    test('gives section blocks with the plain text as fallback', () {
      final response = threaded.render(
        const ChannelNotification(
          kind: ChannelNotificationKind.run,
          id: 'run-1',
          text: "Run run-1 of 'release' failed.",
          title: 'release',
          status: 'failed',
          body: 'Step build stopped.',
          error: 'exit 2',
          facts: {'Workflow': 'release', 'Run': 'run-1'},
        ),
      );

      expect(response.text, "Run run-1 of 'release' failed.");
      final blocks = blocksOf(response);
      expect(blocks.map((block) => block['type']), everyElement('section'));
      expect(blocks.map((block) => (block['text'] as Map)['type']), everyElement('mrkdwn'));
      expect(blocks.map(textOf), [
        '*release* – failed',
        'Step build stopped.',
        '*Error*: exit 2',
        '*Workflow*: release\n*Run*: run-1',
      ]);
    });

    test('escapes & < > in every interpolated value so nothing can ping', () {
      final response = threaded.render(
        const ChannelNotification(
          kind: ChannelNotificationKind.task,
          id: 't1',
          text: 'Task <!channel> & more',
          title: 'Fix <@U1> & co',
          status: 'a<b',
          body: '<!here> body & text',
          error: 'x > y',
          facts: {'k<ey': 'v&l<ue>'},
        ),
      );

      expect(response.text, 'Task &lt;!channel&gt; &amp; more');
      expect(blocksOf(response).map(textOf), [
        '*Fix &lt;@U1&gt; &amp; co* – a&lt;b',
        '&lt;!here&gt; body &amp; text',
        '*Error*: x &gt; y',
        '*k&lt;ey*: v&amp;l&lt;ue&gt;',
      ]);
    });

    test('keeps every section within Slack\'s 3,000 character limit without cutting an entity', () {
      final response = threaded.render(
        ChannelNotification(
          kind: ChannelNotificationKind.run,
          id: 'r',
          text: 't',
          title: 'w',
          status: 'finished',
          body: '${'x' * 2996}&&&',
        ),
      );

      final body = textOf(blocksOf(response)[1]);
      expect(body.length, lessThanOrEqualTo(3000));
      expect(body, endsWith('...'));
      expect(body, isNot(contains(RegExp(r'&[a-z]{0,3}\.\.\.$'))));
    });
  });

  group('render with actions', () {
    const approval = ChannelNotification(
      kind: ChannelNotificationKind.run,
      id: 'run-1',
      text: 'Run run-1 awaits approval.',
      title: 'release',
      status: 'awaiting_approval',
      actions: [
        ChannelNotificationAction(id: runApproveActionId, label: 'Approve'),
        ChannelNotificationAction(id: runRejectActionId, label: 'Reject'),
      ],
      actionData: {runActionRunIdKey: 'run-1', runActionStepIdKey: 'gate', runActionNonceKey: 'n0nce'},
    );

    test('adds one button per action after the sections, each carrying the data as one compact string', () {
      final blocks = blocksOf(threaded.render(approval));

      expect(blocks.map((block) => block['type']), ['section', 'actions']);
      final buttons = (blocks.last['elements'] as List).cast<Map<String, dynamic>>();
      expect(buttons.map((button) => button['type']), everyElement('button'));
      expect(buttons.map((button) => (button['text'] as Map)['text']), ['Approve', 'Reject']);
      expect(buttons.map((button) => button['action_id']), [runApproveActionId, runRejectActionId]);
      for (final button in buttons) {
        final value = button['value'] as String;
        expect(jsonDecode(value), {runActionRunIdKey: 'run-1', runActionStepIdKey: 'gate', runActionNonceKey: 'n0nce'});
        expect(value, isNot(contains(' ')), reason: 'compact, to stay within Slack\'s 2,000 character value limit');
      }
    });

    test('a notification with no actions has no actions block, which is how a retired post loses its buttons', () {
      final blocks = blocksOf(
        threaded.render(
          const ChannelNotification(
            kind: ChannelNotificationKind.run,
            id: 'run-1',
            text: 'Approved.',
            title: 'release',
            status: 'approved',
            actionData: {runActionNonceKey: 'n0nce'},
          ),
        ),
      );

      expect(blocks.map((block) => block['type']), everyElement('section'));
      expect(jsonEncode(blocks), isNot(contains('n0nce')));
    });
  });

  group('edit', () {
    test('replaces the text and the blocks of the posted message in its channel', () async {
      final response = threaded.render(
        const ChannelNotification(
          kind: ChannelNotificationKind.run,
          id: 'run-1',
          text: 'Approved by Ada at 10:00 UTC',
          title: 'release',
          status: 'approved',
        ),
      );

      final edited = await threaded.edit('C1', '100.1', response);

      expect(edited, isTrue);
      final update = harness.api.updates.single;
      expect((update.channel, update.ts, update.text), ('C1', '100.1', 'Approved by Ada at 10:00 UTC'));
      expect(update.blocks, blocksOf(response));
    });

    test('a response without blocks sends none, so Slack drops the old buttons', () async {
      await threaded.edit('C1', '100.1', const ChannelResponse(text: 'No longer pending'));

      expect(harness.api.updates.single.blocks, isEmpty);
      expect(
        harness.api.updates.single.blocks,
        isNotNull,
        reason: 'Slack keeps the old blocks when the field is absent',
      );
    });

    test('an edit Slack refuses returns false without throwing', () async {
      harness.api.onCall = (method) =>
          method == 'chat.update' ? const SlackApiException('chat.update failed: message_not_found') : null;

      expect(await threaded.edit('C1', '100.1', const ChannelResponse(text: 'x')), isFalse);
      expect(harness.api.updates, isEmpty);
    });
  });

  group('sendToNewThread', () {
    test('posts at top level with the text and blocks and returns the qualified identity', () async {
      final response = threaded.render(
        const ChannelNotification(
          kind: ChannelNotificationKind.run,
          id: 'r1',
          text: 'Started.',
          title: 'w',
          status: 'started',
        ),
      );

      final post = await threaded.sendToNewThread('C1', response, threadKey: 'run-r1');

      final sent = harness.api.posts.single;
      expect((sent.channel, sent.text, sent.threadTs), ('C1', 'Started.', null));
      expect(sent.blocks, blocksOf(response));
      expect(post?.messageId, '1700000000.000000');
      expect(post?.threadId, 'C1:1700000000.000000');
    });

    test('a post that Slack refuses returns null without throwing', () async {
      harness.api.onPost = (_, _) => const SlackApiException('chat.postMessage failed: channel_not_found');

      expect(await threaded.sendToNewThread('C1', const ChannelResponse(text: 'x'), threadKey: 'k'), isNull);
      expect(harness.api.posts, isEmpty);
    });

    test('a mention-free reply in the opened thread is admitted, one in another thread is not', () async {
      final post = await threaded.sendToNewThread('C1', const ChannelResponse(text: 'Started.'), threadKey: 'k');
      final ts = post!.messageId;

      await harness.deliver([
        message(channel: 'C1', user: 'U2', text: 'reply in the run thread', ts: '9000.1', threadTs: ts),
        message(channel: 'C1', user: 'U2', text: 'reply elsewhere', ts: '9000.3', threadTs: '9000.2'),
      ]);

      expect(harness.turns.map((turn) => turn.message.text), ['reply in the run thread']);
      expect(harness.api.repliesCalls, ['C1:9000.2']);
      expect(threaded.extractThread(harness.turns.single.message.metadata), post.threadId);
    });
  });

  group('sendToThread', () {
    test('posts into the thread by its ts and returns the identity as given', () async {
      final post = await threaded.sendToThread('C1', const ChannelResponse(text: 'Done.'), threadId: 'C1:100.1');

      final sent = harness.api.posts.single;
      expect((sent.channel, sent.text, sent.threadTs), ('C1', 'Done.', '100.1'));
      expect(post?.threadId, 'C1:100.1');
      expect(post?.messageId, '1700000000.000000');
    });

    test('notes participation so a mention-free reply is admitted', () async {
      await threaded.sendToThread('C1', const ChannelResponse(text: 'Done.'), threadId: 'C1:100.1');

      await harness.deliver([message(channel: 'C1', user: 'U2', text: 'follow-up', ts: '100.5', threadTs: '100.1')]);

      expect(harness.turns.map((turn) => turn.message.text), ['follow-up']);
    });

    test('a failed post or a malformed identity returns null without throwing', () async {
      harness.api.onPost = (_, _) => const SlackApiException('chat.postMessage failed: thread_not_found');
      expect(await threaded.sendToThread('C1', const ChannelResponse(text: 'x'), threadId: 'C1:100.1'), isNull);

      harness.api.onPost = null;
      expect(await threaded.sendToThread('C1', const ChannelResponse(text: 'x'), threadId: '100.1'), isNull);
      expect(harness.api.posts, isEmpty);
    });
  });
}
