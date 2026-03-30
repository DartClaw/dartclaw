import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeChannel, InMemoryTaskRepository;
import 'package:test/test.dart';

void main() {
  group('ChannelManager review intercept', () {
    late _RecordingMessageQueue queue;
    late FakeChannel channel;
    late InMemoryTaskRepository repo;
    late _TaskOps tasks;
    late _RecordingReviewHandler reviewHandler;
    late ChannelManager manager;
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('channel_manager_review_test_');
      queue = _RecordingMessageQueue();
      channel = FakeChannel(ownedJids: {'sender@s.whatsapp.net'});
      repo = InMemoryTaskRepository();
      tasks = _TaskOps(repo);
      reviewHandler = _RecordingReviewHandler();
      manager = ChannelManager(
        queue: queue,
        config: const ChannelConfig.defaults(),
        taskBridge: ChannelTaskBridge(
          taskLister: tasks.list,
          reviewCommandParser: const ReviewCommandParser(),
          reviewHandler: reviewHandler.call,
          triggerParser: const TaskTriggerParser(),
          taskTriggerConfigs: const {ChannelType.whatsapp: TaskTriggerConfig(enabled: true)},
        ),
      );
      manager.registerChannel(channel);
    });

    tearDown(() async {
      await manager.dispose();
      await tasks.dispose();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('accepts a single review task without enqueueing', () async {
      final task = await _putTaskInReview(tasks, 'abc12300-0000-0000-0000-000000000000', title: 'Fix login');
      reviewHandler.result = const ChannelReviewSuccess(taskTitle: 'Fix login', action: 'accept');

      manager.handleInboundMessage(
        ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'sender@s.whatsapp.net', text: 'accept'),
      );
      await _flushAsync();

      expect(queue.enqueued, isEmpty);
      expect(reviewHandler.calls, [(task.id, 'accept')]);
      expect(channel.sentMessages.single.$2.text, "Task 'Fix login' accepted.");
    });

    test('treats bare accept as a normal message when nothing is in review', () async {
      manager.handleInboundMessage(
        ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'sender@s.whatsapp.net', text: 'accept'),
      );
      await _flushAsync();

      expect(queue.enqueued, hasLength(1));
      expect(reviewHandler.calls, isEmpty);
      expect(channel.sentMessages, isEmpty);
    });

    test('resolves explicit short ids for review tasks', () async {
      final task = await _putTaskInReview(tasks, 'abc12300-0000-0000-0000-000000000000', title: 'Fix login');

      manager.handleInboundMessage(
        ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'sender@s.whatsapp.net', text: 'accept abc123'),
      );
      await _flushAsync();

      expect(reviewHandler.calls, [(task.id, 'accept')]);
      expect(queue.enqueued, isEmpty);
    });

    test('resolves explicit full ids for review tasks', () async {
      final task = await _putTaskInReview(tasks, 'abc12300-0000-0000-0000-000000000000', title: 'Fix login');

      manager.handleInboundMessage(
        ChannelMessage(
          channelType: ChannelType.whatsapp,
          senderJid: 'sender@s.whatsapp.net',
          text: 'accept abc12300-0000-0000-0000-000000000000',
        ),
      );
      await _flushAsync();

      expect(reviewHandler.calls, [(task.id, 'accept')]);
      expect(queue.enqueued, isEmpty);
    });

    test('replies when explicit id does not exist', () async {
      manager.handleInboundMessage(
        ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'sender@s.whatsapp.net', text: 'accept abc123'),
      );
      await _flushAsync();

      expect(queue.enqueued, isEmpty);
      expect(reviewHandler.calls, isEmpty);
      expect(channel.sentMessages.single.$2.text, 'No task found with ID abc123.');
    });

    test('replies when explicit id matches a task outside review', () async {
      await _createTask(tasks, 'abc12300-0000-0000-0000-000000000000', title: 'Fix login', status: TaskStatus.draft);

      manager.handleInboundMessage(
        ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'sender@s.whatsapp.net', text: 'accept abc123'),
      );
      await _flushAsync();

      expect(reviewHandler.calls, isEmpty);
      expect(channel.sentMessages.single.$2.text, 'Task abc123 is not in review (current status: draft).');
    });

    test('prompts for disambiguation when multiple tasks are in review', () async {
      await _putTaskInReview(tasks, 'abc12300-0000-0000-0000-000000000000', title: 'Fix login');
      await _putTaskInReview(tasks, 'def45600-0000-0000-0000-000000000000', title: 'Update docs');

      manager.handleInboundMessage(
        ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'sender@s.whatsapp.net', text: 'accept'),
      );
      await _flushAsync();

      expect(reviewHandler.calls, isEmpty);
      expect(queue.enqueued, isEmpty);
      expect(
        channel.sentMessages.single.$2.text,
        "Multiple tasks in review:\nabc123: Fix login\ndef456: Update docs\nReply 'accept <id>' to specify.",
      );
    });

    test('expands listing ids when review task prefixes collide', () async {
      await _putTaskInReview(tasks, 'abc12300-0000-0000-0000-000000000000', title: 'Fix login');
      await _putTaskInReview(tasks, 'abc12311-0000-0000-0000-000000000000', title: 'Update docs');

      manager.handleInboundMessage(
        ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'sender@s.whatsapp.net', text: 'accept'),
      );
      await _flushAsync();

      expect(reviewHandler.calls, isEmpty);
      expect(queue.enqueued, isEmpty);
      expect(
        channel.sentMessages.single.$2.text,
        "Multiple tasks in review:\nabc1230: Fix login\nabc1231: Update docs\nReply 'accept <id>' to specify.",
      );
    });

    test('does not intercept part-of-sentence occurrences', () async {
      await _putTaskInReview(tasks, 'abc12300-0000-0000-0000-000000000000', title: 'Fix login');

      manager.handleInboundMessage(
        ChannelMessage(
          channelType: ChannelType.whatsapp,
          senderJid: 'sender@s.whatsapp.net',
          text: 'I accept that approach',
        ),
      );
      await _flushAsync();

      expect(queue.enqueued, hasLength(1));
      expect(reviewHandler.calls, isEmpty);
      expect(channel.sentMessages, isEmpty);
    });

    test('supports reject confirmations', () async {
      await _putTaskInReview(tasks, 'abc12300-0000-0000-0000-000000000000', title: 'Fix login');
      reviewHandler.result = const ChannelReviewSuccess(taskTitle: 'Fix login', action: 'reject');

      manager.handleInboundMessage(
        ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'sender@s.whatsapp.net', text: 'reject'),
      );
      await _flushAsync();

      expect(reviewHandler.calls.single.$2, 'reject');
      expect(channel.sentMessages.single.$2.text, "Task 'Fix login' rejected.");
    });

    test('surfaces merge conflicts from the review handler', () async {
      await _putTaskInReview(tasks, 'abc12300-0000-0000-0000-000000000000', title: 'Fix login');
      reviewHandler.result = const ChannelReviewMergeConflict(taskTitle: 'Fix login');

      manager.handleInboundMessage(
        ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'sender@s.whatsapp.net', text: 'accept'),
      );
      await _flushAsync();

      expect(channel.sentMessages.single.$2.text, "Task 'Fix login' has merge conflicts. Review in web UI.");
    });

    test('surfaces review errors from the review handler', () async {
      await _putTaskInReview(tasks, 'abc12300-0000-0000-0000-000000000000', title: 'Fix login');
      reviewHandler.result = const ChannelReviewError('Task abc123 is not in review (current status: accepted).');

      manager.handleInboundMessage(
        ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'sender@s.whatsapp.net', text: 'accept'),
      );
      await _flushAsync();

      expect(channel.sentMessages.single.$2.text, 'Task abc123 is not in review (current status: accepted).');
    });

    test('sanitizes raw review action failures from the review handler', () async {
      await _putTaskInReview(tasks, 'abc12300-0000-0000-0000-000000000000', title: 'Fix login');
      reviewHandler.result = const ChannelReviewError('Could not accept task: merge exploded');

      manager.handleInboundMessage(
        ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'sender@s.whatsapp.net', text: 'accept'),
      );
      await _flushAsync();

      expect(channel.sentMessages.single.$2.text, 'Review action failed. Please try again or use the web UI.');
    });

    test('leaves messages alone when the review parser is not wired', () async {
      manager = ChannelManager(
        queue: queue,
        config: const ChannelConfig.defaults(),
        taskBridge: ChannelTaskBridge(
          taskLister: tasks.list,
          triggerParser: const TaskTriggerParser(),
          taskTriggerConfigs: const {ChannelType.whatsapp: TaskTriggerConfig(enabled: true)},
        ),
      );
      manager.registerChannel(channel);

      manager.handleInboundMessage(
        ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'sender@s.whatsapp.net', text: 'accept'),
      );
      await _flushAsync();

      expect(queue.enqueued, hasLength(1));
      expect(reviewHandler.calls, isEmpty);
    });

    test('review intercept takes precedence over task triggers', () async {
      final existing = await _putTaskInReview(tasks, 'abc12300-0000-0000-0000-000000000000', title: 'Fix login');
      manager = ChannelManager(
        queue: queue,
        config: const ChannelConfig.defaults(),
        taskBridge: ChannelTaskBridge(
          taskLister: tasks.list,
          reviewCommandParser: const ReviewCommandParser(),
          reviewHandler: reviewHandler.call,
          triggerParser: const _AlwaysTriggerParser(),
          taskTriggerConfigs: const {ChannelType.whatsapp: TaskTriggerConfig(enabled: true)},
        ),
      );
      manager.registerChannel(channel);

      manager.handleInboundMessage(
        ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'sender@s.whatsapp.net', text: 'accept'),
      );
      await _flushAsync();

      expect(reviewHandler.calls, [(existing.id, 'accept')]);
      expect((await tasks.list()), hasLength(1));
      expect(queue.enqueued, isEmpty);
    });

    test('bound thread accept targets the bound task without enqueueing', () async {
      final task = await _putTaskInReview(tasks, 'abc12300-0000-0000-0000-000000000000', title: 'Fix login');
      reviewHandler.result = const ChannelReviewSuccess(taskTitle: 'Fix login', action: 'accept');

      final threadBindings = ThreadBindingStore(File('${tempDir.path}/thread-bindings.json'));
      await threadBindings.load();
      await threadBindings.create(
        ThreadBinding(
          channelType: ChannelType.googlechat.name,
          threadId: 'spaces/AAAA/threads/THREAD-1',
          taskId: task.id,
          sessionKey: 'bound-session-key',
          createdAt: DateTime.parse('2026-03-21T10:00:00Z'),
          lastActivity: DateTime.parse('2026-03-21T10:00:00Z'),
        ),
      );

      manager = ChannelManager(
        queue: queue,
        config: const ChannelConfig.defaults(),
        taskBridge: ChannelTaskBridge(
          taskLister: tasks.list,
          reviewCommandParser: const ReviewCommandParser(),
          reviewHandler: reviewHandler.call,
          triggerParser: const TaskTriggerParser(),
          taskTriggerConfigs: const {ChannelType.googlechat: TaskTriggerConfig(enabled: true)},
          threadBindings: threadBindings,
          threadBindingEnabled: true,
        ),
      );
      channel = FakeChannel(ownedJids: {'users/123', 'spaces/AAAA'}, type: ChannelType.googlechat);
      manager.registerChannel(channel);

      manager.handleInboundMessage(
        ChannelMessage(
          channelType: ChannelType.googlechat,
          senderJid: 'users/123',
          groupJid: 'spaces/AAAA',
          text: 'accept',
          metadata: const {'spaceName': 'spaces/AAAA', 'threadName': 'spaces/AAAA/threads/THREAD-1'},
        ),
      );
      await _flushAsync();

      expect(reviewHandler.calls, [(task.id, 'accept')]);
      expect(queue.enqueued, isEmpty);
      expect(channel.sentMessages.single.$2.text, "Task 'Fix login' accepted.");
    });
  });
}

Future<Task> _createTask(_TaskOps tasks, String id, {required String title, required TaskStatus status}) async {
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
  if (status == TaskStatus.running) {
    return current;
  }
  if (status == TaskStatus.review) {
    return tasks.transition(id, TaskStatus.review, now: DateTime.parse('2026-03-13T10:10:00Z'));
  }
  throw UnimplementedError('Unsupported status for test helper: $status');
}

Future<Task> _putTaskInReview(_TaskOps tasks, String id, {required String title}) {
  return _createTask(tasks, id, title: title, status: TaskStatus.review);
}

Future<void> _flushAsync() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

class _AlwaysTriggerParser extends TaskTriggerParser {
  const _AlwaysTriggerParser();

  @override
  TaskTriggerResult? parse(String message, TaskTriggerConfig config, {bool emptyDescriptionError = false}) {
    if (message.trim().toLowerCase() != 'accept') {
      return null;
    }
    return const TaskTriggerResult(description: 'should not run', type: TaskType.research, autoStart: true);
  }
}

class _RecordingMessageQueue extends MessageQueue {
  final List<(ChannelMessage, Channel, String)> enqueued = [];

  _RecordingMessageQueue() : super(dispatcher: (sessionKey, message, {senderJid, senderDisplayName}) async => 'ok');

  @override
  void enqueue(ChannelMessage message, Channel sourceChannel, String sessionKey) {
    enqueued.add((message, sourceChannel, sessionKey));
  }

  @override
  void dispose() {}
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
    final task = await _repo.getById(taskId);
    if (task == null) {
      throw ArgumentError('Task not found: $taskId');
    }

    final transitioned = task.transition(newStatus, now: now);
    final persisted = task.copyWith(
      status: transitioned.status,
      configJson: configJson ?? transitioned.configJson,
      startedAt: transitioned.startedAt,
      completedAt: transitioned.completedAt,
    );
    final updated = await _repo.updateIfStatus(persisted, expectedStatus: task.status);
    if (!updated) {
      throw StateError('Task status changed concurrently.');
    }
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
