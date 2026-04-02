import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart'
    show FakeChannel, InMemoryTaskRepository, RecordingReviewHandler, TaskOps, putTaskInReview;
import 'package:test/test.dart';

void main() {
  group('ChannelTaskBridge — bound task (thread commands)', () {
    late FakeChannel channel;
    late InMemoryTaskRepository repo;
    late TaskOps tasks;
    late RecordingReviewHandler reviewHandler;

    setUp(() {
      channel = FakeChannel(ownedJids: {'sender@s.whatsapp.net'});
      repo = InMemoryTaskRepository();
      tasks = TaskOps(repo);
      reviewHandler = RecordingReviewHandler();
    });

    tearDown(() => tasks.dispose());

    ChannelTaskBridge buildBridge() {
      return ChannelTaskBridge(
        taskLister: tasks.list,
        reviewCommandParser: const ReviewCommandParser(),
        reviewHandler: reviewHandler.call,
      );
    }

    ChannelMessage makeMessage(String text) {
      return ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'sender@s.whatsapp.net', text: text);
    }

    test('bare accept with boundTaskId targets bound task even when nothing else is in review', () async {
      // No tasks in review via the normal listing — only the bound task.
      final task = await putTaskInReview(tasks, 'abc12300-0000-0000-0000-000000000000', title: 'Fix login');
      reviewHandler.result = const ChannelReviewSuccess(taskTitle: 'Fix login', action: 'accept');
      final bridge = buildBridge();

      final handled = await bridge.tryHandle(makeMessage('accept'), channel, sessionKey: 'key', boundTaskId: task.id);

      expect(handled, isTrue);
      expect(reviewHandler.calls, [(task.id, 'accept')]);
      expect(channel.sentMessages.single.$2.text, "Task 'Fix login' accepted.");
    });

    test('bare reject with boundTaskId targets bound task', () async {
      final task = await putTaskInReview(tasks, 'abc12300-0000-0000-0000-000000000000', title: 'Fix login');
      reviewHandler.result = const ChannelReviewSuccess(taskTitle: 'Fix login', action: 'reject');
      final bridge = buildBridge();

      final handled = await bridge.tryHandle(makeMessage('reject'), channel, sessionKey: 'key', boundTaskId: task.id);

      expect(handled, isTrue);
      expect(reviewHandler.calls, [(task.id, 'reject')]);
      expect(channel.sentMessages.single.$2.text, "Task 'Fix login' rejected.");
    });

    test('push back with boundTaskId targets bound task and passes comment', () async {
      final task = await putTaskInReview(tasks, 'abc12300-0000-0000-0000-000000000000', title: 'Fix login');
      reviewHandler.result = const ChannelReviewSuccess(taskTitle: 'Fix login', action: 'push_back');
      final bridge = buildBridge();

      final handled = await bridge.tryHandle(
        makeMessage('push back: add more tests please'),
        channel,
        sessionKey: 'key',
        boundTaskId: task.id,
      );

      expect(handled, isTrue);
      expect(reviewHandler.calls.single.$1, task.id);
      expect(reviewHandler.calls.single.$2, 'push_back');
      expect(reviewHandler.capturedComments.single, 'add more tests please');
      expect(channel.sentMessages.single.$2.text, "Task 'Fix login' pushed back with feedback.");
    });

    test('explicit task id in command overrides boundTaskId', () async {
      final taskA = await putTaskInReview(tasks, 'abc12300-0000-0000-0000-000000000000', title: 'Fix login');
      final taskB = await putTaskInReview(tasks, 'def45600-0000-0000-0000-000000000000', title: 'Update docs');
      reviewHandler.result = const ChannelReviewSuccess(taskTitle: 'Update docs', action: 'accept');
      final bridge = buildBridge();

      // boundTaskId points to taskA, but explicit id in message points to taskB.
      final handled = await bridge.tryHandle(
        makeMessage('accept def456'),
        channel,
        sessionKey: 'key',
        boundTaskId: taskA.id,
      );

      expect(handled, isTrue);
      expect(reviewHandler.calls, [(taskB.id, 'accept')]);
    });

    test('returns false for bare accept with no boundTaskId when nothing is in review', () async {
      final bridge = buildBridge();

      final handled = await bridge.tryHandle(
        makeMessage('accept'),
        channel,
        sessionKey: 'key',
        // no boundTaskId
      );

      expect(handled, isFalse);
    });

    test('boundTaskId does not affect non-review messages', () async {
      final task = await putTaskInReview(tasks, 'abc12300-0000-0000-0000-000000000000', title: 'Fix login');
      final bridge = buildBridge();

      final handled = await bridge.tryHandle(
        makeMessage('hello there'),
        channel,
        sessionKey: 'key',
        boundTaskId: task.id,
      );

      expect(handled, isFalse);
      expect(reviewHandler.calls, isEmpty);
    });
  });
}
