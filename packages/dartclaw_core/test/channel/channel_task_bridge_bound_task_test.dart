import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeChannel, InMemoryTaskRepository;
import 'package:test/test.dart';

void main() {
  group('ChannelTaskBridge — bound task (thread commands)', () {
    late FakeChannel channel;
    late InMemoryTaskRepository repo;
    late _TaskOps tasks;
    late _RecordingReviewHandler reviewHandler;

    setUp(() {
      channel = FakeChannel(ownedJids: {'sender@s.whatsapp.net'});
      repo = InMemoryTaskRepository();
      tasks = _TaskOps(repo);
      reviewHandler = _RecordingReviewHandler();
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
      return ChannelMessage(
        channelType: ChannelType.whatsapp,
        senderJid: 'sender@s.whatsapp.net',
        text: text,
      );
    }

    Future<Task> putTaskInReview(String id, {required String title}) async {
      final now = DateTime.parse('2026-03-21T10:00:00Z');
      var task = Task(
        id: id,
        title: title,
        description: title,
        type: TaskType.research,
        createdAt: now,
      );
      task = task.transition(TaskStatus.queued, now: now);
      task = task.transition(TaskStatus.running, now: now);
      task = task.transition(TaskStatus.review, now: now);
      await repo.insert(task);
      return task;
    }

    test('bare accept with boundTaskId targets bound task even when nothing else is in review', () async {
      // No tasks in review via the normal listing — only the bound task.
      final task = await putTaskInReview('abc12300-0000-0000-0000-000000000000', title: 'Fix login');
      reviewHandler.result = const ChannelReviewSuccess(taskTitle: 'Fix login', action: 'accept');
      final bridge = buildBridge();

      final handled = await bridge.tryHandle(
        makeMessage('accept'),
        channel,
        sessionKey: 'key',
        boundTaskId: task.id,
      );

      expect(handled, isTrue);
      expect(reviewHandler.calls, [(task.id, 'accept')]);
      expect(channel.sentMessages.single.$2.text, "Task 'Fix login' accepted.");
    });

    test('bare reject with boundTaskId targets bound task', () async {
      final task = await putTaskInReview('abc12300-0000-0000-0000-000000000000', title: 'Fix login');
      reviewHandler.result = const ChannelReviewSuccess(taskTitle: 'Fix login', action: 'reject');
      final bridge = buildBridge();

      final handled = await bridge.tryHandle(
        makeMessage('reject'),
        channel,
        sessionKey: 'key',
        boundTaskId: task.id,
      );

      expect(handled, isTrue);
      expect(reviewHandler.calls, [(task.id, 'reject')]);
      expect(channel.sentMessages.single.$2.text, "Task 'Fix login' rejected.");
    });

    test('push back with boundTaskId targets bound task and passes comment', () async {
      final task = await putTaskInReview('abc12300-0000-0000-0000-000000000000', title: 'Fix login');
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
      final taskA = await putTaskInReview('abc12300-0000-0000-0000-000000000000', title: 'Fix login');
      final taskB = await putTaskInReview('def45600-0000-0000-0000-000000000000', title: 'Update docs');
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
      final task = await putTaskInReview('abc12300-0000-0000-0000-000000000000', title: 'Fix login');
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

class _TaskOps {
  final InMemoryTaskRepository _repo;

  _TaskOps(this._repo);

  Future<List<Task>> list({TaskStatus? status, TaskType? type}) => _repo.list(status: status, type: type);

  Future<void> dispose() => _repo.dispose();
}

class _RecordingReviewHandler {
  final List<(String, String)> calls = [];
  final List<String?> capturedComments = [];
  ChannelReviewResult result = const ChannelReviewSuccess(taskTitle: 'Fix login', action: 'accept');

  Future<ChannelReviewResult> call(String taskId, String action, {String? comment}) async {
    calls.add((taskId, action));
    capturedComments.add(comment);
    return result;
  }
}
