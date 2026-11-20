import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'task_review_test_support.dart';
import 'task_executor_test_support.dart' show initGitRepo;
import 'host_worktree_tamper_fixture.dart';

void main() {
  late TaskService tasks;
  late EventBus eventBus;

  setUp(() async {
    eventBus = EventBus();
    tasks = TaskService(InMemoryTaskRepository(), eventBus: eventBus);
  });

  tearDown(() async {
    await eventBus.dispose();
    await tasks.dispose();
  });

  group('TaskReviewService', () {
    test('accepts review tasks and fires status events', () async {
      await putTaskInReview(tasks, 'task-1', title: 'Fix login');
      final service = TaskReviewService(tasks: tasks);
      final statusEvents = <TaskStatusChangedEvent>[];
      final reviewReadyEvents = <TaskReviewReadyEvent>[];
      final statusSub = eventBus.on<TaskStatusChangedEvent>().listen(statusEvents.add);
      final readySub = eventBus.on<TaskReviewReadyEvent>().listen(reviewReadyEvents.add);
      addTearDown(statusSub.cancel);
      addTearDown(readySub.cancel);

      final result = await service.review('task-1', 'accept', trigger: 'user');
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
      await putTaskInReview(tasks, 'task-1', title: 'Fix login');
      final service = TaskReviewService(tasks: tasks);
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
      await putTaskInReview(tasks, 'task-1', title: 'Fix login');
      final service = TaskReviewService(tasks: tasks);

      final result = await service.review('task-1', 'reject', trigger: 'user');

      expect(result, const TypeMatcher<ReviewSuccess>());
      expect((await tasks.get('task-1'))!.status, TaskStatus.rejected);
    });

    test('pushes tasks back to running with comment metadata', () async {
      await putTaskInReview(tasks, 'task-1', title: 'Fix login');
      final service = TaskReviewService(tasks: tasks);

      final result = await service.review('task-1', 'push_back', comment: 'try again', trigger: 'user');

      expect(result, const TypeMatcher<ReviewSuccess>());
      final updated = (await tasks.get('task-1'))!;
      expect(updated.status, TaskStatus.running);
      expect(updated.configJson['pushBackCount'], 1);
      expect(updated.configJson['pushBackComment'], 'try again');
    });

    test('rejects push_back without a comment', () async {
      await putTaskInReview(tasks, 'task-1', title: 'Fix login');
      final service = TaskReviewService(tasks: tasks);

      final result = await service.review('task-1', 'push_back', trigger: 'user');

      expect(result, const TypeMatcher<ReviewInvalidRequest>());
      expect((result as ReviewInvalidRequest).message, 'comment must not be empty for push_back');
      expect((await tasks.get('task-1'))!.status, TaskStatus.review);
    });

    test('push_back fires status event with running as new status', () async {
      await putTaskInReview(tasks, 'task-1', title: 'Fix login');
      final service = TaskReviewService(tasks: tasks);
      final statusEvents = <TaskStatusChangedEvent>[];
      final sub = eventBus.on<TaskStatusChangedEvent>().listen(statusEvents.add);
      addTearDown(sub.cancel);

      await service.review('task-1', 'push_back', comment: 'revise the auth logic', trigger: 'user');
      await Future<void>.delayed(Duration.zero);

      expect(statusEvents, hasLength(1));
      expect(statusEvents.single.oldStatus, TaskStatus.review);
      expect(statusEvents.single.newStatus, TaskStatus.running);
    });

    test('push_back invokes PushBackFeedbackDelivery callback', () async {
      await putTaskInReview(tasks, 'task-1', title: 'Fix login', sessionKey: 'agent:main:task:task-1');
      final deliveries = <(String taskId, String feedback)>[];
      final origins = <TaskOrigin>[];
      final service = TaskReviewService(
        tasks: tasks,

        pushBackFeedbackDelivery: ({required taskId, required origin, required feedback}) async {
          deliveries.add((taskId, feedback));
          origins.add(origin);
        },
      );

      await service.review('task-1', 'push_back', comment: 'revise the auth logic', trigger: 'user');
      await Future<void>.delayed(Duration.zero);

      expect(deliveries, hasLength(1));
      expect(deliveries.single.$1, 'task-1');
      expect(deliveries.single.$2, 'revise the auth logic');
      expect(origins.single.sessionKey, 'agent:main:task:task-1');
      expect(origins.single.channelType, 'whatsapp');
    });

    test('push_back proceeds even when PushBackFeedbackDelivery callback throws', () async {
      await putTaskInReview(tasks, 'task-1', title: 'Fix login');
      final service = TaskReviewService(
        tasks: tasks,

        pushBackFeedbackDelivery: ({required taskId, required origin, required feedback}) async {
          throw StateError('delivery failed');
        },
      );

      // Should not rethrow — delivery is best-effort.
      final result = await service.review('task-1', 'push_back', comment: 'try again', trigger: 'user');

      expect(result, const TypeMatcher<ReviewSuccess>());
      expect((await tasks.get('task-1'))!.status, TaskStatus.running);
    });

    test('channelReviewHandler passes comment through for push_back', () async {
      await putTaskInReview(tasks, 'task-1', title: 'Fix login', sessionKey: 'agent:main:task:task-1');
      String? capturedComment;
      final service = TaskReviewService(
        tasks: tasks,

        pushBackFeedbackDelivery: ({required taskId, required origin, required feedback}) async {
          capturedComment = feedback;
        },
      );

      final result = await service.channelReviewHandler()('task-1', 'push_back', comment: 'fix the tests');
      await Future<void>.delayed(Duration.zero);

      expect(result, const TypeMatcher<ChannelReviewSuccess>());
      expect((result as ChannelReviewSuccess).action, 'push_back');
      expect(capturedComment, 'fix the tests');
    });

    for (final strategy in ['squash', 'merge']) {
      test('$strategy accept cleans up worktree-backed tasks', () async {
        await putTaskInReview(
          tasks,
          'task-1',
          title: 'Fix login',
          worktreeJson: const {
            'path': '/tmp/worktree',
            'branch': 'dartclaw/task-task-1',
            'createdAt': '2026-03-13T10:00:00.000Z',
          },
        );
        final mergeExecutor = RecordingMergeExecutor(
          result: const MergeSuccess(commitSha: 'abc123', commitMessage: 'task(task-1): Fix login'),
        );
        final worktreeManager = RecordingWorktreeManager();
        final taskFileGuard = RecordingTaskFileGuard()..register('task-1', '/tmp/worktree');
        final service = TaskReviewService(
          tasks: tasks,

          mergeExecutor: mergeExecutor,
          mergeStrategy: strategy,
          worktreeManager: worktreeManager,
          taskFileGuard: taskFileGuard,
        );

        final result = await service.review('task-1', 'accept', trigger: 'user');

        expect(result, const TypeMatcher<ReviewSuccess>());
        expect(mergeExecutor.callCount, 1);
        expect(worktreeManager.cleanedTaskIds, ['task-1']);
        expect(worktreeManager.forceDeleteBranches, [strategy == 'squash']);
        expect(taskFileGuard.deregisteredTaskIds, ['task-1']);
        expect(taskFileGuard.hasRegistration('task-1'), isFalse);
        expect((await tasks.get('task-1'))!.status, TaskStatus.accepted);
      });
    }

    test('rejects accepting worktree-backed tasks when merge support is unavailable', () async {
      await putTaskInReview(
        tasks,
        'task-1',
        title: 'Fix login',
        worktreeJson: const {
          'path': '/tmp/worktree',
          'branch': 'dartclaw/task-task-1',
          'createdAt': '2026-03-13T10:00:00.000Z',
        },
      );
      final service = TaskReviewService(tasks: tasks);

      final result = await service.review('task-1', 'accept', trigger: 'user');

      expect(result, const TypeMatcher<ReviewActionFailed>());
      expect(
        (result as ReviewActionFailed).message,
        'Merge infrastructure is not available. Use the web UI or configure merge support.',
      );
      expect((await tasks.get('task-1'))!.status, TaskStatus.review);
    });

    test('serializes concurrent review accepts so merge runs only once', () async {
      await putTaskInReview(
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
      final service = TaskReviewService(tasks: tasks, mergeExecutor: mergeExecutor);

      final firstReview = service.review('task-1', 'accept', trigger: 'user');
      await mergeExecutor.started.future;

      final secondReview = service.review('task-1', 'accept', trigger: 'user');
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

    test('execution-surface hold belongs to workflow promotion, so auto-accept skips merge and cleanup', () async {
      await tasks.create(
        id: 'task-workflow-review',
        title: 'Workflow review task',
        description: 'Workflow review task',
        autoStart: true,
        workflowRunId: 'run-123',
        now: DateTime.parse('2026-03-13T10:00:00Z'),
        configJson: const {
          'needsWorktree': true,
          '_workflowGit': {'worktree': 'per-map-item', 'promotion': 'merge'},
        },
      );
      await tasks.transition('task-workflow-review', TaskStatus.running, now: DateTime.parse('2026-03-13T10:05:00Z'));
      await tasks.transition('task-workflow-review', TaskStatus.review, now: DateTime.parse('2026-03-13T10:10:00Z'));
      await tasks.updateFields(
        'task-workflow-review',
        worktreeJson: const {
          'path': '/tmp/worktree',
          'branch': 'dartclaw/workflow/run123/story',
          'createdAt': '2026-03-13T10:00:00.000Z',
        },
      );
      final mergeExecutor = RecordingMergeExecutor(
        result: const MergeSuccess(commitSha: 'abc123', commitMessage: 'task(task-workflow-review): accept'),
      );
      final worktreeManager = RecordingWorktreeManager();
      final service = TaskReviewService(tasks: tasks, mergeExecutor: mergeExecutor, worktreeManager: worktreeManager);

      final result = await service.review('task-workflow-review', 'accept', trigger: 'auto_accept');

      expect(result, const TypeMatcher<ReviewSuccess>());
      expect((await tasks.get('task-workflow-review'))!.status, TaskStatus.accepted);
      expect(mergeExecutor.callCount, 0);
      expect(worktreeManager.cleanedTaskIds, isEmpty);
    });

    test('returns merge conflict and persists conflict artifacts', () async {
      final tempDir = await Directory.systemTemp.createTemp('dartclaw_task_review_conflict_');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      await putTaskInReview(
        tasks,
        'task-1',
        title: 'Fix login',
        worktreeJson: const {
          'path': '/tmp/worktree',
          'branch': 'dartclaw/task-task-1',
          'createdAt': '2026-03-13T10:00:00.000Z',
        },
      );
      final mergeExecutor = RecordingMergeExecutor(
        result: const MergeConflict(conflictingFiles: ['lib/main.dart'], details: 'Automatic merge failed'),
      );
      final worktreeManager = RecordingWorktreeManager();
      final service = TaskReviewService(
        tasks: tasks,

        mergeExecutor: mergeExecutor,
        worktreeManager: worktreeManager,
        dataDir: tempDir.path,
      );

      final result = await service.review('task-1', 'accept', trigger: 'user');

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
      final service = TaskReviewService(tasks: tasks);

      final result = await service.review('missing', 'accept', trigger: 'user');

      expect(result, const TypeMatcher<ReviewNotFound>());
    });

    test('returns invalid transition when task is not in review', () async {
      await tasks.create(
        id: 'task-1',
        title: 'Fix login',
        description: 'Fix login',
        configJson: const {'needsWorktree': false},
        now: DateTime.parse('2026-03-13T10:00:00Z'),
      );
      final service = TaskReviewService(tasks: tasks);

      final result = await service.review('task-1', 'accept', trigger: 'user');

      expect(result, const TypeMatcher<ReviewInvalidTransition>());
      expect((result as ReviewInvalidTransition).currentStatus, TaskStatus.draft);
    });

    test('returns invalid request for unknown actions', () async {
      final service = TaskReviewService(tasks: tasks);

      final result = await service.review('task-1', 'ship_it', trigger: 'user');

      expect(result, const TypeMatcher<ReviewInvalidRequest>());
      expect((result as ReviewInvalidRequest).message, 'action must be one of: accept, reject, push_back');
      expect(result.field, 'action');
    });

    test('owns review action and comment normalization', () async {
      await putTaskInReview(tasks, 'task-1', title: 'Fix login');
      final service = TaskReviewService(tasks: tasks);

      final empty = await service.review('task-1', '   ', trigger: 'user');
      expect(empty, isA<ReviewInvalidRequest>());
      expect((empty as ReviewInvalidRequest).message, 'action must not be empty');
      expect(empty.field, 'action');

      final missingComment = await service.review('task-1', ' push_back ', comment: '   ', trigger: 'user');
      expect(missingComment, isA<ReviewInvalidRequest>());
      expect((missingComment as ReviewInvalidRequest).message, 'comment must not be empty for push_back');
      expect(missingComment.field, 'comment');

      final success = await service.review('task-1', ' push_back ', comment: '  revise it  ', trigger: 'user');
      expect(success, isA<ReviewSuccess>());
      expect((success as ReviewSuccess).task.status, TaskStatus.running);
      expect(success.task.configJson['pushBackComment'], 'revise it');
    });

    test('returns generic failures for unexpected errors', () async {
      await putTaskInReview(
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

        mergeExecutor: _ThrowingMergeExecutor(Exception('merge exploded')),
      );

      final result = await service.review('task-1', 'accept', trigger: 'user');

      expect(result, const TypeMatcher<ReviewActionFailed>());
      expect((result as ReviewActionFailed).message, 'Review action failed. Please try again or use the web UI.');
      expect((await tasks.get('task-1'))!.status, TaskStatus.review);
    });
  });

  group('TaskEventRecorder — push-back events', () {
    late InMemoryTaskEventService eventService;
    late TaskEventRecorder recorder;

    setUp(() async {
      eventService = InMemoryTaskEventService();
      recorder = TaskEventRecorder(eventService: eventService);
    });

    tearDown(() async {
      await eventService.close();
    });

    test('push_back action records a pushBack event with the comment', () async {
      await putTaskInReview(tasks, 'task-1', title: 'Review task');
      final service = TaskReviewService(tasks: tasks, eventRecorder: recorder);

      await service.review('task-1', 'push_back', comment: 'Please fix the tests', trigger: 'user');

      final events = await eventService.listForTask('task-1');
      expect(events, hasLength(1));
      expect(events[0].kind.name, 'pushBack');
      expect(events[0].details['comment'], 'Please fix the tests');
    });

    test('accept action does not record a pushBack event', () async {
      await putTaskInReview(tasks, 'task-1', title: 'Review task');
      final service = TaskReviewService(tasks: tasks, eventRecorder: recorder);

      await service.review('task-1', 'accept', trigger: 'user');

      final events = await eventService.listForTask('task-1', kind: TaskEventKind.pushBack);
      expect(events, isEmpty);
    });

    test('null eventRecorder does not affect push_back behavior', () async {
      await putTaskInReview(tasks, 'task-2', title: 'Another task');
      final service = TaskReviewService(tasks: tasks);

      final result = await service.review('task-2', 'push_back', comment: 'try again', trigger: 'user');

      expect(result, isA<ReviewSuccess>());
    });
  });

  group('squash accept deletes the task branch', () {
    late Directory repo;
    late Directory data;
    late WorktreeManager worktrees;

    Future<ProcessResult> git(List<String> args, {String? dir}) async {
      final result = await runGit(args, workingDirectory: dir ?? repo.path);
      if (result.exitCode != 0) throw StateError('${args.join(' ')}: ${result.stderr}');
      return result;
    }

    setUp(() async {
      repo = await initGitRepo();
      data = await Directory.systemTemp.createTemp('review_cleanup_');
      await git(['config', 'user.email', 'fixture@example.com']);
      await git(['config', 'user.name', 'Fixture']);
      worktrees = WorktreeManager(dataDir: data.path, projectDir: repo.path);
    });
    tearDown(() async {
      await data.delete(recursive: true);
      await repo.delete(recursive: true);
    });

    Future<WorktreeInfo> reviewWorktree({String? attachedBranch}) async {
      if (attachedBranch != null) await git(['branch', attachedBranch, 'main']);
      final worktree = await worktrees.create(
        'cleanup-task',
        baseRef: attachedBranch,
        createBranch: attachedBranch == null,
      );
      File(p.join(worktree.path, 'README.md')).writeAsStringSync('task change\n');
      await git(['add', 'README.md'], dir: worktree.path);
      await git(['commit', '-m', 'task changes'], dir: worktree.path);
      await putTaskInReview(tasks, 'cleanup-task', title: 'Save the changes', worktreeJson: worktree.toJson());
      return worktree;
    }

    TaskReviewService reviewService({String strategy = 'squash'}) => TaskReviewService(
      tasks: tasks,
      worktreeManager: worktrees,
      mergeExecutor: MergeExecutor(projectDir: repo.path),
      mergeStrategy: strategy,
      dataDir: data.path,
    );

    test('lands the squash commit and removes the owned branch', () async {
      final worktree = await reviewWorktree();
      final branchTip = (await git(['rev-parse', worktree.branch])).stdout;

      expect(await reviewService().review('cleanup-task', 'accept', trigger: 'user'), isA<ReviewSuccess>());

      expect((await git(['show', 'main:README.md'])).stdout, 'task change\n');
      expect((await git(['rev-parse', 'main'])).stdout, isNot(branchTip));
      expect(
        (await git(['log', '-1', '--format=%s', 'main'])).stdout.toString().trim(),
        'task(cleanup-task): Save the changes',
      );
      expect((await git(['branch', '--list', worktree.branch])).stdout.toString().trim(), isEmpty);
      expect(Directory(worktree.path).existsSync(), isFalse);
    });

    test('keeps the branch and review state on conflict', () async {
      final worktree = await reviewWorktree();
      File(p.join(repo.path, 'README.md')).writeAsStringSync('base change\n');
      await git(['add', 'README.md']);
      await git(['commit', '-m', 'base changes']);
      final baseTip = (await git(['rev-parse', 'main'])).stdout;

      expect(await reviewService().review('cleanup-task', 'accept', trigger: 'user'), isA<ReviewMergeConflict>());

      expect((await tasks.get('cleanup-task'))!.status, TaskStatus.review);
      expect((await git(['rev-parse', 'main'])).stdout, baseTip);
      expect((await git(['branch', '--list', worktree.branch])).stdout.toString().trim(), isNotEmpty);
      expect(Directory(worktree.path).existsSync(), isTrue);
    });

    test('keeps an attached branch even when already merged', () async {
      final worktree = await reviewWorktree(attachedBranch: 'wf/integration');
      await git(['merge', '--ff-only', worktree.branch]);
      final branchTip = (await git(['rev-parse', worktree.branch])).stdout;

      expect(await reviewService().review('cleanup-task', 'accept', trigger: 'user'), isA<ReviewSuccess>());

      expect((await git(['rev-parse', worktree.branch])).stdout, branchTip);
      expect(Directory(worktree.path).existsSync(), isFalse);
    });

    test('merge strategy retains the non-force deletion path', () async {
      final worktree = await reviewWorktree();
      expect(
        await reviewService(strategy: 'merge').review('cleanup-task', 'accept', trigger: 'user'),
        isA<ReviewSuccess>(),
      );
      expect((await git(['show', 'main:README.md'])).stdout, 'task change\n');
      expect((await git(['branch', '--list', worktree.branch])).stdout.toString().trim(), isEmpty);
    });
  });

  group('execution-surface hold', () {
    late Directory repo;
    late Directory data;
    late WorktreeInfo worktree;
    late WorktreeManager worktrees;

    Future<ProcessResult> git(List<String> args, {String? dir}) async {
      final result = await runGit(args, workingDirectory: dir ?? repo.path);
      if (result.exitCode != 0) throw StateError('${args.join(' ')}: ${result.stderr}');
      return result;
    }

    setUp(() async {
      repo = await initGitRepo();
      data = await Directory.systemTemp.createTemp('review_surface_');
      await git(['config', 'user.email', 'fixture@example.com']);
      await git(['config', 'user.name', 'Fixture']);
      worktrees = WorktreeManager(dataDir: data.path, projectDir: repo.path);
      worktree = await worktrees.create('surface-task');
      await putTaskInReview(tasks, 'surface-task', title: 'Review changes');
      await tasks.updateFields('surface-task', worktreeJson: worktree.toJson());
    });
    tearDown(() async {
      await data.delete(recursive: true);
      await repo.delete(recursive: true);
    });

    void write(String path) {
      final file = File(p.join(worktree.path, path))..parent.createSync(recursive: true);
      file.writeAsStringSync('changed\n');
    }

    for (final trigger in ['auto_accept', 'agent_tool']) {
      for (final committed in [true, false]) {
        test('$trigger holds ${committed ? 'committed' : 'uncommitted'} changes before merge', () async {
          write('.claude/settings.json');
          write('ordinary.dart');
          if (committed) {
            await git(['add', '-A'], dir: worktree.path);
            await git(['commit', '-m', 'agent changes'], dir: worktree.path);
          }
          final before = (await git(['rev-parse', 'main'])).stdout;
          final service = TaskReviewService(
            tasks: tasks,
            mergeExecutor: MergeExecutor(projectDir: repo.path),
            worktreeManager: worktrees,
          );
          final result = await service.review('surface-task', 'accept', trigger: trigger);
          expect(result, isNot(isA<ReviewSuccess>()));
          expect((await git(['rev-parse', 'main'])).stdout, before);
          final held = (await tasks.get('surface-task'))!;
          expect(held.status, TaskStatus.review);
          expect(Directory(worktree.path).existsSync(), isTrue);
          expect((await git(['branch', '--list', worktree.branch])).stdout.toString().trim(), isNotEmpty);
          expect(held.configJson['_executionSurfaceHold'], {
            'paths': ['.claude/settings.json'],
          });
          if (committed) {
            expect(await service.review('surface-task', 'accept', trigger: 'user'), isA<ReviewSuccess>());
            expect((await tasks.get('surface-task'))!.configJson.containsKey('_executionSurfaceHold'), isFalse);
            expect((await git(['show', 'main:.claude/settings.json'])).stdout, 'changed\n');
          }
        });
      }
    }

    test('metadata read errors refuse automatic accept before merge', () async {
      await tasks.updateFields('surface-task', worktreeJson: {...worktree.toJson(), 'path': data.path});
      final merge = RecordingMergeExecutor(
        result: const MergeSuccess(commitSha: 'never', commitMessage: 'never'),
        projectDir: repo.path,
      );
      final service = TaskReviewService(tasks: tasks, mergeExecutor: merge);
      final result = await service.review('surface-task', 'accept', trigger: 'auto_accept');
      expect(result, isA<ReviewActionFailed>());
      expect((await tasks.get('surface-task'))!.status, TaskStatus.review);
      expect(merge.callCount, 0);
    });

    test('project-backed accept holds before sweep and pushes nothing', () async {
      write('.mcp.json');
      final project = _makeProject(id: 'my-app').copyWith(localPath: repo.path);
      await tasks.updateFields('surface-task', projectId: project.id);
      final push = FakeRemotePushService(result: const PushSuccess());
      final service = TaskReviewService(
        tasks: tasks,
        projectService: _projectService(project: project),
        remotePushService: push,
      );
      final before = (await git(['rev-parse', worktree.branch])).stdout;
      expect(await service.review('surface-task', 'accept', trigger: 'auto_accept'), isNot(isA<ReviewSuccess>()));
      expect(push.callCount, 0);
      expect((await git(['rev-parse', worktree.branch])).stdout, before);
      expect((await git(['status', '--porcelain'], dir: worktree.path)).stdout, contains('.mcp.json'));
    });

    for (final hooksPath in ['.husky', '.githooks']) {
      test('host commit sweep runs no git hooks from $hooksPath', () async {
        final marker = await installMarkerGitHook(worktree.path, hooksPath: hooksPath);
        write('work.txt');
        final project = _makeProject(
          id: 'my-app',
          pr: const PrConfig(strategy: PrStrategy.branchOnly),
        ).copyWith(localPath: repo.path);
        await tasks.updateFields('surface-task', projectId: project.id);
        final service = TaskReviewService(
          tasks: tasks,
          projectService: _projectService(project: project),
          remotePushService: FakeRemotePushService(result: const PushSuccess()),
        );
        expect(await service.review('surface-task', 'accept', trigger: 'user'), isA<ReviewSuccess>());
        expect((await git(['show', 'HEAD:work.txt'], dir: worktree.path)).stdout, 'changed\n');
        expect(marker.existsSync(), isFalse);
      });
    }

    test('a clean automatic accept clears a stale hold and lands instruction edits', () async {
      write('AGENTS.md');
      write('CLAUDE.md');
      write('lib/a.dart');
      await git(['add', '-A'], dir: worktree.path);
      await git(['commit', '-m', 'ordinary changes'], dir: worktree.path);
      await tasks.updateFields(
        'surface-task',
        configJson: {
          '_executionSurfaceHold': {
            'paths': ['old'],
          },
        },
      );
      final service = TaskReviewService(
        tasks: tasks,
        mergeExecutor: MergeExecutor(projectDir: repo.path),
      );
      expect(await service.review('surface-task', 'accept', trigger: 'auto_accept'), isA<ReviewSuccess>());
      expect((await tasks.get('surface-task'))!.configJson.containsKey('_executionSurfaceHold'), isFalse);
      expect((await git(['show', 'main:AGENTS.md'])).stdout, 'changed\n');
    });
  });

  group('tampered task worktree', () {
    TaskReviewService personAccept(HostWorktreeTamperFixture fixture, FakeRemotePushService push) => TaskReviewService(
      tasks: tasks,
      projectService: _projectService(
        project: _makeProject(
          id: 'my-app',
          localPath: fixture.projectDir,
          pr: const PrConfig(strategy: PrStrategy.branchOnly),
        ),
      ),
      remotePushService: push,
    );

    Future<String> branchTip(HostWorktreeTamperFixture fixture) async =>
        ((await HostWorktreeTamperFixture.git(fixture.projectDir, ['rev-parse', fixture.branch])).stdout as String)
            .trim();

    final tampers = <String, Future<void> Function(HostWorktreeTamperFixture)>{
      'gitlink rewritten to an agent gitdir': (fixture) => fixture.rewriteGitlinkToAgentGitdir(),
      'gitlink replaced by a repository': (fixture) => fixture.replaceGitlinkWithRepository(),
      'gitlink deleted': (fixture) async => fixture.deleteGitlink(),
    };
    for (final tamper in tampers.entries) {
      test('a person accept refuses a project task whose ${tamper.key}', () async {
        final fixture = await _putProjectTaskInReview(tasks, 'task-tampered');
        fixture.write('dirty.txt');
        final tipBefore = await branchTip(fixture);
        await tamper.value(fixture);
        final push = FakeRemotePushService(result: const PushSuccess());

        final result = await personAccept(fixture, push).review('task-tampered', 'accept', trigger: 'user');

        expect(result, isA<ReviewActionFailed>());
        expect((result as ReviewActionFailed).message, contains('tampered worktree "${fixture.worktreePath}"'));
        expect((await tasks.get('task-tampered'))!.status, TaskStatus.review);
        expect(push.callCount, 0);
        expect(await branchTip(fixture), tipBefore);
        expect(fixture.existingMarkers, isEmpty);
      });
    }

    test('an automatic accept refuses a local task whose gitlink names an agent gitdir', () async {
      final fixture = await HostWorktreeTamperFixture.create(branch: 'dartclaw/task-auto', worktreeName: 'auto');
      addTearDown(fixture.dispose);
      final data = await Directory.systemTemp.createTemp('review_tampered_');
      addTearDown(() => data.delete(recursive: true));
      await putTaskInReview(tasks, 'task-auto', title: 'Review changes');
      await tasks.updateFields(
        'task-auto',
        worktreeJson: {'path': fixture.worktreePath, 'branch': fixture.branch, 'createdAt': '2026-03-13T10:00:00.000Z'},
      );
      fixture.write('.mcp.json');
      await fixture.rewriteGitlinkToAgentGitdir();
      final merge = RecordingMergeExecutor(
        result: const MergeSuccess(commitSha: 'never', commitMessage: 'never'),
      );
      final service = TaskReviewService(
        tasks: tasks,
        mergeExecutor: merge,
        worktreeManager: WorktreeManager(dataDir: data.path, projectDir: fixture.projectDir),
      );

      for (final trigger in ['auto_accept', 'agent_tool']) {
        final result = await service.review('task-auto', 'accept', trigger: trigger);
        expect(result, isA<ReviewActionFailed>());
        expect((result as ReviewActionFailed).message, contains('tampered worktree'));
      }
      expect((await tasks.get('task-auto'))!.status, TaskStatus.review);
      expect(merge.callCount, 0);
      expect(fixture.existingMarkers, isEmpty);
    });

    test('a person accept runs no config of a repository nested in the worktree', () async {
      final fixture = await _putProjectTaskInReview(tasks, 'task-nested');
      await fixture.nestRepository();

      await personAccept(
        fixture,
        FakeRemotePushService(result: const PushSuccess()),
      ).review('task-nested', 'accept', trigger: 'user');

      expect(fixture.existingMarkers, isEmpty);
    });
  });

  group('project-backed accept', () {
    test('push + PR created → task accepted, PR URL artifact stored', () async {
      final tempDir = await Directory.systemTemp.createTemp('dartclaw_proj_review_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final fixture = await _putProjectTaskInReview(tasks, 'task-proj');

      final projectService = _projectService(
        project: _makeProject(
          id: 'my-app',
          localPath: fixture.projectDir,
          pr: const PrConfig(strategy: PrStrategy.githubPr),
        ),
      );
      final pushService = FakeRemotePushService(result: const PushSuccess());
      final prCreator = FakePrCreator(result: const PrCreated('https://github.com/u/r/pull/42'));
      final worktreeManager = RecordingWorktreeManager();
      final service = TaskReviewService(
        tasks: tasks,
        remotePushService: pushService,
        prCreator: prCreator,
        projectService: projectService,
        worktreeManager: worktreeManager,
        dataDir: tempDir.path,
      );

      final result = await service.review('task-proj', 'accept', trigger: 'user');

      expect(result, const TypeMatcher<ReviewSuccess>());
      expect((await tasks.get('task-proj'))!.status, TaskStatus.accepted);
      final artifacts = await tasks.listArtifacts('task-proj');
      expect(artifacts, isNotEmpty);
      final prArtifact = artifacts.firstWhere((a) => a.kind == ArtifactKind.pr);
      expect(prArtifact.name, 'Pull Request');
      expect(prArtifact.path, 'https://github.com/u/r/pull/42');
      expect(worktreeManager.cleanedTaskIds, contains('task-proj'));
      expect(worktreeManager.forceDeleteBranches, [false]);
      expect(worktreeManager.cleanedProjectIds, contains('my-app'));
    });

    test('branch-only strategy → task accepted, branch name artifact stored', () async {
      final tempDir = await Directory.systemTemp.createTemp('dartclaw_proj_review_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final fixture = await _putProjectTaskInReview(tasks, 'task-branch');

      final projectService = _projectService(
        project: _makeProject(
          id: 'my-app',
          localPath: fixture.projectDir,
          pr: const PrConfig(strategy: PrStrategy.branchOnly),
        ),
      );
      final pushService = FakeRemotePushService(result: const PushSuccess());
      final service = TaskReviewService(
        tasks: tasks,
        remotePushService: pushService,
        projectService: projectService,
        dataDir: tempDir.path,
      );

      final result = await service.review('task-branch', 'accept', trigger: 'user');

      expect(result, const TypeMatcher<ReviewSuccess>());
      final artifacts = await tasks.listArtifacts('task-branch');
      final branchArtifact = artifacts.firstWhere((a) => a.kind == ArtifactKind.pr);
      expect(branchArtifact.name, 'Branch');
      expect(branchArtifact.path, 'dartclaw/task-task-branch');
    });

    test('project-backed accept commits dirty worktree changes before push', () async {
      final tempDir = await Directory.systemTemp.createTemp('dartclaw_proj_review_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final fixture = await _putProjectTaskInReview(tasks, 'task-dirty');
      fixture.write('notes/spec-publish.md');

      final projectService = _projectService(
        project: _makeProject(
          id: 'my-app',
          localPath: fixture.projectDir,
          pr: const PrConfig(strategy: PrStrategy.branchOnly),
        ),
      );
      final pushService = FakeRemotePushService(result: const PushSuccess());
      final calls = <({List<String> arguments, bool noSystemConfig})>[];
      Future<ProcessResult> recordingGit(
        List<String> arguments, {
        String? workingDirectory,
        ProcessEnvironmentPlan plan = const EmptyProcessEnvironmentPlan(),
        bool noSystemConfig = true,
      }) {
        calls.add((arguments: arguments, noSystemConfig: noSystemConfig));
        return runGit(arguments, workingDirectory: workingDirectory, plan: plan, noSystemConfig: noSystemConfig);
      }

      final service = TaskReviewService(
        tasks: tasks,
        remotePushService: pushService,
        projectService: projectService,
        dataDir: tempDir.path,
        processRunner: recordingGit,
      );

      final result = await service.review('task-dirty', 'accept', trigger: 'user');

      expect(result, const TypeMatcher<ReviewSuccess>());
      expect(pushService.callCount, 1);
      final commit = calls.singleWhere((call) => call.arguments.contains('commit'));
      expect(
        commit.arguments,
        containsAll([
          'core.hooksPath=/dev/null',
          '--git-dir=${fixture.adminDir}',
          '--work-tree=${fixture.worktreePath}',
        ]),
      );
      expect(commit.noSystemConfig, isTrue);
      final committed = await HostWorktreeTamperFixture.git(fixture.worktreePath, [
        'show',
        'HEAD:notes/spec-publish.md',
      ]);
      expect(committed.stdout, 'changed\n');
    });

    test('PR creation failure keeps task in review and preserves the worktree', () async {
      final tempDir = await Directory.systemTemp.createTemp('dartclaw_proj_review_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final fixture = await _putProjectTaskInReview(tasks, 'task-pr-failure');

      final projectService = _projectService(
        project: _makeProject(
          id: 'my-app',
          localPath: fixture.projectDir,
          pr: const PrConfig(strategy: PrStrategy.githubPr),
        ),
      );
      final pushService = FakeRemotePushService(result: const PushSuccess());
      final prCreator = FakePrCreator(
        result: const PrCreationFailed(
          error: 'GitHub PR creation failed (HTTP 422)',
          details: 'A pull request already exists for this branch.',
        ),
      );
      final worktreeManager = RecordingWorktreeManager();
      final service = TaskReviewService(
        tasks: tasks,
        remotePushService: pushService,
        prCreator: prCreator,
        projectService: projectService,
        worktreeManager: worktreeManager,
        dataDir: tempDir.path,
      );

      final result = await service.review('task-pr-failure', 'accept', trigger: 'user');

      expect(result, isA<ReviewActionFailed>());
      expect((await tasks.get('task-pr-failure'))!.status, TaskStatus.review);
      expect(worktreeManager.cleanedTaskIds, isEmpty);
      final artifacts = await tasks.listArtifacts('task-pr-failure');
      final prArtifact = artifacts.firstWhere((a) => a.kind == ArtifactKind.pr);
      expect(prArtifact.name, 'PR Creation Error');
    });

    test('push auth failure → task stays in review, error artifact stored', () async {
      final tempDir = await Directory.systemTemp.createTemp('dartclaw_proj_review_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final fixture = await _putProjectTaskInReview(tasks, 'task-auth');

      final projectService = _projectService(
        project: _makeProject(id: 'my-app', localPath: fixture.projectDir),
      );
      final pushService = FakeRemotePushService(
        result: const PushAuthFailure('Authentication denied. Check credentials.'),
      );
      final worktreeManager = RecordingWorktreeManager();
      final service = TaskReviewService(
        tasks: tasks,
        remotePushService: pushService,
        projectService: projectService,
        worktreeManager: worktreeManager,
        dataDir: tempDir.path,
      );

      final result = await service.review('task-auth', 'accept', trigger: 'user');

      expect(result, const TypeMatcher<ReviewActionFailed>());
      expect((await tasks.get('task-auth'))!.status, TaskStatus.review);
      // Worktree preserved on failure.
      expect(worktreeManager.cleanedTaskIds, isEmpty);
      final artifacts = await tasks.listArtifacts('task-auth');
      expect(artifacts.any((a) => a.kind == ArtifactKind.data && a.name == 'Push Error'), isTrue);
    });

    test('push rejected → task stays in review, error artifact stored', () async {
      final tempDir = await Directory.systemTemp.createTemp('dartclaw_proj_review_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final fixture = await _putProjectTaskInReview(tasks, 'task-reject');

      final projectService = _projectService(
        project: _makeProject(id: 'my-app', localPath: fixture.projectDir),
      );
      final pushService = FakeRemotePushService(result: const PushRejected('non-fast-forward update rejected'));
      final service = TaskReviewService(
        tasks: tasks,
        remotePushService: pushService,
        projectService: projectService,
        dataDir: tempDir.path,
      );

      final result = await service.review('task-reject', 'accept', trigger: 'user');

      expect(result, const TypeMatcher<ReviewActionFailed>());
      expect((await tasks.get('task-reject'))!.status, TaskStatus.review);
    });

    test('project-backed reject cleans up using the project clone context', () async {
      final fixture = await _putProjectTaskInReview(tasks, 'task-reject-cleanup');

      final worktreeManager = RecordingWorktreeManager();
      final service = TaskReviewService(
        tasks: tasks,

        projectService: _projectService(
          project: _makeProject(id: 'my-app', localPath: fixture.projectDir),
        ),
        worktreeManager: worktreeManager,
      );

      final result = await service.review('task-reject-cleanup', 'reject', trigger: 'user');

      expect(result, const TypeMatcher<ReviewSuccess>());
      expect((await tasks.get('task-reject-cleanup'))!.status, TaskStatus.rejected);
      expect(worktreeManager.cleanedTaskIds, contains('task-reject-cleanup'));
      expect(worktreeManager.forceDeleteBranches, [false]);
      expect(worktreeManager.cleanedProjectIds, contains('my-app'));
    });

    test('_local task accept → existing merge flow (regression)', () async {
      await tasks.create(
        id: 'task-local',
        title: 'Local task',
        description: 'Fix locally.',
        configJson: const {'needsWorktree': true},
        autoStart: true,
        now: DateTime.parse('2026-03-13T10:00:00Z'),
      );
      await tasks.updateFields('task-local', projectId: '_local');
      await tasks.transition('task-local', TaskStatus.running, now: DateTime.parse('2026-03-13T10:05:00Z'));
      await tasks.transition('task-local', TaskStatus.review, now: DateTime.parse('2026-03-13T10:10:00Z'));
      await tasks.updateFields(
        'task-local',
        worktreeJson: const {
          'path': '/tmp/worktree-local',
          'branch': 'dartclaw/task-task-local',
          'createdAt': '2026-03-13T10:00:00.000Z',
        },
      );

      final mergeExecutor = RecordingMergeExecutor(
        result: const MergeSuccess(commitSha: 'abc123', commitMessage: 'task(task-local): Local task'),
      );
      final worktreeManager = RecordingWorktreeManager();
      final service = TaskReviewService(tasks: tasks, mergeExecutor: mergeExecutor, worktreeManager: worktreeManager);

      final result = await service.review('task-local', 'accept', trigger: 'user');

      expect(result, const TypeMatcher<ReviewSuccess>());
      expect(mergeExecutor.callCount, 1);
      expect(worktreeManager.cleanedTaskIds, contains('task-local'));
    });

    test('task without worktreeJson → no push, no merge', () async {
      await tasks.create(
        id: 'task-no-wt',
        title: 'Task without worktree',
        description: 'Research something.',
        autoStart: true,
        now: DateTime.parse('2026-03-13T10:00:00Z'),
      );
      await tasks.updateFields('task-no-wt', projectId: 'my-app');
      await tasks.transition('task-no-wt', TaskStatus.running, now: DateTime.parse('2026-03-13T10:05:00Z'));
      await tasks.transition('task-no-wt', TaskStatus.review, now: DateTime.parse('2026-03-13T10:10:00Z'));

      final pushService = FakeRemotePushService(result: const PushSuccess());
      final service = TaskReviewService(
        tasks: tasks,

        remotePushService: pushService,
        projectService: _projectService(project: _makeProject(id: 'my-app')),
      );

      final result = await service.review('task-no-wt', 'accept', trigger: 'user');

      expect(result, const TypeMatcher<ReviewSuccess>());
      expect(pushService.callCount, 0);
    });

    test('push infrastructure unavailable → ReviewActionFailed', () async {
      await _putProjectTaskInReview(tasks, 'task-no-push');

      final service = TaskReviewService(
        tasks: tasks,

        // No remotePushService or projectService
      );

      final result = await service.review('task-no-push', 'accept', trigger: 'user');

      expect(result, const TypeMatcher<ReviewActionFailed>());
      expect((result as ReviewActionFailed).message, contains('not available'));
      expect((await tasks.get('task-no-push'))!.status, TaskStatus.review);
    });
  });
}

class _BlockingMergeExecutor extends MergeExecutor {
  final MergeResult result;
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  int callCount = 0;

  new({required this.result}) : super(projectDir: '.');

  @override
  Future<MergeResult> merge({
    required String branch,
    required String baseRef,
    required String taskId,
    required String taskTitle,
    String? expectedBaseSha,
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

  new(this.error) : super(projectDir: '.');

  @override
  Future<MergeResult> merge({
    required String branch,
    required String baseRef,
    required String taskId,
    required String taskTitle,
    String? expectedBaseSha,
    MergeStrategy? strategy,
  }) async {
    throw error;
  }
}

// ── Project-backed test helpers ──────────────────────────────────────────────

Project _makeProject({
  required String id,
  PrConfig pr = const PrConfig.defaults(),
  String localPath = '/data/projects/my-app',
}) => Project(
  id: id,
  name: 'My App',
  remoteUrl: 'git@github.com:u/my-app.git',
  localPath: localPath,
  defaultBranch: 'main',
  status: ProjectStatus.ready,
  createdAt: DateTime.now(),
  pr: pr,
);

/// Creates a project-backed task in review state whose worktree is a real
/// linked worktree of a real project, with one commit on the task branch and an
/// `origin/main` that the branch is ahead of.
Future<HostWorktreeTamperFixture> _putProjectTaskInReview(TaskService tasks, String id) async {
  final fixture = await HostWorktreeTamperFixture.create(branch: 'dartclaw/task-$id', worktreeName: id);
  addTearDown(fixture.dispose);
  await HostWorktreeTamperFixture.git(fixture.projectDir, ['update-ref', 'refs/remotes/origin/main', 'main']);
  fixture.write('work.txt');
  await HostWorktreeTamperFixture.git(fixture.worktreePath, ['add', 'work.txt']);
  await HostWorktreeTamperFixture.git(fixture.worktreePath, ['commit', '-q', '-m', 'task work']);
  await tasks.create(
    id: id,
    title: 'Project task $id',
    description: 'Do work.',
    configJson: const {'needsWorktree': true},
    autoStart: true,
    now: DateTime.parse('2026-03-13T10:00:00Z'),
  );
  await tasks.updateFields(id, projectId: 'my-app');
  await tasks.transition(id, TaskStatus.running, now: DateTime.parse('2026-03-13T10:05:00Z'));
  await tasks.transition(id, TaskStatus.review, now: DateTime.parse('2026-03-13T10:10:00Z'));
  await tasks.updateFields(
    id,
    worktreeJson: {'path': fixture.worktreePath, 'branch': fixture.branch, 'createdAt': '2026-03-13T10:00:00.000Z'},
  );
  return fixture;
}

FakeProjectService _projectService({required Project? project}) {
  return FakeProjectService(
    projects: project == null ? const [] : [project],
    includeLocalProjectInGetAll: false,
    defaultProjectId: project?.id,
  );
}
