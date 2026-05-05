@Tags(['component'])
library;

import 'dart:async';
import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        ContextExtractor,
        EventBus,
        GateEvaluator,
        KvService,
        MergeResolveConfig,
        MergeResolveEscalation,
        MessageService,
        OutputConfig,
        StepExecutionContext,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowExecutor,
        WorkflowGitIntegrationBranchResult,
        WorkflowGitPromotionConflict,
        WorkflowGitPromotionSuccess,
        WorkflowGitPublishStrategy,
        WorkflowGitStrategy,
        WorkflowGitWorktreeStrategy,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowSerializationEnactedEvent,
        WorkflowStep,
        WorkflowStepOutputTransformer,
        WorkflowTurnAdapter,
        WorkflowTurnOutcome;
import 'package:dartclaw_server/dartclaw_server.dart' show TaskService;
import 'package:dartclaw_storage/dartclaw_storage.dart'
    show
        SqliteAgentExecutionRepository,
        SqliteExecutionRepositoryTransactor,
        SqliteTaskRepository,
        SqliteWorkflowRunRepository,
        SqliteWorkflowStepExecutionRepository;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  group('S78 H16 serialize-remaining idempotency', () {
    late Directory tempDir;
    late SqliteTaskRepository taskRepository;
    late SqliteAgentExecutionRepository agentExecutionRepository;
    late SqliteWorkflowStepExecutionRepository workflowStepExecutionRepository;
    late SqliteExecutionRepositoryTransactor executionRepositoryTransactor;
    late SqliteWorkflowRunRepository repository;
    late MessageService messageService;
    late KvService kvService;
    late EventBus eventBus;
    late TaskService taskService;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('dartclaw_s78_h16_test_');
      Directory(p.join(tempDir.path, 'sessions')).createSync(recursive: true);

      final db = sqlite3.openInMemory();
      eventBus = EventBus();
      taskRepository = SqliteTaskRepository(db);
      agentExecutionRepository = SqliteAgentExecutionRepository(db, eventBus: eventBus);
      workflowStepExecutionRepository = SqliteWorkflowStepExecutionRepository(db);
      executionRepositoryTransactor = SqliteExecutionRepositoryTransactor(db);
      repository = SqliteWorkflowRunRepository(db);
      taskService = TaskService(
        taskRepository,
        agentExecutionRepository: agentExecutionRepository,
        executionTransactor: executionRepositoryTransactor,
        eventBus: eventBus,
      );
      messageService = MessageService(baseDir: p.join(tempDir.path, 'sessions'));
      kvService = KvService(filePath: p.join(tempDir.path, 'kv.json'));
    });

    tearDown(() async {
      await messageService.dispose();
      await kvService.dispose();
      await eventBus.dispose();
      await taskService.dispose();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('resume after durable event flag does not re-fire serialization event', () async {
      const runEmittedKey = '_merge_resolve.serialize_remaining_event_emitted';
      const phaseKey = '_merge_resolve.pipeline.serialize_remaining_phase';

      final definition = _mergeResolveDefinition(maxParallel: 3);
      final run = _makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext(
        data: {
          'stories': [
            {'id': 'S01'},
            {'id': 'S02'},
            {'id': 'S03'},
          ],
        },
        variables: const {'PROJECT': 'test-project', 'BRANCH': 'main'},
      );

      final firstEvents = <WorkflowSerializationEnactedEvent>[];
      final firstEventSub = eventBus.on<WorkflowSerializationEnactedEvent>().listen(firstEvents.add);
      final releaseThirdTask = Completer<void>();
      final completeFirstRunTasks = eventBus.on<TaskStatusChangedEvent>().where(_isQueued).listen((event) async {
        await _attachWorktree(event.taskId, taskService, tempDir);
        if (await _isThirdStoryTask(event.taskId, taskService)) await releaseThirdTask.future;
        await Future<void>.delayed(Duration.zero);
        await _completeIfActive(event.taskId, taskService);
      });

      final firstExecutor = _makeExecutor(
        taskService: taskService,
        taskRepository: taskRepository,
        eventBus: eventBus,
        repository: repository,
        agentExecutionRepository: agentExecutionRepository,
        workflowStepExecutionRepository: workflowStepExecutionRepository,
        executionRepositoryTransactor: executionRepositoryTransactor,
        messageService: messageService,
        kvService: kvService,
        dir: tempDir,
        turnAdapter: _adapter(conflictingStoryIds: {'S02'}),
        outputTransformer: _codingWithMergeResolveFailTransformer(),
      );

      final firstRunFuture = firstExecutor.execute(run, definition, context);
      final crashSnapshot = await _waitForCrashSnapshot(repository, run.id, runEmittedKey, phaseKey);
      expect(firstEvents, hasLength(1));
      expect(_contextData(crashSnapshot)[runEmittedKey], isTrue);
      expect(_contextData(crashSnapshot)[phaseKey], isNot(equals('drained')));

      releaseThirdTask.complete();
      await firstRunFuture;
      await completeFirstRunTasks.cancel();
      await firstEventSub.cancel();

      await eventBus.dispose();
      await taskService.dispose();

      final resumedDb = sqlite3.openInMemory();
      eventBus = EventBus();
      taskRepository = SqliteTaskRepository(resumedDb);
      agentExecutionRepository = SqliteAgentExecutionRepository(resumedDb, eventBus: eventBus);
      workflowStepExecutionRepository = SqliteWorkflowStepExecutionRepository(resumedDb);
      executionRepositoryTransactor = SqliteExecutionRepositoryTransactor(resumedDb);
      repository = SqliteWorkflowRunRepository(resumedDb);
      taskService = TaskService(
        taskRepository,
        agentExecutionRepository: agentExecutionRepository,
        executionTransactor: executionRepositoryTransactor,
        eventBus: eventBus,
      );

      final resumedRun = crashSnapshot.copyWith(
        status: WorkflowRunStatus.running,
        completedAt: null,
        errorMessage: null,
        updatedAt: DateTime.now(),
      );
      await repository.insert(resumedRun);

      final secondEvents = <WorkflowSerializationEnactedEvent>[];
      final secondEventSub = eventBus.on<WorkflowSerializationEnactedEvent>().listen(secondEvents.add);
      final completeSecondRunTasks = eventBus.on<TaskStatusChangedEvent>().where(_isQueued).listen((event) async {
        await _attachWorktree(event.taskId, taskService, tempDir);
        await Future<void>.delayed(Duration.zero);
        await _completeIfActive(event.taskId, taskService);
      });

      final secondExecutor = _makeExecutor(
        taskService: taskService,
        taskRepository: taskRepository,
        eventBus: eventBus,
        repository: repository,
        agentExecutionRepository: agentExecutionRepository,
        workflowStepExecutionRepository: workflowStepExecutionRepository,
        executionRepositoryTransactor: executionRepositoryTransactor,
        messageService: messageService,
        kvService: kvService,
        dir: tempDir,
        turnAdapter: _adapter(conflictingStoryIds: {'S02'}),
        outputTransformer: _codingWithMergeResolveFailTransformer(),
      );

      await secondExecutor.execute(resumedRun, definition, WorkflowContext.fromJson(crashSnapshot.contextJson));
      await completeSecondRunTasks.cancel();
      await secondEventSub.cancel();

      expect(secondEvents, isEmpty);
      expect(firstEvents.length + secondEvents.length, equals(1));
      final persistedRun = await repository.getById(run.id);
      expect(_contextData(persistedRun)[runEmittedKey], isTrue, reason: '${persistedRun?.contextJson}');
      expect(_contextData(persistedRun)[phaseKey], equals('drained'));
    });
  });
}

bool _isQueued(TaskStatusChangedEvent event) => event.newStatus == TaskStatus.queued;

WorkflowDefinition _mergeResolveDefinition({required int maxParallel}) {
  return WorkflowDefinition(
    name: 'mr-wf',
    description: 'Merge-resolve test workflow',
    project: '{{PROJECT}}',
    gitStrategy: const WorkflowGitStrategy(
      integrationBranch: true,
      worktree: WorkflowGitWorktreeStrategy(mode: 'per-map-item'),
      promotion: 'merge',
      publish: WorkflowGitPublishStrategy(enabled: false),
      mergeResolve: MergeResolveConfig(
        enabled: true,
        maxAttempts: 1,
        escalation: MergeResolveEscalation.serializeRemaining,
      ),
    ),
    steps: [
      WorkflowStep(
        id: 'pipeline',
        name: 'Story Pipeline',
        type: 'foreach',
        mapOver: 'stories',
        maxParallel: maxParallel,
        foreachSteps: const ['implement'],
        outputs: const {'results': OutputConfig()},
      ),
      WorkflowStep(id: 'implement', name: 'Implement Story', prompts: const ['Implement {{map.item.id}}']),
    ],
  );
}

WorkflowRun _makeRun(WorkflowDefinition definition) {
  final now = DateTime.now();
  return WorkflowRun(
    id: 'run-h16',
    definitionName: definition.name,
    status: WorkflowRunStatus.running,
    startedAt: now,
    updatedAt: now,
    currentStepIndex: 0,
    definitionJson: definition.toJson(),
    variablesJson: const {'PROJECT': 'test-project', 'BRANCH': 'main'},
  );
}

WorkflowExecutor _makeExecutor({
  required TaskService taskService,
  required SqliteTaskRepository taskRepository,
  required EventBus eventBus,
  required SqliteWorkflowRunRepository repository,
  required SqliteAgentExecutionRepository agentExecutionRepository,
  required SqliteWorkflowStepExecutionRepository workflowStepExecutionRepository,
  required SqliteExecutionRepositoryTransactor executionRepositoryTransactor,
  required MessageService messageService,
  required KvService kvService,
  required Directory dir,
  required WorkflowTurnAdapter turnAdapter,
  required WorkflowStepOutputTransformer outputTransformer,
}) {
  return WorkflowExecutor(
    executionContext: StepExecutionContext(
      taskService: taskService,
      eventBus: eventBus,
      kvService: kvService,
      repository: repository,
      gateEvaluator: GateEvaluator(),
      contextExtractor: ContextExtractor(
        taskService: taskService,
        messageService: messageService,
        dataDir: dir.path,
        workflowStepExecutionRepository: workflowStepExecutionRepository,
      ),
      turnAdapter: turnAdapter,
      outputTransformer: outputTransformer,
      taskRepository: taskRepository,
      agentExecutionRepository: agentExecutionRepository,
      workflowStepExecutionRepository: workflowStepExecutionRepository,
      executionTransactor: executionRepositoryTransactor,
    ),
    dataDir: dir.path,
  );
}

WorkflowTurnAdapter _adapter({required Set<String> conflictingStoryIds}) {
  return WorkflowTurnAdapter(
    reserveTurn: (_) => Future.value('turn-1'),
    executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
    waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
    initializeWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async =>
        const WorkflowGitIntegrationBranchResult(integrationBranch: 'dartclaw/integration/test'),
    promoteWorkflowBranch:
        ({
          required runId,
          required projectId,
          required branch,
          required integrationBranch,
          required strategy,
          String? storyId,
        }) async {
          if (storyId != null && conflictingStoryIds.contains(storyId)) {
            return const WorkflowGitPromotionConflict(conflictingFiles: ['lib/story.dart'], details: 'conflict');
          }
          return WorkflowGitPromotionSuccess(commitSha: 'sha-${storyId ?? 'x'}');
        },
    cleanupWorktreeForRetry: ({required projectId, required branch, required preAttemptSha}) async => null,
    captureWorkflowBranchSha: ({required projectId, required branch}) async => 'sha-pre',
  );
}

WorkflowStepOutputTransformer _codingWithMergeResolveFailTransformer() {
  return (run, definition, step, task, outputs) {
    if (step.id.startsWith('_merge_resolve_')) {
      return {
        'merge_resolve.outcome': 'failed',
        'merge_resolve.error_message': 'simulated failure',
        'merge_resolve.conflicted_files': <String>['lib/story.dart'],
        'merge_resolve.resolution_summary': '',
      };
    }
    final result = Map<String, dynamic>.from(outputs);
    if (step.type == 'coding') {
      result['${step.id}.branch'] = 'story-branch-${task.id}';
    }
    return result;
  };
}

Future<void> _attachWorktree(String taskId, TaskService taskService, Directory dir) async {
  final task = await taskService.get(taskId);
  if (task == null || task.status.terminal) return;
  await taskService.updateFields(
    taskId,
    worktreeJson: {
      'path': p.join(dir.path, 'worktrees', taskId),
      'branch': 'story-branch-$taskId',
      'createdAt': DateTime.now().toIso8601String(),
    },
  );
}

Future<bool> _isThirdStoryTask(String taskId, TaskService taskService) async {
  final task = await taskService.get(taskId);
  return task?.workflowStepExecution?.stepId == 'implement' && task?.workflowStepExecution?.mapIterationIndex == 2;
}

Future<void> _completeIfActive(String taskId, TaskService taskService) async {
  final task = await taskService.get(taskId);
  if (task == null || task.status.terminal) return;
  try {
    if (task.status == TaskStatus.queued) {
      await taskService.transition(taskId, TaskStatus.running, trigger: 'test');
    }
    final runningTask = await taskService.get(taskId);
    if (runningTask == null || runningTask.status.terminal) return;
    if (runningTask.status == TaskStatus.running) {
      await taskService.transition(taskId, TaskStatus.review, trigger: 'test');
    }
    final reviewTask = await taskService.get(taskId);
    if (reviewTask == null || reviewTask.status.terminal) return;
    if (reviewTask.status == TaskStatus.review) {
      await taskService.transition(taskId, TaskStatus.accepted, trigger: 'test');
    }
  } on StateError {
    // Drain cancellation can win the race in the simulated crash window.
  }
}

Future<WorkflowRun> _waitForCrashSnapshot(
  SqliteWorkflowRunRepository repository,
  String runId,
  String runEmittedKey,
  String phaseKey,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  WorkflowRun? lastRun;
  while (DateTime.now().isBefore(deadline)) {
    final run = await repository.getById(runId);
    lastRun = run;
    final data = _contextData(run);
    if (data[runEmittedKey] == true && data[phaseKey] != 'drained') {
      return run!;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError(
    'Timed out waiting for durable serialize-remaining crash snapshot; '
    'status=${lastRun?.status.name}, context=${lastRun?.contextJson}',
  );
}

Map<String, dynamic> _contextData(WorkflowRun? run) {
  final contextJson = run?.contextJson;
  if (contextJson == null) return const <String, dynamic>{};
  final data = contextJson['data'];
  return data is Map ? Map<String, dynamic>.from(data) : Map<String, dynamic>.from(contextJson);
}
