import 'package:dartclaw_core/dartclaw_core.dart'
    show ChannelNotification, ChannelNotificationKind, ChannelResponse, ThreadedNotifications;
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_google_chat/src/google_chat_threaded_notifications.dart';
import 'package:dartclaw_google_chat/testing.dart';
import 'package:test/test.dart';

void main() {
  const builder = ChatCardBuilder();
  late FakeGoogleChatRestClient restClient;
  late ThreadedNotifications threaded;
  late List<({String? threadKey, String? threadName, Map<String, dynamic>? card, String? text})> sends;

  setUp(() {
    sends = [];
    restClient = FakeGoogleChatRestClient();
    threaded = GoogleChatChannel(
      config: const GoogleChatConfig(enabled: true),
      restClient: restClient,
    ).threadedNotifications!;
  });

  /// Scripts the rest client to record each send and answer with [result].
  void script(({String? messageName, String? threadName, bool usedQuotedMessageMetadata}) Function(bool card) result) {
    restClient = FakeGoogleChatRestClient(
      onSend:
          ({
            required spaceName,
            text,
            card,
            threadKey,
            threadName,
            quotedMessageName,
            quotedMessageLastUpdateTime,
            textWithoutQuote,
            fallbackOnQuoteFailure = true,
          }) async {
            sends.add((threadKey: threadKey, threadName: threadName, card: card, text: text));
            return result(card != null);
          },
    );
    threaded = GoogleChatChannel(
      config: const GoogleChatConfig(enabled: true),
      restClient: restClient,
    ).threadedNotifications!;
  }

  group('extractThread', () {
    test('reads the threadName the webhook and Pub/Sub adapter stamp', () {
      expect(threaded.extractThread({'threadName': 'spaces/AAA/threads/T1'}), 'spaces/AAA/threads/T1');
    });

    test('is null without a non-empty threadName', () {
      expect(threaded.extractThread({}), isNull);
      expect(threaded.extractThread({'threadName': ''}), isNull);
      expect(threaded.extractThread({'threadName': 42}), isNull);
      expect(threaded.extractThread({'threadId': 'spaces/AAA/threads/T1'}), isNull);
    });
  });

  group('render', () {
    test('task notification equals the task card for the same inputs, with review buttons', () {
      final createdAt = DateTime.utc(2026, 3, 13, 10);
      final updatedAt = DateTime.utc(2026, 3, 13, 11, 30);
      final response = threaded.render(
        ChannelNotification(
          kind: ChannelNotificationKind.task,
          id: 'task-1',
          text: "Task 'Fix login' needs review.",
          title: 'Fix login',
          status: 'review',
          body: 'Review the patch.',
          requestedBy: 'alice',
          createdAt: createdAt,
          updatedAt: updatedAt,
          reviewActions: true,
        ),
      );

      expect(response.text, "Task 'Fix login' needs review.");
      expect(
        response.structuredPayload,
        builder.taskNotification(
          taskId: 'task-1',
          title: 'Fix login',
          status: 'review',
          description: 'Review the patch.',
          requestedBy: 'alice',
          createdAt: createdAt,
          updatedAt: updatedAt,
          includeReviewButtons: true,
        ),
      );
    });

    test('failed task notification carries the error summary', () {
      final response = threaded.render(
        const ChannelNotification(
          kind: ChannelNotificationKind.task,
          id: 'task-2',
          text: "Task 'Build' failed: boom.",
          title: 'Build',
          status: 'failed',
          error: 'boom',
        ),
      );

      expect(
        response.structuredPayload,
        builder.taskNotification(taskId: 'task-2', title: 'Build', status: 'failed', errorSummary: 'boom'),
      );
    });

    test('falls back to the plain text, without a card, when card construction fails', () {
      final failing = GoogleChatThreadedNotifications(restClient, cards: const _ThrowingChatCardBuilder());

      final response = failing.render(
        const ChannelNotification(
          kind: ChannelNotificationKind.task,
          id: 'task-3',
          text: "Task 'Task' is now running.",
          title: 'Task',
          status: 'running',
        ),
      );

      expect(response.structuredPayload, isNull);
      expect(response.text, "Task 'Task' is now running.");
    });

    test('run notification is a card with the plain text as fallback', () {
      final response = threaded.render(
        const ChannelNotification(
          kind: ChannelNotificationKind.run,
          id: 'run-7',
          text: "Run run-7 of 'release' failed.",
          title: 'release',
          status: 'failed',
          body: 'Step build stopped.',
          error: 'exit 2',
          facts: {'Workflow': 'release', 'Run': 'run-7', 'Step': 'build'},
        ),
      );

      expect(response.text, "Run run-7 of 'release' failed.");
      expect(
        response.structuredPayload,
        builder.runNotification(
          runId: 'run-7',
          title: 'release',
          status: 'failed',
          facts: const {'Workflow': 'release', 'Run': 'run-7', 'Step': 'build'},
          body: 'Step build stopped.',
          errorSummary: 'exit 2',
        ),
      );
      final text = response.structuredPayload.toString();
      expect(text, allOf(contains('run_run-7'), contains('Step build stopped.'), contains('exit 2'), contains('Step')));
    });
  });

  group('sendToNewThread', () {
    test('passes the thread key and returns the thread and message names', () async {
      script(
        (_) => (
          messageName: 'spaces/AAA/messages/M1',
          threadName: 'spaces/AAA/threads/T1',
          usedQuotedMessageMetadata: false,
        ),
      );
      final card = builder.confirmationCard(title: 'Run', message: 'Started.');

      final post = await threaded.sendToNewThread(
        'spaces/AAA',
        ChannelResponse(text: 'Started.', structuredPayload: card),
        threadKey: 'run-1',
      );

      expect(sends.single.threadKey, 'run-1');
      expect(sends.single.threadName, isNull);
      expect(sends.single.card, card);
      expect(post?.threadId, 'spaces/AAA/threads/T1');
      expect(post?.messageId, 'spaces/AAA/messages/M1');
    });

    test('falls back to plain text when the card is refused', () async {
      script(
        (card) => card
            ? (messageName: null, threadName: null, usedQuotedMessageMetadata: false)
            : (
                messageName: 'spaces/AAA/messages/M2',
                threadName: 'spaces/AAA/threads/T2',
                usedQuotedMessageMetadata: false,
              ),
      );

      final post = await threaded.sendToNewThread(
        'spaces/AAA',
        ChannelResponse(
          text: 'Started.',
          structuredPayload: builder.confirmationCard(title: 'Run', message: 'Started.'),
        ),
        threadKey: 'run-2',
      );

      expect(sends.map((s) => s.card != null), [true, false]);
      expect(sends.last.text, 'Started.');
      expect(sends.last.threadKey, 'run-2');
      expect(post?.threadId, 'spaces/AAA/threads/T2');
    });

    test('returns null when the API returns no message name or no thread name', () async {
      script((_) => (messageName: null, threadName: null, usedQuotedMessageMetadata: false));
      expect(await threaded.sendToNewThread('spaces/AAA', const ChannelResponse(text: 'x'), threadKey: 'k'), isNull);

      script((_) => (messageName: 'spaces/AAA/messages/M3', threadName: null, usedQuotedMessageMetadata: false));
      expect(await threaded.sendToNewThread('spaces/AAA', const ChannelResponse(text: 'x'), threadKey: 'k'), isNull);
    });

    test('returns null without sending when there is nothing to deliver', () async {
      script(
        (_) => (
          messageName: 'spaces/AAA/messages/M4',
          threadName: 'spaces/AAA/threads/T4',
          usedQuotedMessageMetadata: false,
        ),
      );

      expect(await threaded.sendToNewThread('spaces/AAA', const ChannelResponse(text: ''), threadKey: 'k'), isNull);
      expect(sends, isEmpty);
    });
  });

  group('sendToThread', () {
    test('passes the thread name and returns where the message landed', () async {
      script(
        (_) => (
          messageName: 'spaces/AAA/messages/M5',
          threadName: 'spaces/AAA/threads/T5',
          usedQuotedMessageMetadata: false,
        ),
      );
      final card = builder.confirmationCard(title: 'Run', message: 'Finished.');

      final post = await threaded.sendToThread(
        'spaces/AAA',
        ChannelResponse(text: 'Finished.', structuredPayload: card),
        threadId: 'spaces/AAA/threads/T5',
      );

      expect(sends.single.threadName, 'spaces/AAA/threads/T5');
      expect(sends.single.threadKey, isNull);
      expect(post?.threadId, 'spaces/AAA/threads/T5');
      expect(post?.messageId, 'spaces/AAA/messages/M5');
    });

    test('returns null when the API returns none', () async {
      script((_) => (messageName: null, threadName: null, usedQuotedMessageMetadata: false));

      expect(
        await threaded.sendToThread('spaces/AAA', const ChannelResponse(text: 'x'), threadId: 'spaces/AAA/threads/T5'),
        isNull,
      );
    });
  });
}

class _ThrowingChatCardBuilder extends ChatCardBuilder {
  const new();

  @override
  Map<String, dynamic> taskNotification({
    required String taskId,
    required String title,
    required String status,
    String? description,
    String? errorSummary,
    String? requestedBy,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool includeReviewButtons = false,
  }) {
    throw StateError('boom');
  }
}
