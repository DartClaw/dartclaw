import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/task/workflow_run_notification_subscriber.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowRun, WorkflowRunOrigin;
import 'package:logging/logging.dart';
import 'package:test/test.dart';

/// A fake capability that holds one run's new-thread send until [gate] completes.
class _GatedThreads extends FakeThreadedNotifications {
  new(this.gatedKey, this.gate);

  final String gatedKey;
  final Completer<void> gate;

  @override
  Future<ThreadedPost?> sendToNewThread(
    String recipientId,
    ChannelResponse response, {
    required String threadKey,
  }) async {
    if (threadKey == gatedKey) await gate.future;
    return super.sendToNewThread(recipientId, response, threadKey: threadKey);
  }
}

/// A fake capability whose rendered text differs from the notification's, as Slack's escaping does.
class _EscapingThreads extends FakeThreadedNotifications {
  @override
  ChannelResponse render(ChannelNotification notification) {
    final rendered = super.render(notification);
    return ChannelResponse(
      text: rendered.text.replaceAll('<', '&lt;').replaceAll('>', '&gt;'),
      structuredPayload: rendered.structuredPayload,
    );
  }
}

void main() {
  late EventBus eventBus;
  late Directory tempDir;
  late ThreadBindingStore store;
  late Map<String, WorkflowRun> runs;
  late List<LogRecord> logs;
  late StreamSubscription<LogRecord> logSubscription;
  late FakeThreadedNotifications slackThreads;
  late FakeChannel slack;
  late FakeChannel whatsapp;

  setUp(() async {
    eventBus = EventBus();
    tempDir = Directory.systemTemp.createTempSync('workflow_run_notifications_test_');
    store = ThreadBindingStore(File('${tempDir.path}/thread-bindings.json'));
    await store.load();
    runs = {};
    logs = [];
    Logger.root.level = Level.ALL;
    logSubscription = Logger.root.onRecord.listen(logs.add);
    slackThreads = FakeThreadedNotifications();
    slack = FakeChannel(name: 'slack', type: ChannelType.slack, ownsAllJids: true, threadedNotifications: slackThreads);
    whatsapp = FakeChannel(name: 'wa', type: ChannelType.whatsapp, ownsAllJids: true);
  });

  tearDown(() async {
    await logSubscription.cancel();
    await eventBus.dispose();
    tempDir.deleteSync(recursive: true);
  });

  WorkflowRunNotificationSubscriber subscribe(
    List<Channel> channels, {
    WorkflowChatNotificationsConfig? configured,
    ThreadBindingStore? bindings,
    String? baseUrl,
  }) {
    final manager = ChannelManager(queue: RecordingMessageQueue(), config: const ChannelConfig.defaults());
    for (final channel in channels) {
      manager.registerChannel(channel);
    }
    final subscriber = WorkflowRunNotificationSubscriber(
      lookupRun: (id) async => runs[id],
      channelManager: manager,
      configured: configured,
      threadBindings: bindings ?? store,
      baseUrl: baseUrl,
    );
    subscriber.subscribe(eventBus);
    addTearDown(subscriber.dispose);
    return subscriber;
  }

  WorkflowRun addRun(String id, WorkflowRunOrigin origin, {String workflow = 'code-review'}) {
    final now = DateTime.utc(2026, 10, 6);
    return runs[id] = WorkflowRun(id: id, definitionName: workflow, startedAt: now, updatedAt: now, origin: origin);
  }

  void status(String runId, WorkflowRunStatus from, WorkflowRunStatus to, {String? error}) {
    eventBus.fire(
      WorkflowRunStatusChangedEvent(
        runId: runId,
        definitionName: runs[runId]?.definitionName ?? 'code-review',
        oldStatus: from,
        newStatus: to,
        errorMessage: error,
        timestamp: DateTime.utc(2026, 10, 6, 1),
      ),
    );
  }

  void approval(String runId, {String stepId = 'gate', String message = 'Review the plan'}) {
    eventBus.fire(
      WorkflowApprovalRequestedEvent(
        runId: runId,
        stepId: stepId,
        message: message,
        timestamp: DateTime.utc(2026, 10, 6, 1),
      ),
    );
  }

  void stepDone(String runId, {int index = 2, int total = 5, bool success = true, String? outcome}) {
    eventBus.fire(
      WorkflowStepCompletedEvent(
        runId: runId,
        stepId: 'implement',
        stepName: 'Implement',
        stepIndex: index,
        totalSteps: total,
        taskId: 'task-1',
        success: success,
        outcome: outcome,
        tokenCount: null,
        timestamp: DateTime.utc(2026, 10, 6, 1),
      ),
    );
  }

  Future<void> settle() async {
    await pumpEventQueue(times: 50);
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  const slackOrigin = WorkflowRunOrigin(
    surface: 'slack',
    channelType: 'slack',
    recipientId: 'C1',
    threadId: 'C1:1700000000.000100',
    sessionKey: 'agent:main:group:slack:C1',
    senderId: 'U1',
  );
  const web = WorkflowRunOrigin(surface: 'web');
  const configuredSlack = WorkflowChatNotificationsConfig(channel: ChannelType.slack, recipient: 'CNOTIFY');

  Iterable<LogRecord> warnings(String needle) =>
      logs.where((r) => r.level == Level.WARNING && r.message.contains(needle));

  group('destinations', () {
    test('a run started from a threaded origin posts started, approval and finished into that thread only', () async {
      final configuredChannel = FakeThreadedNotifications();
      final other = FakeChannel(
        name: 'gchat',
        type: ChannelType.googlechat,
        ownsAllJids: true,
        threadedNotifications: configuredChannel,
      );
      subscribe([
        slack,
        other,
      ], configured: const WorkflowChatNotificationsConfig(channel: ChannelType.googlechat, recipient: 'spaces/CFG'));
      addRun('run-1', slackOrigin);

      status('run-1', WorkflowRunStatus.pending, WorkflowRunStatus.running);
      approval('run-1', stepId: 'gate', message: 'Review the plan');
      status('run-1', WorkflowRunStatus.running, WorkflowRunStatus.completed);
      await settle();

      expect(slackThreads.sends, hasLength(3));
      for (final send in slackThreads.sends) {
        expect((send.recipientId, send.threadKey, send.threadId), ('C1', null, 'C1:1700000000.000100'));
      }
      expect(slackThreads.rendered.map((n) => n.status), ['started', 'awaiting_approval', 'finished']);
      for (final text in slackThreads.rendered.map((n) => n.text)) {
        expect(text, allOf(contains("'code-review'"), contains('run-1')));
      }
      expect(slackThreads.rendered[1].text, contains('gate'));
      expect(slackThreads.rendered[1].facts, containsPair('Step', 'gate'));
      expect(configuredChannel.sends, isEmpty);
      expect(other.sentMessages, isEmpty);
      expect(slack.sentMessages, isEmpty, reason: 'a post into an existing thread is not also sent plain');
      expect(store.lookupByRun('run-1'), isEmpty, reason: 'an origin thread is not bound; only the run creates one');
    });

    test('a second threaded channel posts into its own origin thread the same way', () async {
      final googleChatThreads = FakeThreadedNotifications();
      final googleChat = FakeChannel(
        name: 'gchat',
        type: ChannelType.googlechat,
        ownsAllJids: true,
        threadedNotifications: googleChatThreads,
      );
      subscribe([slack, googleChat], configured: configuredSlack);
      addRun(
        'run-2',
        const WorkflowRunOrigin(
          surface: 'googlechat',
          channelType: 'googlechat',
          recipientId: 'spaces/AAA',
          threadId: 'spaces/AAA/threads/T1',
        ),
      );

      status('run-2', WorkflowRunStatus.pending, WorkflowRunStatus.running);
      await settle();

      final send = googleChatThreads.sends.single;
      expect((send.recipientId, send.threadId, send.threadKey), ('spaces/AAA', 'spaces/AAA/threads/T1', null));
      expect(slackThreads.sends, isEmpty);
    });

    test('an approval post carries the first 1,000 characters of what is under review and the run page link', () async {
      subscribe([slack], baseUrl: 'https://dartclaw.example/');
      addRun('run-1', slackOrigin);
      final message = '${'a' * 1000}${'b' * 500}';

      approval('run-1', message: message);
      await settle();

      final notification = slackThreads.rendered.single;
      expect(notification.body, 'a' * 1000);
      expect(notification.text, contains('a' * 1000));
      expect(notification.text, isNot(contains('b')));
      expect(notification.text, contains('https://dartclaw.example/workflows/run-1'));
      expect(notification.facts['Run page'], 'https://dartclaw.example/workflows/run-1');
    });

    test('an approval post has no link when the deployment declares no base_url', () async {
      subscribe([slack]);
      addRun('run-1', slackOrigin);

      approval('run-1', message: 'Review the plan');
      await settle();

      final notification = slackThreads.rendered.single;
      expect(notification.text, isNot(contains('/workflows/')));
      expect(notification.facts.keys, isNot(contains('Run page')));
    });

    test('a failure post carries the error cut at 1,000 characters', () async {
      subscribe([slack]);
      addRun('run-1', slackOrigin);

      status('run-1', WorkflowRunStatus.running, WorkflowRunStatus.failed, error: '${'e' * 1000}${'x' * 500}');
      await settle();

      final notification = slackThreads.rendered.single;
      expect(notification.error, 'e' * 1000);
      expect(notification.text, endsWith('e' * 1000));
      expect(notification.text, isNot(contains('x')));
      expect(notification.status, 'failed');
    });

    test('a cancelled run counts as finished', () async {
      subscribe([slack]);
      addRun('run-1', slackOrigin);

      status('run-1', WorkflowRunStatus.running, WorkflowRunStatus.cancelled);
      await settle();

      expect(slackThreads.rendered.single.status, 'finished');
      expect(slackThreads.rendered.single.text, contains('cancelled'));
    });

    test('a run started outside chat gets one thread per run in the configured channel, closed with the run', () async {
      subscribe([slack], configured: configuredSlack);
      addRun('run-a', web, workflow: 'plan-and-implement');
      addRun('run-b', web, workflow: 'code-review');

      status('run-a', WorkflowRunStatus.pending, WorkflowRunStatus.running);
      status('run-b', WorkflowRunStatus.pending, WorkflowRunStatus.running);
      await settle();

      final threadA = store.lookupByRun('run-a').single;
      final threadB = store.lookupByRun('run-b').single;
      expect(threadA.threadId, isNot(threadB.threadId), reason: 'two runs in one channel keep their own thread');
      expect((threadA.channelType, threadA.sessionKey), ('slack', null));
      expect(slackThreads.sends.map((s) => (s.recipientId, s.threadKey)), [
        ('CNOTIFY', 'run-run-a'),
        ('CNOTIFY', 'run-run-b'),
      ]);

      slackThreads.sends.clear();
      status('run-a', WorkflowRunStatus.running, WorkflowRunStatus.completed);
      status('run-b', WorkflowRunStatus.running, WorkflowRunStatus.failed, error: 'boom');
      await settle();

      expect(slackThreads.sends.map((s) => (s.threadId, s.threadKey)), [
        (threadA.threadId, null),
        (threadB.threadId, null),
      ], reason: 'every later post of a run lands in that run\'s thread, the finish post included');
      expect(store.lookupByRun('run-a'), isEmpty, reason: 'the binding is deleted after the finished post');
      expect(store.lookupByRun('run-b'), isEmpty, reason: 'and after the failed post');
      expect(slack.sentMessages, isEmpty);
    });

    test('a run with no origin thread on a threaded channel falls to the configured channel', () async {
      subscribe([slack], configured: configuredSlack);
      addRun(
        'run-1',
        const WorkflowRunOrigin(
          surface: 'slack',
          channelType: 'slack',
          recipientId: 'C1',
          sessionKey: 'agent:main:group:slack:C1',
        ),
      );

      status('run-1', WorkflowRunStatus.pending, WorkflowRunStatus.running);
      await settle();

      expect(slackThreads.sends.single.recipientId, 'CNOTIFY');
      expect(slackThreads.sends.single.threadKey, 'run-run-1');
    });

    test('nothing is posted without a configured channel, and never for an unknown origin', () async {
      subscribe([slack]);
      addRun('run-web', web);
      addRun('run-legacy', WorkflowRunOrigin.unknown);

      status('run-web', WorkflowRunStatus.pending, WorkflowRunStatus.running);
      await settle();
      expect(slackThreads.sends, isEmpty);
      expect(slack.sentMessages, isEmpty);

      final withConfigured = FakeThreadedNotifications();
      final other = FakeChannel(type: ChannelType.googlechat, ownsAllJids: true, threadedNotifications: withConfigured);
      subscribe([
        other,
      ], configured: const WorkflowChatNotificationsConfig(channel: ChannelType.googlechat, recipient: 'spaces/CFG'));
      status('run-legacy', WorkflowRunStatus.pending, WorkflowRunStatus.running);
      approval('run-legacy');
      status('run-legacy', WorkflowRunStatus.running, WorkflowRunStatus.completed);
      await settle();
      expect(withConfigured.sends, isEmpty, reason: 'a legacy row never notifies, even with a channel configured');
      expect(store.lookupByRun('run-legacy'), isEmpty);
    });

    test('a configured channel that declares no capability gets plain posts and no binding', () async {
      subscribe([
        whatsapp,
      ], configured: const WorkflowChatNotificationsConfig(channel: ChannelType.whatsapp, recipient: 'group@g.us'));
      addRun('run-1', web);

      status('run-1', WorkflowRunStatus.pending, WorkflowRunStatus.running);
      status('run-1', WorkflowRunStatus.running, WorkflowRunStatus.completed);
      await settle();

      expect(whatsapp.sentMessages.map((m) => m.$1), ['group@g.us', 'group@g.us']);
      expect(whatsapp.sentMessages.first.$2.text, allOf(contains("'code-review'"), contains('run-1')));
      expect(whatsapp.sentMessages.first.$2.structuredPayload, isNull);
      expect(store.lookupByRun('run-1'), isEmpty);
    });

    for (final origin in [
      (name: 'DM', recipient: 'sender@s.whatsapp.net'),
      (name: 'group', recipient: '120363000000000000@g.us'),
    ]) {
      test(
        'a run started from a WhatsApp ${origin.name} posts plain messages there and not to the configured channel',
        () async {
          subscribe([whatsapp, slack], configured: configuredSlack);
          addRun(
            'run-1',
            WorkflowRunOrigin(surface: 'whatsapp', channelType: 'whatsapp', recipientId: origin.recipient),
          );

          status('run-1', WorkflowRunStatus.pending, WorkflowRunStatus.running);
          approval('run-1');
          status('run-1', WorkflowRunStatus.running, WorkflowRunStatus.completed);
          await settle();

          expect(whatsapp.sentMessages.map((m) => m.$1), List.filled(3, origin.recipient));
          expect(whatsapp.sentMessages.every((m) => m.$2.structuredPayload == null), isTrue);
          expect(slackThreads.sends, isEmpty);
          expect(slack.sentMessages, isEmpty);
          expect(whatsapp.sentMessages[1].$2.text, contains('awaiting approval'));
        },
      );
    }

    test(
      'an origin channel that is not registered posts nothing and warns, never falling to the configured channel',
      () async {
        subscribe([slack], configured: configuredSlack);
        addRun('run-1', const WorkflowRunOrigin(surface: 'signal', channelType: 'signal', recipientId: '+4670000000'));

        status('run-1', WorkflowRunStatus.pending, WorkflowRunStatus.running);
        await settle();

        expect(slackThreads.sends, isEmpty);
        expect(warnings('signal'), isNotEmpty);
      },
    );
  });

  group('sequencing', () {
    test('events of one run fired in one turn open exactly one thread and post in event order', () async {
      // The thread is still opening when the later events arrive, which is what a slow channel looks like.
      final gate = Completer<void>();
      final gated = _GatedThreads('run-run-1', gate);
      final channel = FakeChannel(type: ChannelType.slack, ownsAllJids: true, threadedNotifications: gated);
      subscribe([channel], configured: configuredSlack);
      addRun('run-1', web);

      status('run-1', WorkflowRunStatus.pending, WorkflowRunStatus.running);
      approval('run-1');
      status('run-1', WorkflowRunStatus.running, WorkflowRunStatus.completed);
      await settle();
      expect(gated.sends, isEmpty);

      gate.complete();
      await settle();

      expect(gated.sends.where((s) => s.threadKey != null), hasLength(1));
      expect(gated.rendered.map((n) => n.status), ['started', 'awaiting_approval', 'finished']);
      final thread = gated.sends.first.post!.threadId;
      expect(gated.sends.skip(1).map((s) => s.threadId), [thread, thread]);
      expect(store.lookupByRun('run-1'), isEmpty);
    });

    test('a run whose thread is still opening does not delay another run', () async {
      final gate = Completer<void>();
      final gated = _GatedThreads('run-run-a', gate);
      final channel = FakeChannel(type: ChannelType.slack, ownsAllJids: true, threadedNotifications: gated);
      subscribe([channel], configured: configuredSlack);
      addRun('run-a', web);
      addRun('run-b', web);

      status('run-a', WorkflowRunStatus.pending, WorkflowRunStatus.running);
      status('run-b', WorkflowRunStatus.pending, WorkflowRunStatus.running);
      status('run-a', WorkflowRunStatus.running, WorkflowRunStatus.completed);
      await settle();

      expect(gated.sends.map((s) => s.threadKey), ['run-run-b'], reason: 'run B posted while run A was held');
      expect(store.lookupByRun('run-a'), isEmpty);

      gate.complete();
      await settle();

      expect(gated.sends.map((s) => s.threadKey ?? s.threadId), [
        'run-run-b',
        'run-run-a',
        gated.sends[1].post!.threadId,
      ], reason: 'A opened its thread, then finished in it');
      expect(store.lookupByRun('run-a'), isEmpty, reason: 'closed with the run');
    });

    test('config selects the events: only finished posts, but a terminal event still closes the run thread', () async {
      subscribe(
        [slack],
        configured: const WorkflowChatNotificationsConfig(
          channel: ChannelType.slack,
          recipient: 'CNOTIFY',
          events: {WorkflowChatNotificationEvent.finished},
        ),
      );
      addRun('run-1', web);

      status('run-1', WorkflowRunStatus.pending, WorkflowRunStatus.running);
      approval('run-1');
      stepDone('run-1');
      await settle();
      expect(slackThreads.sends, isEmpty);

      status('run-1', WorkflowRunStatus.running, WorkflowRunStatus.completed);
      await settle();
      expect(slackThreads.rendered.map((n) => n.status), ['finished']);
    });

    test('a run thread is released at its terminal event even when that event is not selected for posting', () async {
      subscribe(
        [slack],
        configured: const WorkflowChatNotificationsConfig(
          channel: ChannelType.slack,
          recipient: 'CNOTIFY',
          events: {WorkflowChatNotificationEvent.started},
        ),
      );
      addRun('run-1', web);

      status('run-1', WorkflowRunStatus.pending, WorkflowRunStatus.running);
      await settle();
      expect(store.lookupByRun('run-1'), hasLength(1));

      status('run-1', WorkflowRunStatus.running, WorkflowRunStatus.failed, error: 'boom');
      await settle();

      expect(slackThreads.sends, hasLength(1), reason: 'the failed event was not selected');
      expect(store.lookupByRun('run-1'), isEmpty);
    });

    test('the default selection is started, awaiting approval, finished and failed, never the step line', () async {
      subscribe([slack]);
      addRun('run-1', slackOrigin);

      status('run-1', WorkflowRunStatus.pending, WorkflowRunStatus.running);
      stepDone('run-1');
      status('run-1', WorkflowRunStatus.running, WorkflowRunStatus.paused);
      status('run-1', WorkflowRunStatus.paused, WorkflowRunStatus.running);
      approval('run-1');
      status('run-1', WorkflowRunStatus.running, WorkflowRunStatus.failed);
      await settle();

      expect(slackThreads.rendered.map((n) => n.status), ['started', 'awaiting_approval', 'failed']);
    });

    test('step_completed, once selected, posts one line naming the step, its position and its outcome', () async {
      subscribe(
        [whatsapp],
        configured: const WorkflowChatNotificationsConfig(
          channel: ChannelType.whatsapp,
          recipient: 'group@g.us',
          events: {WorkflowChatNotificationEvent.stepCompleted},
        ),
      );
      addRun('run-1', web);

      stepDone('run-1', index: 2, total: 5, success: true);
      stepDone('run-1', index: 3, total: 5, success: false, outcome: 'needsInput');
      await settle();

      expect(whatsapp.sentMessages.map((m) => m.$2.text), [
        "Workflow 'code-review' (run run-1): step 'Implement' (3/5) succeeded.",
        "Workflow 'code-review' (run run-1): step 'Implement' (4/5) needsInput.",
      ]);
    });

    test('a resume or retry that returns a run to running does not post started again', () async {
      subscribe([slack]);
      addRun('run-1', slackOrigin);

      status('run-1', WorkflowRunStatus.paused, WorkflowRunStatus.running);
      status('run-1', WorkflowRunStatus.failed, WorkflowRunStatus.running);
      await settle();

      expect(slackThreads.sends, isEmpty);
    });

    test('a throwing channel never stops later events or the run, and each failed post warns naming the run', () async {
      slackThreads.sendError = StateError('disconnected');
      subscribe([slack, whatsapp], configured: configuredSlack);
      addRun('run-1', web);
      addRun(
        'run-wa',
        const WorkflowRunOrigin(surface: 'whatsapp', channelType: 'whatsapp', recipientId: 'dm@s.whatsapp.net'),
      );
      whatsapp.throwOnSend = true;

      status('run-wa', WorkflowRunStatus.pending, WorkflowRunStatus.running);
      status('run-wa', WorkflowRunStatus.running, WorkflowRunStatus.completed);
      status('run-1', WorkflowRunStatus.pending, WorkflowRunStatus.running);
      status('run-1', WorkflowRunStatus.running, WorkflowRunStatus.completed);
      await settle();

      expect(warnings('workflow run run-wa'), hasLength(2), reason: 'both plain posts were attempted and logged');
      expect(warnings('workflow run run-1'), isNotEmpty);
      expect(slackThreads.sends, hasLength(2), reason: 'the later event was still handled');
      expect(store.lookupByRun('run-1'), isEmpty);
    });

    test('a new-thread send without a thread identity falls back to a plain send and warns once per run', () async {
      slackThreads.newThreadReturnsNull = true;
      subscribe([slack], configured: configuredSlack);
      addRun('run-1', web);

      status('run-1', WorkflowRunStatus.pending, WorkflowRunStatus.running);
      approval('run-1');
      await settle();

      expect(slack.sentMessages.map((m) => m.$1), ['CNOTIFY', 'CNOTIFY'], reason: 'each post falls back to plain');
      expect(store.lookupByRun('run-1'), isEmpty);
      expect(warnings('workflow run run-1'), hasLength(1));
    });

    test('the plain fallback carries the text the channel rendered, never the raw notification text', () async {
      // Slack escapes `<!channel>` in its render; a fallback of the raw text would broadcast it.
      final escaping = _EscapingThreads()..newThreadReturnsNull = true;
      final channel = FakeChannel(
        name: 'slack',
        type: ChannelType.slack,
        ownsAllJids: true,
        threadedNotifications: escaping,
      );
      subscribe([channel], configured: configuredSlack);
      addRun('run-1', web);

      approval('run-1', message: '<!channel> please look');
      await settle();

      expect(channel.sentMessages.single.$2.text, contains('&lt;!channel&gt;'));
      expect(channel.sentMessages.single.$2.text, isNot(contains('<!channel>')));
    });

    test(
      'a send into an existing thread that fails is dropped with one warning per run and no plain fallback',
      () async {
        subscribe([slack]);
        addRun('run-1', slackOrigin);
        slackThreads.existingThreadReturnsNull = true;

        status('run-1', WorkflowRunStatus.pending, WorkflowRunStatus.running);
        approval('run-1');
        status('run-1', WorkflowRunStatus.running, WorkflowRunStatus.completed);
        await settle();

        expect(slack.sentMessages, isEmpty);
        expect(slackThreads.sends, hasLength(3), reason: 'every post is still attempted');
        expect(warnings('workflow run run-1'), hasLength(1));
      },
    );

    test('an event for a run that cannot be loaded posts nothing and does not throw', () async {
      subscribe([slack], configured: configuredSlack);

      status('missing', WorkflowRunStatus.pending, WorkflowRunStatus.running);
      await settle();

      expect(slackThreads.sends, isEmpty);
      expect(warnings('missing'), isNotEmpty);
    });
  });
}
