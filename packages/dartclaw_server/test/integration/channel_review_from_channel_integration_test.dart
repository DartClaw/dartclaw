import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  late TaskService tasks;
  late EventBus eventBus;
  late _RecordingMessageQueue queue;
  late FakeChannel channel;
  late _RecordingMergeExecutor mergeExecutor;
  late _RecordingWorktreeManager worktreeManager;
  late _RecordingTaskFileGuard taskFileGuard;
  late TaskReviewService reviewService;
  late ChannelManager manager;
  late TaskNotificationSubscriber notificationSubscriber;

  setUp(() {
    eventBus = EventBus();
    tasks = TaskService(SqliteTaskRepository(openTaskDbInMemory()), eventBus: eventBus);
    queue = _RecordingMessageQueue();
    channel = FakeChannel(ownedJids: {'sender@s.whatsapp.net'});
    mergeExecutor = _RecordingMergeExecutor(
      result: const MergeSuccess(commitSha: 'abc123', commitMessage: 'task(task-1): Fix login'),
    );
    worktreeManager = _RecordingWorktreeManager();
    taskFileGuard = _RecordingTaskFileGuard();
    reviewService = TaskReviewService(
      tasks: tasks,
      mergeExecutor: mergeExecutor,
      worktreeManager: worktreeManager,
      taskFileGuard: taskFileGuard,
    );
    manager = ChannelManager(
      queue: queue,
      config: const ChannelConfig.defaults(),
      taskBridge: ChannelTaskBridge(
        taskCreator: tasks.create,
        taskLister: tasks.list,
        reviewCommandParser: const ReviewCommandParser(),
        reviewHandler: reviewService.channelReviewHandler(trigger: 'channel'),
        triggerParser: const TaskTriggerParser(),
        taskTriggerConfigs: const {ChannelType.whatsapp: TaskTriggerConfig(enabled: true)},
      ),
    );
    manager.registerChannel(channel);
    notificationSubscriber = TaskNotificationSubscriber(tasks: tasks, channelManager: manager);
    notificationSubscriber.subscribe(eventBus);
  });

  tearDown(() async {
    await notificationSubscriber.dispose();
    await manager.dispose();
    await eventBus.dispose();
    await tasks.dispose();
  });

  test('accept from channel preserves provenance, notifies origin, and replies with confirmation', () async {
    final task = await _putTaskInReview(
      tasks,
      'task-1',
      title: 'Fix login',
      configJson: {
        'origin': TaskOrigin(
          channelType: ChannelType.whatsapp.name,
          sessionKey: SessionKey.dmPerChannelContact(
            channelType: ChannelType.whatsapp.name,
            peerId: 'sender@s.whatsapp.net',
          ),
          recipientId: 'sender@s.whatsapp.net',
          contactId: 'sender@s.whatsapp.net',
          sourceMessageId: 'msg-1',
        ).toJson(),
      },
    );
    taskFileGuard.register(task.id, '/tmp/worktree');

    // Subscribe after setup — only capture the review→accepted transition from the channel handler.
    final statusEvents = <TaskStatusChangedEvent>[];
    final statusSub = eventBus.on<TaskStatusChangedEvent>().listen(statusEvents.add);
    addTearDown(statusSub.cancel);

    manager.handleInboundMessage(
      ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'sender@s.whatsapp.net', text: 'accept'),
    );
    await _flushAsync();

    final updated = await tasks.get(task.id);
    expect(updated!.status, TaskStatus.accepted);
    expect(mergeExecutor.callCount, 1);
    expect(worktreeManager.cleanedTaskIds, [task.id]);
    expect(taskFileGuard.deregisteredTaskIds, [task.id]);
    expect(queue.enqueued, isEmpty);
    expect(statusEvents, hasLength(1));
    expect(statusEvents.single.trigger, 'channel');
    expect(channel.sentMessages.map((message) => message.$1), everyElement('sender@s.whatsapp.net'));
    expect(channel.sentMessages.map((message) => message.$2.text), contains("Task 'Fix login' accepted."));
    expect(
      channel.sentMessages.map((message) => message.$2.text),
      contains("Task 'Fix login' accepted. Changes merged."),
    );
  });
}

Future<Task> _putTaskInReview(
  TaskService tasks,
  String id, {
  required String title,
  Map<String, dynamic>? configJson,
}) async {
  await tasks.create(
    id: id,
    title: title,
    description: title,
    type: TaskType.coding,
    autoStart: true,
    configJson: configJson ?? const {},
    now: DateTime.parse('2026-03-13T10:00:00Z'),
  );
  await tasks.transition(id, TaskStatus.running, now: DateTime.parse('2026-03-13T10:05:00Z'));
  await tasks.transition(id, TaskStatus.review, now: DateTime.parse('2026-03-13T10:10:00Z'));
  return tasks.updateFields(
    id,
    worktreeJson: const {
      'path': '/tmp/worktree',
      'branch': 'dartclaw/task-task-1',
      'createdAt': '2026-03-13T10:00:00.000Z',
    },
  );
}

Future<void> _flushAsync() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(const Duration(milliseconds: 10));
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

class _RecordingMergeExecutor extends MergeExecutor {
  final MergeResult result;
  int callCount = 0;

  _RecordingMergeExecutor({required this.result}) : super(projectDir: '.');

  @override
  Future<MergeResult> merge({
    required String branch,
    required String baseRef,
    required String taskId,
    required String taskTitle,
    MergeStrategy? strategy,
  }) async {
    callCount += 1;
    return result;
  }
}

class _RecordingWorktreeManager extends WorktreeManager {
  final List<String> cleanedTaskIds = [];

  _RecordingWorktreeManager() : super(dataDir: '/tmp', projectDir: '/tmp');

  @override
  Future<void> cleanup(String taskId, {Project? project}) async {
    cleanedTaskIds.add(taskId);
  }
}

class _RecordingTaskFileGuard extends TaskFileGuard {
  final List<String> deregisteredTaskIds = [];

  @override
  void deregister(String taskId) {
    deregisteredTaskIds.add(taskId);
    super.deregister(taskId);
  }
}
