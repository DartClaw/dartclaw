import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  late TaskService tasks;
  late EventBus eventBus;

  setUp(() {
    db = openTaskDbInMemory();
    eventBus = EventBus();
    tasks = TaskService(SqliteTaskRepository(db), eventBus: eventBus);
  });

  tearDown(() async {
    await eventBus.dispose();
    await tasks.dispose();
    db.close();
  });

  group('TaskReviewService', () {
    test('accepts review tasks and fires status events', () async {
      await _putTaskInReview(tasks, 'task-1', title: 'Fix login');
      final service = TaskReviewService(tasks: tasks, eventBus: eventBus);
      final statusEvents = <TaskStatusChangedEvent>[];
      final reviewReadyEvents = <TaskReviewReadyEvent>[];
      final statusSub = eventBus.on<TaskStatusChangedEvent>().listen(statusEvents.add);
      final readySub = eventBus.on<TaskReviewReadyEvent>().listen(reviewReadyEvents.add);
      addTearDown(statusSub.cancel);
      addTearDown(readySub.cancel);

      final result = await service.review('task-1', 'accept');
      await Future<void>.delayed(Duration.zero);

      expect(result, const TypeMatcher<ReviewSuccess>());
      expect((result as ReviewSuccess).task.status, TaskStatus.accepted);
      expect((await tasks.get('task-1'))!.status, TaskStatus.accepted);
      expect(statusEvents, hasLength(1));
      expect(statusEvents.single.oldStatus, TaskStatus.review);
      expect(statusEvents.single.newStatus, TaskStatus.accepted);
      expect(statusEvents.single.trigger, 'user');
      expect(reviewReadyEvents, isEmpty);
    });

    test('channel review handler preserves channel provenance', () async {
      await _putTaskInReview(tasks, 'task-1', title: 'Fix login');
      final service = TaskReviewService(tasks: tasks, eventBus: eventBus);
      final statusEvents = <TaskStatusChangedEvent>[];
      final statusSub = eventBus.on<TaskStatusChangedEvent>().listen(statusEvents.add);
      addTearDown(statusSub.cancel);

      final result = await service.channelReviewHandler()('task-1', 'accept');
      await Future<void>.delayed(Duration.zero);

      expect(result, const TypeMatcher<ChannelReviewSuccess>());
      expect((result as ChannelReviewSuccess).taskTitle, 'Fix login');
      expect(statusEvents, hasLength(1));
      expect(statusEvents.single.trigger, 'channel');
    });

    test('rejects review tasks', () async {
      await _putTaskInReview(tasks, 'task-1', title: 'Fix login');
      final service = TaskReviewService(tasks: tasks, eventBus: eventBus);

      final result = await service.review('task-1', 'reject');

      expect(result, const TypeMatcher<ReviewSuccess>());
      expect((await tasks.get('task-1'))!.status, TaskStatus.rejected);
    });

    test('pushes tasks back to running with comment metadata', () async {
      await _putTaskInReview(tasks, 'task-1', title: 'Fix login');
      final service = TaskReviewService(tasks: tasks, eventBus: eventBus);

      final result = await service.review('task-1', 'push_back', comment: 'try again');

      expect(result, const TypeMatcher<ReviewSuccess>());
      final updated = (await tasks.get('task-1'))!;
      expect(updated.status, TaskStatus.running);
      expect(updated.configJson['pushBackCount'], 1);
      expect(updated.configJson['pushBackComment'], 'try again');
    });

    test('rejects push_back without a comment', () async {
      await _putTaskInReview(tasks, 'task-1', title: 'Fix login');
      final service = TaskReviewService(tasks: tasks, eventBus: eventBus);

      final result = await service.review('task-1', 'push_back');

      expect(result, const TypeMatcher<ReviewInvalidRequest>());
      expect((result as ReviewInvalidRequest).message, 'comment must not be empty for push_back');
      expect((await tasks.get('task-1'))!.status, TaskStatus.review);
    });

    test('push_back fires status event with running as new status', () async {
      await _putTaskInReview(tasks, 'task-1', title: 'Fix login');
      final service = TaskReviewService(tasks: tasks, eventBus: eventBus);
      final statusEvents = <TaskStatusChangedEvent>[];
      final sub = eventBus.on<TaskStatusChangedEvent>().listen(statusEvents.add);
      addTearDown(sub.cancel);

      await service.review('task-1', 'push_back', comment: 'revise the auth logic');
      await Future<void>.delayed(Duration.zero);

      expect(statusEvents, hasLength(1));
      expect(statusEvents.single.oldStatus, TaskStatus.review);
      expect(statusEvents.single.newStatus, TaskStatus.running);
    });

    test('push_back invokes PushBackFeedbackDelivery callback', () async {
      await _putTaskInReview(tasks, 'task-1', title: 'Fix login', sessionKey: 'agent:main:task:task-1');
      final deliveries = <(String taskId, String feedback)>[];
      final service = TaskReviewService(
        tasks: tasks,
        eventBus: eventBus,
        pushBackFeedbackDelivery: ({required taskId, required sessionKey, required feedback}) async {
          deliveries.add((taskId, feedback));
        },
      );

      await service.review('task-1', 'push_back', comment: 'revise the auth logic');
      await Future<void>.delayed(Duration.zero);

      expect(deliveries, hasLength(1));
      expect(deliveries.single.$1, 'task-1');
      expect(deliveries.single.$2, 'revise the auth logic');
    });

    test('push_back proceeds even when PushBackFeedbackDelivery callback throws', () async {
      await _putTaskInReview(tasks, 'task-1', title: 'Fix login');
      final service = TaskReviewService(
        tasks: tasks,
        eventBus: eventBus,
        pushBackFeedbackDelivery: ({required taskId, required sessionKey, required feedback}) async {
          throw StateError('delivery failed');
        },
      );

      // Should not rethrow — delivery is best-effort.
      final result = await service.review('task-1', 'push_back', comment: 'try again');

      expect(result, const TypeMatcher<ReviewSuccess>());
      expect((await tasks.get('task-1'))!.status, TaskStatus.running);
    });

    test('channelReviewHandler passes comment through for push_back', () async {
      await _putTaskInReview(tasks, 'task-1', title: 'Fix login', sessionKey: 'agent:main:task:task-1');
      String? capturedComment;
      final service = TaskReviewService(
        tasks: tasks,
        eventBus: eventBus,
        pushBackFeedbackDelivery: ({required taskId, required sessionKey, required feedback}) async {
          capturedComment = feedback;
        },
      );

      final result = await service.channelReviewHandler()('task-1', 'push_back', comment: 'fix the tests');
      await Future<void>.delayed(Duration.zero);

      expect(result, const TypeMatcher<ChannelReviewSuccess>());
      expect((result as ChannelReviewSuccess).action, 'push_back');
      expect(capturedComment, 'fix the tests');
    });

    test('runs merge and cleans up worktrees for accepted coding tasks', () async {
      await _putTaskInReview(
        tasks,
        'task-1',
        title: 'Fix login',
        worktreeJson: const {
          'path': '/tmp/worktree',
          'branch': 'dartclaw/task-task-1',
          'createdAt': '2026-03-13T10:00:00.000Z',
        },
      );
      final mergeExecutor = _RecordingMergeExecutor(
        result: const MergeSuccess(commitSha: 'abc123', commitMessage: 'task(task-1): Fix login'),
      );
      final worktreeManager = _RecordingWorktreeManager();
      final taskFileGuard = _RecordingTaskFileGuard()..register('task-1', '/tmp/worktree');
      final service = TaskReviewService(
        tasks: tasks,
        eventBus: eventBus,
        mergeExecutor: mergeExecutor,
        worktreeManager: worktreeManager,
        taskFileGuard: taskFileGuard,
      );

      final result = await service.review('task-1', 'accept');

      expect(result, const TypeMatcher<ReviewSuccess>());
      expect(mergeExecutor.callCount, 1);
      expect(worktreeManager.cleanedTaskIds, ['task-1']);
      expect(taskFileGuard.deregisteredTaskIds, ['task-1']);
      expect(taskFileGuard.hasRegistration('task-1'), isFalse);
      expect((await tasks.get('task-1'))!.status, TaskStatus.accepted);
    });

    test('rejects accepting worktree-backed tasks when merge support is unavailable', () async {
      await _putTaskInReview(
        tasks,
        'task-1',
        title: 'Fix login',
        worktreeJson: const {
          'path': '/tmp/worktree',
          'branch': 'dartclaw/task-task-1',
          'createdAt': '2026-03-13T10:00:00.000Z',
        },
      );
      final service = TaskReviewService(tasks: tasks, eventBus: eventBus);

      final result = await service.review('task-1', 'accept');

      expect(result, const TypeMatcher<ReviewActionFailed>());
      expect(
        (result as ReviewActionFailed).message,
        'Merge infrastructure is not available. Use the web UI or configure merge support.',
      );
      expect((await tasks.get('task-1'))!.status, TaskStatus.review);
    });

    test('serializes concurrent review accepts so merge runs only once', () async {
      await _putTaskInReview(
        tasks,
        'task-1',
        title: 'Fix login',
        worktreeJson: const {
          'path': '/tmp/worktree',
          'branch': 'dartclaw/task-task-1',
          'createdAt': '2026-03-13T10:00:00.000Z',
        },
      );
      final mergeExecutor = _BlockingMergeExecutor(
        result: const MergeSuccess(commitSha: 'abc123', commitMessage: 'task(task-1): Fix login'),
      );
      final service = TaskReviewService(tasks: tasks, eventBus: eventBus, mergeExecutor: mergeExecutor);

      final firstReview = service.review('task-1', 'accept');
      await mergeExecutor.started.future;

      final secondReview = service.review('task-1', 'accept');
      await Future<void>.delayed(Duration.zero);
      expect(mergeExecutor.callCount, 1);

      mergeExecutor.release.complete();
      final firstResult = await firstReview;
      final secondResult = await secondReview;

      expect(firstResult, const TypeMatcher<ReviewSuccess>());
      expect(secondResult, const TypeMatcher<ReviewInvalidTransition>());
      expect((secondResult as ReviewInvalidTransition).currentStatus, TaskStatus.accepted);
      expect(mergeExecutor.callCount, 1);
      expect((await tasks.get('task-1'))!.status, TaskStatus.accepted);
    });

    test('returns merge conflict and persists conflict artifacts', () async {
      final tempDir = await Directory.systemTemp.createTemp('dartclaw_task_review_conflict_');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      await _putTaskInReview(
        tasks,
        'task-1',
        title: 'Fix login',
        worktreeJson: const {
          'path': '/tmp/worktree',
          'branch': 'dartclaw/task-task-1',
          'createdAt': '2026-03-13T10:00:00.000Z',
        },
      );
      final mergeExecutor = _RecordingMergeExecutor(
        result: const MergeConflict(conflictingFiles: ['lib/main.dart'], details: 'Automatic merge failed'),
      );
      final worktreeManager = _RecordingWorktreeManager();
      final service = TaskReviewService(
        tasks: tasks,
        eventBus: eventBus,
        mergeExecutor: mergeExecutor,
        worktreeManager: worktreeManager,
        dataDir: tempDir.path,
      );

      final result = await service.review('task-1', 'accept');

      expect(result, const TypeMatcher<ReviewMergeConflict>());
      final conflict = result as ReviewMergeConflict;
      expect(conflict.taskTitle, 'Fix login');
      expect(conflict.conflictingFiles, ['lib/main.dart']);
      expect((await tasks.get('task-1'))!.status, TaskStatus.review);
      expect(worktreeManager.cleanedTaskIds, isEmpty);

      final artifacts = await tasks.listArtifacts('task-1');
      expect(artifacts, hasLength(1));
      expect(artifacts.single.name, 'conflict.json');
      final json = jsonDecode(await File(artifacts.single.path).readAsString()) as Map<String, dynamic>;
      expect(json['conflictingFiles'], ['lib/main.dart']);
    });

    test('returns not found when the task does not exist', () async {
      final service = TaskReviewService(tasks: tasks, eventBus: eventBus);

      final result = await service.review('missing', 'accept');

      expect(result, const TypeMatcher<ReviewNotFound>());
    });

    test('returns invalid transition when task is not in review', () async {
      await tasks.create(
        id: 'task-1',
        title: 'Fix login',
        description: 'Fix login',
        type: TaskType.coding,
        now: DateTime.parse('2026-03-13T10:00:00Z'),
      );
      final service = TaskReviewService(tasks: tasks, eventBus: eventBus);

      final result = await service.review('task-1', 'accept');

      expect(result, const TypeMatcher<ReviewInvalidTransition>());
      expect((result as ReviewInvalidTransition).currentStatus, TaskStatus.draft);
    });

    test('returns invalid request for unknown actions', () async {
      final service = TaskReviewService(tasks: tasks, eventBus: eventBus);

      final result = await service.review('task-1', 'ship_it');

      expect(result, const TypeMatcher<ReviewInvalidRequest>());
      expect((result as ReviewInvalidRequest).message, 'action must be one of: accept, reject, push_back');
    });

    test('returns generic failures for unexpected errors', () async {
      await _putTaskInReview(
        tasks,
        'task-1',
        title: 'Fix login',
        worktreeJson: const {
          'path': '/tmp/worktree',
          'branch': 'dartclaw/task-task-1',
          'createdAt': '2026-03-13T10:00:00.000Z',
        },
      );
      final service = TaskReviewService(
        tasks: tasks,
        eventBus: eventBus,
        mergeExecutor: _ThrowingMergeExecutor(Exception('merge exploded')),
      );

      final result = await service.review('task-1', 'accept');

      expect(result, const TypeMatcher<ReviewActionFailed>());
      expect((result as ReviewActionFailed).message, 'Review action failed. Please try again or use the web UI.');
      expect((await tasks.get('task-1'))!.status, TaskStatus.review);
    });
  });
}

Future<Task> _putTaskInReview(
  TaskService tasks,
  String id, {
  required String title,
  Map<String, dynamic>? worktreeJson,
  String? sessionKey,
}) async {
  final configJson = sessionKey != null
      ? <String, dynamic>{'origin': <String, dynamic>{'sessionKey': sessionKey}}
      : null;
  await tasks.create(
    id: id,
    title: title,
    description: title,
    type: TaskType.coding,
    autoStart: true,
    now: DateTime.parse('2026-03-13T10:00:00Z'),
    configJson: configJson ?? const {},
  );
  await tasks.transition(id, TaskStatus.running, now: DateTime.parse('2026-03-13T10:05:00Z'));
  await tasks.transition(id, TaskStatus.review, now: DateTime.parse('2026-03-13T10:10:00Z'));
  if (worktreeJson != null) {
    return tasks.updateFields(id, worktreeJson: worktreeJson);
  }
  return (await tasks.get(id))!;
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

class _BlockingMergeExecutor extends MergeExecutor {
  final MergeResult result;
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  int callCount = 0;

  _BlockingMergeExecutor({required this.result}) : super(projectDir: '.');

  @override
  Future<MergeResult> merge({
    required String branch,
    required String baseRef,
    required String taskId,
    required String taskTitle,
    MergeStrategy? strategy,
  }) async {
    callCount += 1;
    if (!started.isCompleted) {
      started.complete();
    }
    await release.future;
    return result;
  }
}

class _ThrowingMergeExecutor extends MergeExecutor {
  final Object error;

  _ThrowingMergeExecutor(this.error) : super(projectDir: '.');

  @override
  Future<MergeResult> merge({
    required String branch,
    required String baseRef,
    required String taskId,
    required String taskTitle,
    MergeStrategy? strategy,
  }) async {
    throw error;
  }
}

class _RecordingWorktreeManager extends WorktreeManager {
  final List<String> cleanedTaskIds = [];

  _RecordingWorktreeManager() : super(dataDir: '/tmp', projectDir: '/tmp');

  @override
  Future<void> cleanup(String taskId) async {
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
