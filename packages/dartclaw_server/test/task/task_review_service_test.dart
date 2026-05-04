import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
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
      await putTaskInReview(tasks, 'task-1', title: 'Fix login');
      final service = TaskReviewService(tasks: tasks);
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

      final result = await service.review('task-1', 'reject');

      expect(result, const TypeMatcher<ReviewSuccess>());
      expect((await tasks.get('task-1'))!.status, TaskStatus.rejected);
    });

    test('pushes tasks back to running with comment metadata', () async {
      await putTaskInReview(tasks, 'task-1', title: 'Fix login');
      final service = TaskReviewService(tasks: tasks);

      final result = await service.review('task-1', 'push_back', comment: 'try again');

      expect(result, const TypeMatcher<ReviewSuccess>());
      final updated = (await tasks.get('task-1'))!;
      expect(updated.status, TaskStatus.running);
      expect(updated.configJson['pushBackCount'], 1);
      expect(updated.configJson['pushBackComment'], 'try again');
    });

    test('rejects push_back without a comment', () async {
      await putTaskInReview(tasks, 'task-1', title: 'Fix login');
      final service = TaskReviewService(tasks: tasks);

      final result = await service.review('task-1', 'push_back');

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

      await service.review('task-1', 'push_back', comment: 'revise the auth logic');
      await Future<void>.delayed(Duration.zero);

      expect(statusEvents, hasLength(1));
      expect(statusEvents.single.oldStatus, TaskStatus.review);
      expect(statusEvents.single.newStatus, TaskStatus.running);
    });

    test('push_back invokes PushBackFeedbackDelivery callback', () async {
      await putTaskInReview(tasks, 'task-1', title: 'Fix login', sessionKey: 'agent:main:task:task-1');
      final deliveries = <(String taskId, String feedback)>[];
      final service = TaskReviewService(
        tasks: tasks,

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
      await putTaskInReview(tasks, 'task-1', title: 'Fix login');
      final service = TaskReviewService(
        tasks: tasks,

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
      await putTaskInReview(tasks, 'task-1', title: 'Fix login', sessionKey: 'agent:main:task:task-1');
      String? capturedComment;
      final service = TaskReviewService(
        tasks: tasks,

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
      final mergeExecutor = _RecordingMergeExecutor(
        result: const MergeSuccess(commitSha: 'abc123', commitMessage: 'task(task-1): Fix login'),
      );
      final worktreeManager = _RecordingWorktreeManager();
      final taskFileGuard = _RecordingTaskFileGuard()..register('task-1', '/tmp/worktree');
      final service = TaskReviewService(
        tasks: tasks,

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

      final result = await service.review('task-1', 'accept');

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

    test('accepting workflow-owned git review tasks skips merge and cleanup', () async {
      await tasks.create(
        id: 'task-workflow-review',
        title: 'Workflow review task',
        description: 'Workflow review task',
        type: TaskType.coding,
        autoStart: true,
        workflowRunId: 'run-123',
        now: DateTime.parse('2026-03-13T10:00:00Z'),
        configJson: const {
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
      final mergeExecutor = _RecordingMergeExecutor(
        result: const MergeSuccess(commitSha: 'abc123', commitMessage: 'task(task-workflow-review): accept'),
      );
      final worktreeManager = _RecordingWorktreeManager();
      final service = TaskReviewService(tasks: tasks, mergeExecutor: mergeExecutor, worktreeManager: worktreeManager);

      final result = await service.review('task-workflow-review', 'accept');

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
      final mergeExecutor = _RecordingMergeExecutor(
        result: const MergeConflict(conflictingFiles: ['lib/main.dart'], details: 'Automatic merge failed'),
      );
      final worktreeManager = _RecordingWorktreeManager();
      final service = TaskReviewService(
        tasks: tasks,

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
      final service = TaskReviewService(tasks: tasks);

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
      final service = TaskReviewService(tasks: tasks);

      final result = await service.review('task-1', 'accept');

      expect(result, const TypeMatcher<ReviewInvalidTransition>());
      expect((result as ReviewInvalidTransition).currentStatus, TaskStatus.draft);
    });

    test('returns invalid request for unknown actions', () async {
      final service = TaskReviewService(tasks: tasks);

      final result = await service.review('task-1', 'ship_it');

      expect(result, const TypeMatcher<ReviewInvalidRequest>());
      expect((result as ReviewInvalidRequest).message, 'action must be one of: accept, reject, push_back');
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

      final result = await service.review('task-1', 'accept');

      expect(result, const TypeMatcher<ReviewActionFailed>());
      expect((result as ReviewActionFailed).message, 'Review action failed. Please try again or use the web UI.');
      expect((await tasks.get('task-1'))!.status, TaskStatus.review);
    });
  });

  group('TaskEventRecorder — push-back events', () {
    late Database evtDb;
    late TaskEventService eventService;
    late TaskEventRecorder recorder;

    setUp(() {
      evtDb = openTaskDbInMemory();
      eventService = TaskEventService(evtDb);
      recorder = TaskEventRecorder(eventService: eventService);
    });

    tearDown(() {
      evtDb.close();
    });

    test('push_back action records a pushBack event with the comment', () async {
      await putTaskInReview(tasks, 'task-1', title: 'Review task');
      final service = TaskReviewService(tasks: tasks, eventRecorder: recorder);

      await service.review('task-1', 'push_back', comment: 'Please fix the tests');

      final events = eventService.listForTask('task-1');
      expect(events, hasLength(1));
      expect(events[0].kind.name, 'pushBack');
      expect(events[0].details['comment'], 'Please fix the tests');
    });

    test('accept action does not record a pushBack event', () async {
      await putTaskInReview(tasks, 'task-1', title: 'Review task');
      final service = TaskReviewService(tasks: tasks, eventRecorder: recorder);

      await service.review('task-1', 'accept');

      final events = eventService.listForTask('task-1', kind: const PushBack());
      expect(events, isEmpty);
    });

    test('null eventRecorder does not affect push_back behavior', () async {
      await putTaskInReview(tasks, 'task-2', title: 'Another task');
      final service = TaskReviewService(tasks: tasks);

      final result = await service.review('task-2', 'push_back', comment: 'try again');

      expect(result, isA<ReviewSuccess>());
    });
  });

  group('project-backed accept', () {
    test('push + PR created → task accepted, PR URL artifact stored', () async {
      final tempDir = await Directory.systemTemp.createTemp('dartclaw_proj_review_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      await _putProjectTaskInReview(tasks, 'task-proj');

      final projectService = _projectService(
        project: _makeProject(
          id: 'my-app',
          pr: const PrConfig(strategy: PrStrategy.githubPr),
        ),
      );
      final pushService = _FakeRemotePushService(result: const PushSuccess());
      final prCreator = _FakePrCreator(result: const PrCreated('https://github.com/u/r/pull/42'));
      final worktreeManager = _RecordingWorktreeManager();
      final gitRunner = _FakeGitRunner.cleanBranchDiff();
      final service = TaskReviewService(
        tasks: tasks,
        remotePushService: pushService,
        prCreator: prCreator,
        projectService: projectService,
        worktreeManager: worktreeManager,
        dataDir: tempDir.path,
        processRunner: gitRunner.run,
      );

      final result = await service.review('task-proj', 'accept');

      expect(result, const TypeMatcher<ReviewSuccess>());
      expect((await tasks.get('task-proj'))!.status, TaskStatus.accepted);
      final artifacts = await tasks.listArtifacts('task-proj');
      expect(artifacts, isNotEmpty);
      final prArtifact = artifacts.firstWhere((a) => a.kind == ArtifactKind.pr);
      expect(prArtifact.name, 'Pull Request');
      expect(prArtifact.path, 'https://github.com/u/r/pull/42');
      expect(worktreeManager.cleanedTaskIds, contains('task-proj'));
      expect(worktreeManager.cleanedProjectIds, contains('my-app'));
    });

    test('branch-only strategy → task accepted, branch name artifact stored', () async {
      final tempDir = await Directory.systemTemp.createTemp('dartclaw_proj_review_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      await _putProjectTaskInReview(tasks, 'task-branch');

      final projectService = _projectService(
        project: _makeProject(
          id: 'my-app',
          pr: const PrConfig(strategy: PrStrategy.branchOnly),
        ),
      );
      final pushService = _FakeRemotePushService(result: const PushSuccess());
      final gitRunner = _FakeGitRunner.cleanBranchDiff();
      final service = TaskReviewService(
        tasks: tasks,
        remotePushService: pushService,
        projectService: projectService,
        dataDir: tempDir.path,
        processRunner: gitRunner.run,
      );

      final result = await service.review('task-branch', 'accept');

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

      await _putProjectTaskInReview(tasks, 'task-dirty');

      final projectService = _projectService(
        project: _makeProject(
          id: 'my-app',
          pr: const PrConfig(strategy: PrStrategy.branchOnly),
        ),
      );
      final pushService = _FakeRemotePushService(result: const PushSuccess());
      final gitRunner = _FakeGitRunner.withResponses({
        'status --porcelain --untracked-files=all': _gitResult('?? notes/spec-publish.md\n'),
        'add -A': _gitResult(''),
        'commit -m task(task-dirty): Project task task-dirty': _gitResult('[branch abc123] commit\n'),
        'rev-parse --verify origin/main': _gitResult('origin/main\n'),
        'diff --quiet origin/main...HEAD': _gitResult('', exitCode: 1),
      });
      final service = TaskReviewService(
        tasks: tasks,
        remotePushService: pushService,
        projectService: projectService,
        dataDir: tempDir.path,
        processRunner: gitRunner.run,
      );

      final result = await service.review('task-dirty', 'accept');

      expect(result, const TypeMatcher<ReviewSuccess>());
      expect(pushService.callCount, 1);
      expect(gitRunner.commands, contains('add -A'));
      expect(gitRunner.commands, contains('commit -m task(task-dirty): Project task task-dirty'));
    });

    test('gh not found → push succeeds, warning artifact, task accepted', () async {
      final tempDir = await Directory.systemTemp.createTemp('dartclaw_proj_review_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      await _putProjectTaskInReview(tasks, 'task-gh');

      final projectService = _projectService(
        project: _makeProject(
          id: 'my-app',
          pr: const PrConfig(strategy: PrStrategy.githubPr),
        ),
      );
      final pushService = _FakeRemotePushService(result: const PushSuccess());
      final prCreator = _FakePrCreator(result: const PrGhNotFound('gh not found. Create PR manually.'));
      final gitRunner = _FakeGitRunner.cleanBranchDiff();
      final service = TaskReviewService(
        tasks: tasks,
        remotePushService: pushService,
        prCreator: prCreator,
        projectService: projectService,
        dataDir: tempDir.path,
        processRunner: gitRunner.run,
      );

      final result = await service.review('task-gh', 'accept');

      expect(result, const TypeMatcher<ReviewSuccess>());
      expect((await tasks.get('task-gh'))!.status, TaskStatus.accepted);
      final artifacts = await tasks.listArtifacts('task-gh');
      final prArtifact = artifacts.firstWhere((a) => a.kind == ArtifactKind.pr);
      expect(prArtifact.name, 'PR Instructions');
    });

    test('PR creation failure keeps task in review and preserves the worktree', () async {
      final tempDir = await Directory.systemTemp.createTemp('dartclaw_proj_review_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      await _putProjectTaskInReview(tasks, 'task-pr-failure');

      final projectService = _projectService(
        project: _makeProject(
          id: 'my-app',
          pr: const PrConfig(strategy: PrStrategy.githubPr),
        ),
      );
      final pushService = _FakeRemotePushService(result: const PushSuccess());
      final prCreator = _FakePrCreator(
        result: const PrCreationFailed(
          error: 'GitHub PR creation failed (HTTP 422)',
          details: 'A pull request already exists for this branch.',
        ),
      );
      final worktreeManager = _RecordingWorktreeManager();
      final gitRunner = _FakeGitRunner.cleanBranchDiff();
      final service = TaskReviewService(
        tasks: tasks,
        remotePushService: pushService,
        prCreator: prCreator,
        projectService: projectService,
        worktreeManager: worktreeManager,
        dataDir: tempDir.path,
        processRunner: gitRunner.run,
      );

      final result = await service.review('task-pr-failure', 'accept');

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

      await _putProjectTaskInReview(tasks, 'task-auth');

      final projectService = _projectService(project: _makeProject(id: 'my-app'));
      final pushService = _FakeRemotePushService(
        result: const PushAuthFailure('Authentication denied. Check credentials.'),
      );
      final worktreeManager = _RecordingWorktreeManager();
      final gitRunner = _FakeGitRunner.cleanBranchDiff();
      final service = TaskReviewService(
        tasks: tasks,
        remotePushService: pushService,
        projectService: projectService,
        worktreeManager: worktreeManager,
        dataDir: tempDir.path,
        processRunner: gitRunner.run,
      );

      final result = await service.review('task-auth', 'accept');

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

      await _putProjectTaskInReview(tasks, 'task-reject');

      final projectService = _projectService(project: _makeProject(id: 'my-app'));
      final pushService = _FakeRemotePushService(result: const PushRejected('non-fast-forward update rejected'));
      final gitRunner = _FakeGitRunner.cleanBranchDiff();
      final service = TaskReviewService(
        tasks: tasks,
        remotePushService: pushService,
        projectService: projectService,
        dataDir: tempDir.path,
        processRunner: gitRunner.run,
      );

      final result = await service.review('task-reject', 'accept');

      expect(result, const TypeMatcher<ReviewActionFailed>());
      expect((await tasks.get('task-reject'))!.status, TaskStatus.review);
    });

    test('project-backed reject cleans up using the project clone context', () async {
      await _putProjectTaskInReview(tasks, 'task-reject-cleanup');

      final worktreeManager = _RecordingWorktreeManager();
      final service = TaskReviewService(
        tasks: tasks,

        projectService: _projectService(project: _makeProject(id: 'my-app')),
        worktreeManager: worktreeManager,
      );

      final result = await service.review('task-reject-cleanup', 'reject');

      expect(result, const TypeMatcher<ReviewSuccess>());
      expect((await tasks.get('task-reject-cleanup'))!.status, TaskStatus.rejected);
      expect(worktreeManager.cleanedTaskIds, contains('task-reject-cleanup'));
      expect(worktreeManager.cleanedProjectIds, contains('my-app'));
    });

    test('_local task accept → existing merge flow (regression)', () async {
      await tasks.create(
        id: 'task-local',
        title: 'Local task',
        description: 'Fix locally.',
        type: TaskType.coding,
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

      final mergeExecutor = _RecordingMergeExecutor(
        result: const MergeSuccess(commitSha: 'abc123', commitMessage: 'task(task-local): Local task'),
      );
      final worktreeManager = _RecordingWorktreeManager();
      final service = TaskReviewService(tasks: tasks, mergeExecutor: mergeExecutor, worktreeManager: worktreeManager);

      final result = await service.review('task-local', 'accept');

      expect(result, const TypeMatcher<ReviewSuccess>());
      expect(mergeExecutor.callCount, 1);
      expect(worktreeManager.cleanedTaskIds, contains('task-local'));
    });

    test('task without worktreeJson → no push, no merge', () async {
      await tasks.create(
        id: 'task-no-wt',
        title: 'Research task',
        description: 'Research something.',
        type: TaskType.research,
        autoStart: true,
        now: DateTime.parse('2026-03-13T10:00:00Z'),
      );
      await tasks.updateFields('task-no-wt', projectId: 'my-app');
      await tasks.transition('task-no-wt', TaskStatus.running, now: DateTime.parse('2026-03-13T10:05:00Z'));
      await tasks.transition('task-no-wt', TaskStatus.review, now: DateTime.parse('2026-03-13T10:10:00Z'));

      final pushService = _FakeRemotePushService(result: const PushSuccess());
      final service = TaskReviewService(
        tasks: tasks,

        remotePushService: pushService,
        projectService: _projectService(project: _makeProject(id: 'my-app')),
      );

      final result = await service.review('task-no-wt', 'accept');

      expect(result, const TypeMatcher<ReviewSuccess>());
      expect(pushService.callCount, 0);
    });

    test('push infrastructure unavailable → ReviewActionFailed', () async {
      await _putProjectTaskInReview(tasks, 'task-no-push');

      final service = TaskReviewService(
        tasks: tasks,

        // No remotePushService or projectService
      );

      final result = await service.review('task-no-push', 'accept');

      expect(result, const TypeMatcher<ReviewActionFailed>());
      expect((result as ReviewActionFailed).message, contains('not available'));
      expect((await tasks.get('task-no-push'))!.status, TaskStatus.review);
    });
  });
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
    String? expectedBaseSha,
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

  _ThrowingMergeExecutor(this.error) : super(projectDir: '.');

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

class _RecordingWorktreeManager extends WorktreeManager {
  final List<String> cleanedTaskIds = [];
  final List<String?> cleanedProjectIds = [];

  _RecordingWorktreeManager() : super(dataDir: '/tmp', projectDir: '/tmp');

  @override
  Future<void> cleanup(String taskId, {Project? project}) async {
    cleanedTaskIds.add(taskId);
    cleanedProjectIds.add(project?.id);
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

// ── Project-backed test helpers ──────────────────────────────────────────────

Project _makeProject({required String id, PrConfig pr = const PrConfig.defaults()}) => Project(
  id: id,
  name: 'My App',
  remoteUrl: 'git@github.com:u/my-app.git',
  localPath: '/data/projects/my-app',
  defaultBranch: 'main',
  status: ProjectStatus.ready,
  createdAt: DateTime.now(),
  pr: pr,
);

/// Creates a project-backed task in review state with a worktree.
Future<void> _putProjectTaskInReview(TaskService tasks, String id) async {
  await tasks.create(
    id: id,
    title: 'Project task $id',
    description: 'Do work.',
    type: TaskType.coding,
    autoStart: true,
    now: DateTime.parse('2026-03-13T10:00:00Z'),
  );
  await tasks.updateFields(id, projectId: 'my-app');
  await tasks.transition(id, TaskStatus.running, now: DateTime.parse('2026-03-13T10:05:00Z'));
  await tasks.transition(id, TaskStatus.review, now: DateTime.parse('2026-03-13T10:10:00Z'));
  await tasks.updateFields(
    id,
    worktreeJson: {
      'path': '/data/worktrees/$id',
      'branch': 'dartclaw/task-$id',
      'createdAt': '2026-03-13T10:00:00.000Z',
    },
  );
}

FakeProjectService _projectService({required Project? project}) {
  return FakeProjectService(
    projects: project == null ? const [] : [project],
    includeLocalProjectInGetAll: false,
    defaultProjectId: project?.id,
  );
}

class _FakeRemotePushService extends RemotePushService {
  final PushResult result;
  int callCount = 0;

  _FakeRemotePushService({required this.result});

  @override
  Future<PushResult> push({required Project project, required String branch}) async {
    callCount++;
    return result;
  }
}

class _FakePrCreator extends PrCreator {
  final PrCreationResult result;

  _FakePrCreator({required this.result});

  @override
  Future<PrCreationResult> create({required Project project, required Task task, required String branch}) async =>
      result;
}

class _FakeGitRunner {
  final Map<String, ProcessResult> _responses;
  final List<String> commands = [];

  _FakeGitRunner._(this._responses);

  factory _FakeGitRunner.withResponses(Map<String, ProcessResult> responses) => _FakeGitRunner._(responses);

  factory _FakeGitRunner.cleanBranchDiff() => _FakeGitRunner.withResponses({
    'status --porcelain --untracked-files=all': _gitResult(''),
    'rev-parse --verify origin/main': _gitResult('origin/main\n'),
    'diff --quiet origin/main...HEAD': _gitResult('', exitCode: 1),
  });

  Future<ProcessResult> run(String executable, List<String> arguments, {String? workingDirectory}) async {
    final key = arguments.join(' ');
    commands.add(key);
    return _responses[key] ?? _gitResult('');
  }
}

ProcessResult _gitResult(String stdout, {String stderr = '', int exitCode = 0}) {
  return ProcessResult(0, exitCode, stdout, stderr);
}
