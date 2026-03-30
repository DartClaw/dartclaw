import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeChannel, InMemoryTaskRepository;
import 'package:test/test.dart';

void main() {
  group('ChannelTaskBridge — review commands', () {
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

    ChannelTaskBridge buildBridge({bool withReview = true, bool withTrigger = false}) {
      return ChannelTaskBridge(
        taskLister: tasks.list,
        reviewCommandParser: withReview ? const ReviewCommandParser() : null,
        reviewHandler: withReview ? reviewHandler.call : null,
        triggerParser: withTrigger ? const TaskTriggerParser() : null,
        taskTriggerConfigs:
            withTrigger ? const {ChannelType.whatsapp: TaskTriggerConfig(enabled: true)} : const {},
      );
    }

    ChannelMessage makeMessage(String text) {
      return ChannelMessage(
        channelType: ChannelType.whatsapp,
        senderJid: 'sender@s.whatsapp.net',
        text: text,
      );
    }

    test('accepts a single review task and returns true', () async {
      final task = await _putTaskInReview(tasks, 'abc12300-0000-0000-0000-000000000000', title: 'Fix login');
      reviewHandler.result = const ChannelReviewSuccess(taskTitle: 'Fix login', action: 'accept');
      final bridge = buildBridge();

      final handled = await bridge.tryHandle(makeMessage('accept'), channel, sessionKey: 'key');

      expect(handled, isTrue);
      expect(reviewHandler.calls, [(task.id, 'accept')]);
      expect(channel.sentMessages.single.$2.text, "Task 'Fix login' accepted.");
    });

    test('returns false for bare accept when nothing is in review', () async {
      final bridge = buildBridge();

      final handled = await bridge.tryHandle(makeMessage('accept'), channel, sessionKey: 'key');

      expect(handled, isFalse);
      expect(reviewHandler.calls, isEmpty);
      expect(channel.sentMessages, isEmpty);
    });

    test('resolves explicit short ids', () async {
      final task = await _putTaskInReview(tasks, 'abc12300-0000-0000-0000-000000000000', title: 'Fix login');
      reviewHandler.result = const ChannelReviewSuccess(taskTitle: 'Fix login', action: 'accept');
      final bridge = buildBridge();

      final handled = await bridge.tryHandle(makeMessage('accept abc123'), channel, sessionKey: 'key');

      expect(handled, isTrue);
      expect(reviewHandler.calls, [(task.id, 'accept')]);
    });

    test('prompts disambiguation when multiple tasks in review', () async {
      await _putTaskInReview(tasks, 'abc12300-0000-0000-0000-000000000000', title: 'Fix login');
      await _putTaskInReview(tasks, 'def45600-0000-0000-0000-000000000000', title: 'Update docs');
      final bridge = buildBridge();

      final handled = await bridge.tryHandle(makeMessage('accept'), channel, sessionKey: 'key');

      expect(handled, isTrue);
      expect(reviewHandler.calls, isEmpty);
      expect(
        channel.sentMessages.single.$2.text,
        "Multiple tasks in review:\nabc123: Fix login\ndef456: Update docs\nReply 'accept <id>' to specify.",
      );
    });

    test('returns false when review parser is not wired', () async {
      await _putTaskInReview(tasks, 'abc12300-0000-0000-0000-000000000000', title: 'Fix login');
      final bridge = buildBridge(withReview: false);

      final handled = await bridge.tryHandle(makeMessage('accept'), channel, sessionKey: 'key');

      expect(handled, isFalse);
      expect(channel.sentMessages, isEmpty);
    });

    test('sanitizes raw review action failures', () async {
      await _putTaskInReview(tasks, 'abc12300-0000-0000-0000-000000000000', title: 'Fix login');
      reviewHandler.result = const ChannelReviewError('Could not accept task: merge exploded');
      final bridge = buildBridge();

      await bridge.tryHandle(makeMessage('accept'), channel, sessionKey: 'key');

      expect(channel.sentMessages.single.$2.text, 'Review action failed. Please try again or use the web UI.');
    });

    test('surfaces merge conflicts', () async {
      await _putTaskInReview(tasks, 'abc12300-0000-0000-0000-000000000000', title: 'Fix login');
      reviewHandler.result = const ChannelReviewMergeConflict(taskTitle: 'Fix login');
      final bridge = buildBridge();

      await bridge.tryHandle(makeMessage('accept'), channel, sessionKey: 'key');

      expect(channel.sentMessages.single.$2.text, "Task 'Fix login' has merge conflicts. Review in web UI.");
    });

    test('review commands take precedence over task triggers', () async {
      final task = await _putTaskInReview(tasks, 'abc12300-0000-0000-0000-000000000000', title: 'Fix login');
      reviewHandler.result = const ChannelReviewSuccess(taskTitle: 'Fix login', action: 'accept');
      final bridge = buildBridge(withReview: true, withTrigger: true);

      final handled = await bridge.tryHandle(makeMessage('accept'), channel, sessionKey: 'key');

      expect(handled, isTrue);
      expect(reviewHandler.calls, [(task.id, 'accept')]);
      expect(await tasks.list(), hasLength(1));
    });
  });
}

Future<Task> _createTask(
  _TaskOps tasks,
  String id, {
  required String title,
  required TaskStatus status,
}) async {
  final task = await tasks.create(
    id: id,
    title: title,
    description: title,
    type: TaskType.research,
    autoStart: status != TaskStatus.draft,
    now: DateTime.parse('2026-03-13T10:00:00Z'),
  );
  if (status == TaskStatus.draft || status == TaskStatus.queued) {
    return task;
  }
  var current = task;
  if (current.status == TaskStatus.queued && status.index >= TaskStatus.running.index) {
    current = await tasks.transition(id, TaskStatus.running, now: DateTime.parse('2026-03-13T10:05:00Z'));
  }
  if (status == TaskStatus.review) {
    return tasks.transition(id, TaskStatus.review, now: DateTime.parse('2026-03-13T10:10:00Z'));
  }
  return current;
}

Future<Task> _putTaskInReview(_TaskOps tasks, String id, {required String title}) {
  return _createTask(tasks, id, title: title, status: TaskStatus.review);
}

class _TaskOps {
  final InMemoryTaskRepository _repo;

  _TaskOps(this._repo);

  Future<Task> create({
    required String id,
    required String title,
    required String description,
    required TaskType type,
    bool autoStart = false,
    String? goalId,
    String? acceptanceCriteria,
    String? createdBy,
    String? projectId,
    Map<String, dynamic> configJson = const {},
    DateTime? now,
    String trigger = 'system',
  }) async {
    final timestamp = now ?? DateTime.now();
    var task = Task(
      id: id,
      title: title,
      description: description,
      type: type,
      goalId: goalId,
      acceptanceCriteria: acceptanceCriteria,
      createdBy: createdBy,
      configJson: configJson,
      createdAt: timestamp,
    );
    if (autoStart) {
      task = task.transition(TaskStatus.queued, now: timestamp);
    }
    await _repo.insert(task);
    return task;
  }

  Future<List<Task>> list({TaskStatus? status, TaskType? type}) => _repo.list(status: status, type: type);

  Future<Task> transition(
    String taskId,
    TaskStatus newStatus, {
    DateTime? now,
    Map<String, dynamic>? configJson,
  }) async {
    final task = (await _repo.getById(taskId))!;
    final transitioned = task.transition(newStatus, now: now);
    final persisted = task.copyWith(
      status: transitioned.status,
      configJson: configJson ?? transitioned.configJson,
      startedAt: transitioned.startedAt,
      completedAt: transitioned.completedAt,
    );
    await _repo.updateIfStatus(persisted, expectedStatus: task.status);
    return persisted;
  }

  Future<void> dispose() => _repo.dispose();
}

class _RecordingReviewHandler {
  final List<(String, String)> calls = [];
  ChannelReviewResult result = const ChannelReviewSuccess(taskTitle: 'Fix login', action: 'accept');

  Future<ChannelReviewResult> call(String taskId, String action, {String? comment}) async {
    calls.add((taskId, action));
    return result;
  }
}
