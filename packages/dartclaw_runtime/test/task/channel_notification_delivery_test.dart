import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/task/channel_notification_delivery.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:logging/logging.dart';
import 'package:test/test.dart';

void main() {
  late ChannelNotificationDelivery delivery;
  late FakeThreadedNotifications threads;
  late FakeChannel channel;
  late List<LogRecord> warnings;
  late List<LogRecord> posts;
  late StreamSubscription<LogRecord> logSubscription;

  setUp(() {
    delivery = ChannelNotificationDelivery();
    threads = FakeThreadedNotifications();
    channel = FakeChannel(type: ChannelType.slack, ownsAllJids: true, threadedNotifications: threads);
    warnings = [];
    posts = [];
    Logger.root.level = Level.ALL;
    logSubscription = Logger.root.onRecord.listen((record) {
      if (record.level == Level.WARNING) warnings.add(record);
      if (record.level == Level.INFO && record.loggerName == 'ChannelNotificationDelivery') posts.add(record);
    });
  });

  tearDown(() => logSubscription.cancel());

  const response = ChannelResponse(text: 'rendered &lt;!channel&gt;');

  final eventAt = DateTime.now().subtract(const Duration(seconds: 2));
  final notification = ChannelNotification(
    kind: ChannelNotificationKind.run,
    id: 'r1',
    text: 'Run started',
    title: 'Workflow',
    status: 'started',
    updatedAt: eventAt,
  );

  group('publicPageUrl', () {
    test('joins a path onto the base URL whatever its trailing slash, and answers null without one', () {
      expect(publicPageUrl('https://dartclaw.example', '/workflows/r1'), 'https://dartclaw.example/workflows/r1');
      expect(publicPageUrl(' https://dartclaw.example/ ', '/tasks/t1'), 'https://dartclaw.example/tasks/t1');
      expect(publicPageUrl(null, '/tasks/t1'), isNull);
      expect(publicPageUrl('  ', '/tasks/t1'), isNull);
    });
  });

  group('sendInNewThread', () {
    test('answers the post and sends nothing plain when the thread opens', () async {
      final post = await delivery.sendInNewThread(
        channel,
        threads,
        'C1',
        response,
        notification: notification,
        threadKey: 'run-1',
        subject: 'workflow run 1',
      );

      expect(post, isNotNull);
      expect(channel.sentMessages, isEmpty);
      expect(warnings, isEmpty);
    });

    test('falls back to one plain send of the channel-rendered text, never the raw notification text', () async {
      threads.newThreadReturnsNull = true;

      final post = await delivery.sendInNewThread(
        channel,
        threads,
        'C1',
        response,
        notification: notification,
        threadKey: 'run-1',
        subject: 'workflow run 1',
      );

      expect(post, isNull);
      expect(channel.sentMessages.single.$2.text, 'rendered &lt;!channel&gt;');
      expect(channel.sentMessages.single.$2.structuredPayload, isNull);
    });

    test('warns once per subject, and again for the same subject once it is forgotten', () async {
      threads.newThreadReturnsNull = true;
      Future<void> miss(String subject) => delivery.sendInNewThread(
        channel,
        threads,
        'C1',
        response,
        notification: notification,
        threadKey: 'k',
        subject: subject,
      );

      await miss('workflow run 1');
      await miss('workflow run 1');
      await miss('workflow run 2');
      expect(warnings, hasLength(2), reason: 'one for each subject');

      delivery.forget('workflow run 1');
      await miss('workflow run 1');
      expect(warnings, hasLength(3));
      expect(channel.sentMessages, hasLength(4), reason: 'every miss still falls back to its own plain send');
    });

    test('treats a throwing channel as a miss', () async {
      threads.sendError = StateError('disconnected');

      final post = await delivery.sendInNewThread(
        channel,
        threads,
        'C1',
        response,
        notification: notification,
        threadKey: 'run-1',
        subject: 'workflow run 1',
      );

      expect(post, isNull);
      expect(channel.sentMessages, hasLength(1));
      expect(warnings.single.message, allOf(contains('workflow run 1'), contains('disconnected')));
    });
  });

  group('sendInThread', () {
    test('drops a failed send with one warning per subject and never sends plain', () async {
      threads.existingThreadReturnsNull = true;

      for (var i = 0; i < 3; i++) {
        expect(
          await delivery.sendInThread(
            channel,
            threads,
            'C1',
            response,
            notification: notification,
            threadId: 'T1',
            subject: 'task t1',
          ),
          isNull,
        );
      }

      expect(channel.sentMessages, isEmpty);
      expect(warnings, hasLength(1));
      expect(warnings.single.message, contains('task t1'));
    });
  });

  group('sendRendered and sendPlain', () {
    test('a throwing channel is logged naming the subject and never rethrown', () async {
      channel.throwOnSend = true;

      await delivery.sendRendered(channel, 'C1', response, notification: notification, subject: 'task t1');
      await delivery.sendPlain(
        channel,
        'C1',
        const ChannelNotification(
          kind: ChannelNotificationKind.task,
          id: 't1',
          text: 'plain',
          title: 'T',
          status: 'running',
        ),
        subject: 'task t1',
      );

      expect(warnings, hasLength(2));
      expect(warnings.every((r) => r.message.contains('task t1')), isTrue);
    });

    test('sendPlain sends the notification text with no card', () async {
      await delivery.sendPlain(
        channel,
        'C1',
        const ChannelNotification(
          kind: ChannelNotificationKind.task,
          id: 't1',
          text: 'Task is running',
          title: 'T',
          status: 'running',
        ),
        subject: 'task t1',
      );

      final (recipient, sent) = channel.sentMessages.single;
      expect((recipient, sent.text), ('C1', 'Task is running'));
      expect(sent.structuredPayload, isNull);
    });
  });

  group('post log', () {
    test('every post that lands is logged at INFO with its ID, event kind, event time and delay', () async {
      await delivery.sendInNewThread(
        channel,
        threads,
        'C1',
        response,
        notification: notification,
        threadKey: 'run-r1',
        subject: 'workflow run r1',
      );
      await delivery.sendInThread(
        channel,
        threads,
        'C1',
        response,
        notification: notification,
        threadId: 'T1',
        subject: 'workflow run r1',
      );
      await delivery.sendRendered(channel, 'C1', response, notification: notification, subject: 'workflow run r1');
      await delivery.sendPlain(channel, 'C1', notification, subject: 'workflow run r1');

      expect(posts, hasLength(4), reason: 'one line per landed post, whichever send path carried it');
      for (final line in posts.map((record) => record.message)) {
        expect(line, startsWith('Posted run r1 started to slack C1 (event at ${eventAt.toUtc().toIso8601String()}, '));
        final delay = int.parse(RegExp(r', (\d+) ms after\)$').firstMatch(line)!.group(1)!);
        expect(delay, greaterThanOrEqualTo(2000), reason: 'the delay is measured from the event time');
      }
    });

    test('a post that does not land is logged as a warning only, never as a post', () async {
      threads.existingThreadReturnsNull = true;
      channel.throwOnSend = true;

      await delivery.sendInThread(
        channel,
        threads,
        'C1',
        response,
        notification: notification,
        threadId: 'T1',
        subject: 'workflow run r1',
      );
      await delivery.sendRendered(channel, 'C1', response, notification: notification, subject: 'workflow run r1');

      expect(posts, isEmpty);
      expect(warnings, hasLength(2));
    });

    test('a notification with no event time still logs the post, without a delay', () async {
      await delivery.sendPlain(
        channel,
        'C1',
        const ChannelNotification(
          kind: ChannelNotificationKind.task,
          id: 't1',
          text: 'plain',
          title: 'T',
          status: 'running',
        ),
        subject: 'task t1',
      );

      expect(posts.single.message, 'Posted task t1 running to slack C1');
    });
  });
}
