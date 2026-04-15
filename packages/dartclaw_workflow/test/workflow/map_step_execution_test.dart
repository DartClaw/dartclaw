import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_models/dartclaw_models.dart' show SessionType;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        ArtifactKind,
        EventBus,
        KvService,
        MapIterationCompletedEvent,
        MapStepCompletedEvent,
        MessageService,
        SessionService,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowGitBootstrapResult,
        WorkflowGitPromotionSuccess,
        WorkflowGitPublishStrategy,
        WorkflowGitStrategy,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowStep;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show ContextExtractor, GateEvaluator, WorkflowExecutor, WorkflowTurnAdapter, WorkflowTurnOutcome;
import 'package:dartclaw_server/dartclaw_server.dart' show TaskService;
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

String _workflowContext(Map<String, Object?> values) => '<workflow-context>${jsonEncode(values)}</workflow-context>';

void main() {
  late Directory tempDir;
  late String sessionsDir;
  late TaskService taskService;
  late MessageService messageService;
  late SessionService sessionService;
  late KvService kvService;
  late SqliteWorkflowRunRepository repository;
  late EventBus eventBus;
  late WorkflowExecutor executor;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_map_step_test_');
    sessionsDir = p.join(tempDir.path, 'sessions');
    Directory(sessionsDir).createSync(recursive: true);

    final db = sqlite3.openInMemory();
    eventBus = EventBus();
    taskService = TaskService(SqliteTaskRepository(db), eventBus: eventBus);
    repository = SqliteWorkflowRunRepository(db);
    sessionService = SessionService(baseDir: sessionsDir);
    messageService = MessageService(baseDir: sessionsDir);
    kvService = KvService(filePath: p.join(tempDir.path, 'kv.json'));

    executor = WorkflowExecutor(
      taskService: taskService,
      eventBus: eventBus,
      kvService: kvService,
      repository: repository,
      gateEvaluator: GateEvaluator(),
      contextExtractor: ContextExtractor(
        taskService: taskService,
        messageService: messageService,
        dataDir: tempDir.path,
      ),
      dataDir: tempDir.path,
    );
  });

  tearDown(() async {
    await taskService.dispose();
    await messageService.dispose();
    await kvService.dispose();
    await eventBus.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  WorkflowRun makeRun(WorkflowDefinition definition) {
    final now = DateTime.now();
    return WorkflowRun(
      id: 'run-1',
      definitionName: definition.name,
      status: WorkflowRunStatus.running,
      startedAt: now,
      updatedAt: now,
      currentStepIndex: 0,
      definitionJson: definition.toJson(),
    );
  }

  /// Simulates task completion: queued → running → terminal.
  Future<void> completeTask(String taskId, {TaskStatus status = TaskStatus.accepted}) async {
    try {
      await taskService.transition(taskId, TaskStatus.running, trigger: 'test');
    } on StateError {
      // May already be running.
    }
    if (status == TaskStatus.accepted || status == TaskStatus.rejected) {
      try {
        await taskService.transition(taskId, TaskStatus.review, trigger: 'test');
      } on StateError {
        // May already be in review.
      }
    }
    await taskService.transition(taskId, status, trigger: 'test');
  }

  group('core map execution', () {
    test('workflow-owned map coding task can complete from review state', () async {
      final definition = WorkflowDefinition(
        name: 'map-review-ready',
        description: 'Workflow-owned map tasks should unblock from review.',
        gitStrategy: const WorkflowGitStrategy(
          bootstrap: true,
          worktree: 'per-map-item',
          promotion: 'merge',
          publish: WorkflowGitPublishStrategy(enabled: false),
        ),
        steps: const [
          WorkflowStep(
            id: 'implement',
            name: 'Implement Stories',
            type: 'coding',
            project: 'my-project',
            prompts: ['Implement {{map.item.id}}'],
            mapOver: 'stories',
            maxParallel: 1,
            contextOutputs: ['story_result'],
          ),
        ],
      );

      final run = WorkflowRun(
        id: 'map-review-ready-run',
        definitionName: definition.name,
        status: WorkflowRunStatus.running,
        startedAt: DateTime.now(),
        updatedAt: DateTime.now(),
        variablesJson: const {'PROJECT': 'my-project', 'BRANCH': 'main'},
        definitionJson: definition.toJson(),
      );
      await repository.insert(run);

      final context = WorkflowContext(
        data: {
          'stories': [
            {'id': 'S01'},
          ],
        },
        variables: const {'PROJECT': 'my-project', 'BRANCH': 'main'},
      );

      final runtimeExecutor = WorkflowExecutor(
        taskService: taskService,
        eventBus: eventBus,
        kvService: kvService,
        repository: repository,
        gateEvaluator: GateEvaluator(),
        contextExtractor: ContextExtractor(
          taskService: taskService,
          messageService: messageService,
          dataDir: tempDir.path,
        ),
        dataDir: tempDir.path,
        turnAdapter: WorkflowTurnAdapter(
          reserveTurn: (_) => Future.value('turn-1'),
          executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
          waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
          bootstrapWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async =>
              const WorkflowGitBootstrapResult(integrationBranch: 'dartclaw/integration/test'),
          promoteWorkflowBranch:
              ({
                required runId,
                required projectId,
                required branch,
                required integrationBranch,
                required strategy,
                String? storyId,
              }) async => const WorkflowGitPromotionSuccess(commitSha: 'abc123'),
        ),
      );

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        final task = await taskService.get(e.taskId);
        if (task == null) return;
        await taskService.updateFields(
          task.id,
          worktreeJson: {
            'path': p.join(tempDir.path, 'worktrees', task.id),
            'branch': 'story-s01',
            'createdAt': DateTime.now().toIso8601String(),
          },
        );
        try {
          await taskService.transition(task.id, TaskStatus.running, trigger: 'test');
        } on StateError {
          // Already running.
        }
        await taskService.transition(task.id, TaskStatus.review, trigger: 'test');
      });

      await runtimeExecutor.execute(run, definition, context);
      await sub.cancel();

      final finalRun = await repository.getById('map-review-ready-run');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('runtime quick review runs before promotion for per-map-item coding stories', () async {
      final promotedStoryIds = <String?>[];
      final definition = WorkflowDefinition(
        name: 'plan-runtime-review',
        description: 'Runtime quick review sequencing',
        gitStrategy: const WorkflowGitStrategy(
          bootstrap: true,
          worktree: 'per-map-item',
          quickReview: true,
          promotion: 'merge',
          publish: WorkflowGitPublishStrategy(enabled: false),
        ),
        steps: const [
          WorkflowStep(
            id: 'implement',
            name: 'Implement Stories',
            type: 'coding',
            project: 'my-project',
            prompts: ['Implement {{map.item.id}}'],
            mapOver: 'stories',
            maxParallel: 1,
            contextOutputs: ['story_result'],
          ),
        ],
      );

      final run = WorkflowRun(
        id: 'runtime-review-run',
        definitionName: definition.name,
        status: WorkflowRunStatus.running,
        startedAt: DateTime.now(),
        updatedAt: DateTime.now(),
        variablesJson: const {'PROJECT': 'my-project', 'BRANCH': 'main'},
        definitionJson: definition.toJson(),
      );
      await repository.insert(run);

      final context = WorkflowContext(
        data: {
          'stories': [
            {'id': 'S01'},
          ],
        },
        variables: const {'PROJECT': 'my-project', 'BRANCH': 'main'},
      );

      final runtimeExecutor = WorkflowExecutor(
        taskService: taskService,
        eventBus: eventBus,
        kvService: kvService,
        repository: repository,
        gateEvaluator: GateEvaluator(),
        contextExtractor: ContextExtractor(
          taskService: taskService,
          messageService: messageService,
          dataDir: tempDir.path,
        ),
        dataDir: tempDir.path,
        turnAdapter: WorkflowTurnAdapter(
          reserveTurn: (_) => Future.value('turn-1'),
          executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
          waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
          bootstrapWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async =>
              const WorkflowGitBootstrapResult(integrationBranch: 'dartclaw/integration/test'),
          promoteWorkflowBranch:
              ({
                required runId,
                required projectId,
                required branch,
                required integrationBranch,
                required strategy,
                String? storyId,
              }) async {
                promotedStoryIds.add(storyId);
                return const WorkflowGitPromotionSuccess(commitSha: 'abc123');
              },
        ),
      );

      final queuedTitles = <String>[];
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        final task = await taskService.get(e.taskId);
        if (task == null) return;
        queuedTitles.add(task.title);

        if (task.title.contains('[quick-review]')) {
          final artifactsDir = Directory(p.join(tempDir.path, 'tasks', e.taskId, 'artifacts'))
            ..createSync(recursive: true);
          final output = File(p.join(artifactsDir.path, 'quick-review.md'));
          output.writeAsStringSync('{"pass": true, "findings_count": 0, "findings": [], "summary": "ok"}');
          await taskService.addArtifact(
            id: 'artifact-${e.taskId}',
            taskId: e.taskId,
            name: 'quick-review.md',
            kind: ArtifactKind.document,
            path: output.path,
          );
        } else if (task.title.contains('Implement Stories')) {
          await taskService.updateFields(
            task.id,
            worktreeJson: {
              'path': p.join(tempDir.path, 'worktrees', task.id),
              'branch': 'story-s01',
              'createdAt': DateTime.now().toIso8601String(),
            },
          );
        }
        await completeTask(e.taskId);
      });

      await runtimeExecutor.execute(run, definition, context);
      await sub.cancel();

      expect(queuedTitles.first, contains('Implement Stories'));
      expect(queuedTitles[1], contains('[quick-review]'));
      expect(queuedTitles.where((title) => title.contains('[quick-remediate]')), isEmpty);
      expect(promotedStoryIds, equals(['S01']));
    });

    test('runtime quick review remediation is bounded to a single pass before promotion', () async {
      var promotionCount = 0;
      final definition = WorkflowDefinition(
        name: 'plan-runtime-remediate',
        description: 'Runtime quick remediation bound',
        gitStrategy: const WorkflowGitStrategy(
          bootstrap: true,
          worktree: 'per-map-item',
          quickReview: true,
          promotion: 'merge',
          publish: WorkflowGitPublishStrategy(enabled: false),
        ),
        steps: const [
          WorkflowStep(
            id: 'implement',
            name: 'Implement Stories',
            type: 'coding',
            project: 'my-project',
            prompts: ['Implement {{map.item.id}}'],
            mapOver: 'stories',
            maxParallel: 1,
            contextOutputs: ['story_result'],
          ),
        ],
      );

      final run = WorkflowRun(
        id: 'runtime-remediate-run',
        definitionName: definition.name,
        status: WorkflowRunStatus.running,
        startedAt: DateTime.now(),
        updatedAt: DateTime.now(),
        variablesJson: const {'PROJECT': 'my-project', 'BRANCH': 'main'},
        definitionJson: definition.toJson(),
      );
      await repository.insert(run);

      final context = WorkflowContext(
        data: {
          'stories': [
            {'id': 'S01'},
          ],
        },
        variables: const {'PROJECT': 'my-project', 'BRANCH': 'main'},
      );

      final runtimeExecutor = WorkflowExecutor(
        taskService: taskService,
        eventBus: eventBus,
        kvService: kvService,
        repository: repository,
        gateEvaluator: GateEvaluator(),
        contextExtractor: ContextExtractor(
          taskService: taskService,
          messageService: messageService,
          dataDir: tempDir.path,
        ),
        dataDir: tempDir.path,
        turnAdapter: WorkflowTurnAdapter(
          reserveTurn: (_) => Future.value('turn-1'),
          executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
          waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
          bootstrapWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async =>
              const WorkflowGitBootstrapResult(integrationBranch: 'dartclaw/integration/test'),
          promoteWorkflowBranch:
              ({
                required runId,
                required projectId,
                required branch,
                required integrationBranch,
                required strategy,
                String? storyId,
              }) async {
                promotionCount++;
                return const WorkflowGitPromotionSuccess(commitSha: 'abc123');
              },
        ),
      );

      final queuedTitles = <String>[];
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        final task = await taskService.get(e.taskId);
        if (task == null) return;
        queuedTitles.add(task.title);

        if (task.title.contains('[quick-review]')) {
          final session = await sessionService.createSession(type: SessionType.task);
          await taskService.updateFields(task.id, sessionId: session.id);
          await kvService.set('session_cost:${session.id}', jsonEncode({'total_tokens': 3}));
          final artifactsDir = Directory(p.join(tempDir.path, 'tasks', e.taskId, 'artifacts'))
            ..createSync(recursive: true);
          final output = File(p.join(artifactsDir.path, 'quick-review.md'));
          output.writeAsStringSync(
            '{"pass": false, "findings_count": 2, "findings": [{"severity":"high","title":"x"}], "summary": "needs remediation"}',
          );
          await taskService.addArtifact(
            id: 'artifact-${e.taskId}',
            taskId: e.taskId,
            name: 'quick-review.md',
            kind: ArtifactKind.document,
            path: output.path,
          );
        } else if (task.title.contains('[quick-remediate]')) {
          final session = await sessionService.createSession(type: SessionType.task);
          await taskService.updateFields(task.id, sessionId: session.id);
          await kvService.set('session_cost:${session.id}', jsonEncode({'total_tokens': 4}));
          final artifactsDir = Directory(p.join(tempDir.path, 'tasks', e.taskId, 'artifacts'))
            ..createSync(recursive: true);
          final output = File(p.join(artifactsDir.path, 'quick-remediation.md'));
          output.writeAsStringSync('Runtime remediation result');
          await taskService.addArtifact(
            id: 'artifact-${e.taskId}',
            taskId: e.taskId,
            name: 'quick-remediation.md',
            kind: ArtifactKind.document,
            path: output.path,
          );
        } else if (task.title.contains('Implement Stories')) {
          await taskService.updateFields(
            task.id,
            sessionId: (await sessionService.createSession(type: SessionType.task)).id,
            worktreeJson: {
              'path': p.join(tempDir.path, 'worktrees', task.id),
              'branch': 'story-s01',
              'createdAt': DateTime.now().toIso8601String(),
            },
          );
          final refreshedTask = await taskService.get(task.id);
          await kvService.set('session_cost:${refreshedTask!.sessionId}', jsonEncode({'total_tokens': 10}));
        }
        await completeTask(e.taskId);
      });

      await runtimeExecutor.execute(run, definition, context);
      await sub.cancel();

      expect(queuedTitles.where((title) => title.contains('[quick-remediate]')).length, equals(1));
      expect(promotionCount, equals(1));
      expect(context['implement[0].quick_remediation_passes'], equals(1));
      expect(context['implement[0].story_result'], equals('Runtime remediation result'));
      expect(context['implement[0].tokenCount'], equals(17));
      expect((context['story_result'] as List).first, containsPair('text', 'Runtime remediation result'));
    });

    test('plain-text runtime quick review with no issues is treated as pass', () async {
      var promotionCount = 0;
      final definition = WorkflowDefinition(
        name: 'plan-runtime-review-plain-text-pass',
        description: 'Runtime quick review text fallback',
        gitStrategy: const WorkflowGitStrategy(
          bootstrap: true,
          worktree: 'per-map-item',
          quickReview: true,
          promotion: 'merge',
          publish: WorkflowGitPublishStrategy(enabled: false),
        ),
        steps: const [
          WorkflowStep(
            id: 'implement',
            name: 'Implement Stories',
            type: 'coding',
            project: 'my-project',
            prompts: ['Implement {{map.item.id}}'],
            mapOver: 'stories',
            maxParallel: 1,
            contextOutputs: ['story_result'],
          ),
        ],
      );

      final run = WorkflowRun(
        id: 'runtime-review-text-pass-run',
        definitionName: definition.name,
        status: WorkflowRunStatus.running,
        startedAt: DateTime.now(),
        updatedAt: DateTime.now(),
        variablesJson: const {'PROJECT': 'my-project', 'BRANCH': 'main'},
        definitionJson: definition.toJson(),
      );
      await repository.insert(run);

      final context = WorkflowContext(
        data: {
          'stories': [
            {'id': 'S01'},
          ],
        },
        variables: const {'PROJECT': 'my-project', 'BRANCH': 'main'},
      );

      final runtimeExecutor = WorkflowExecutor(
        taskService: taskService,
        eventBus: eventBus,
        kvService: kvService,
        repository: repository,
        gateEvaluator: GateEvaluator(),
        contextExtractor: ContextExtractor(
          taskService: taskService,
          messageService: messageService,
          dataDir: tempDir.path,
        ),
        messageService: messageService,
        dataDir: tempDir.path,
        turnAdapter: WorkflowTurnAdapter(
          reserveTurn: (_) => Future.value('turn-1'),
          executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
          waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
          bootstrapWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async =>
              const WorkflowGitBootstrapResult(integrationBranch: 'dartclaw/integration/test'),
          promoteWorkflowBranch:
              ({
                required runId,
                required projectId,
                required branch,
                required integrationBranch,
                required strategy,
                String? storyId,
              }) async {
                promotionCount++;
                return const WorkflowGitPromotionSuccess(commitSha: 'abc123');
              },
        ),
      );

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        final task = await taskService.get(e.taskId);
        if (task == null) return;

        final session = await sessionService.createSession(type: SessionType.task);
        await taskService.updateFields(task.id, sessionId: session.id);

        if (task.title.contains('[quick-review]')) {
          await messageService.insertMessage(
            sessionId: session.id,
            role: 'assistant',
            content:
                'Using the quick-review path to inspect the generated note before returning findings.\n'
                '**Findings**\n'
                '- None. The generated note matches the requested two-line shape.',
          );
        } else {
          await taskService.updateFields(
            task.id,
            worktreeJson: {
              'path': p.join(tempDir.path, 'worktrees', task.id),
              'branch': 'story-s01',
              'createdAt': DateTime.now().toIso8601String(),
            },
          );
          await messageService.insertMessage(
            sessionId: session.id,
            role: 'assistant',
            content: _workflowContext({'story_result': 'IMPLEMENTED'}),
          );
        }
        await completeTask(e.taskId);
      });

      await runtimeExecutor.execute(run, definition, context);
      await sub.cancel();

      expect(promotionCount, equals(1));
      final finalRun = await repository.getById(run.id);
      expect(finalRun?.status, WorkflowRunStatus.completed);
    });

    test('plain-text runtime quick review findings trigger remediation', () async {
      var promotionCount = 0;
      final queuedTitles = <String>[];
      final definition = WorkflowDefinition(
        name: 'plan-runtime-review-plain-text-findings',
        description: 'Runtime quick review prose findings fallback',
        gitStrategy: const WorkflowGitStrategy(
          bootstrap: true,
          worktree: 'per-map-item',
          quickReview: true,
          promotion: 'merge',
          publish: WorkflowGitPublishStrategy(enabled: false),
        ),
        steps: const [
          WorkflowStep(
            id: 'implement',
            name: 'Implement Stories',
            type: 'coding',
            project: 'my-project',
            prompts: ['Implement {{map.item.id}}'],
            mapOver: 'stories',
            maxParallel: 1,
            contextOutputs: ['story_result'],
          ),
        ],
      );

      final run = WorkflowRun(
        id: 'runtime-review-text-findings-run',
        definitionName: definition.name,
        status: WorkflowRunStatus.running,
        startedAt: DateTime.now(),
        updatedAt: DateTime.now(),
        variablesJson: const {'PROJECT': 'my-project', 'BRANCH': 'main'},
        definitionJson: definition.toJson(),
      );
      await repository.insert(run);

      final context = WorkflowContext(
        data: {
          'stories': [
            {'id': 'S01'},
          ],
        },
        variables: const {'PROJECT': 'my-project', 'BRANCH': 'main'},
      );

      final runtimeExecutor = WorkflowExecutor(
        taskService: taskService,
        eventBus: eventBus,
        kvService: kvService,
        repository: repository,
        gateEvaluator: GateEvaluator(),
        contextExtractor: ContextExtractor(
          taskService: taskService,
          messageService: messageService,
          dataDir: tempDir.path,
        ),
        messageService: messageService,
        dataDir: tempDir.path,
        turnAdapter: WorkflowTurnAdapter(
          reserveTurn: (_) => Future.value('turn-1'),
          executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
          waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
          bootstrapWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async =>
              const WorkflowGitBootstrapResult(integrationBranch: 'dartclaw/integration/test'),
          promoteWorkflowBranch:
              ({
                required runId,
                required projectId,
                required branch,
                required integrationBranch,
                required strategy,
                String? storyId,
              }) async {
                promotionCount++;
                return const WorkflowGitPromotionSuccess(commitSha: 'abc123');
              },
        ),
      );

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        final task = await taskService.get(e.taskId);
        if (task == null) return;
        queuedTitles.add(task.title);

        final session = await sessionService.createSession(type: SessionType.task);
        await taskService.updateFields(task.id, sessionId: session.id);

        if (task.title.contains('[quick-review]')) {
          await messageService.insertMessage(
            sessionId: session.id,
            role: 'assistant',
            content:
                '**Findings**\n'
                '- `notes/example.md:1` does not satisfy the required output contract.\n'
                '- The generated artifact is missing the expected status details.',
          );
        } else if (task.title.contains('[quick-remediate]')) {
          final artifactsDir = Directory(p.join(tempDir.path, 'tasks', e.taskId, 'artifacts'))
            ..createSync(recursive: true);
          final output = File(p.join(artifactsDir.path, 'quick-remediation.md'));
          output.writeAsStringSync('Remediated implementation result');
          await taskService.addArtifact(
            id: 'artifact-${e.taskId}',
            taskId: e.taskId,
            name: 'quick-remediation.md',
            kind: ArtifactKind.document,
            path: output.path,
          );
        } else {
          await taskService.updateFields(
            task.id,
            worktreeJson: {
              'path': p.join(tempDir.path, 'worktrees', task.id),
              'branch': 'story-s01',
              'createdAt': DateTime.now().toIso8601String(),
            },
          );
          await messageService.insertMessage(
            sessionId: session.id,
            role: 'assistant',
            content: _workflowContext({'story_result': 'INITIAL_IMPLEMENTATION'}),
          );
        }
        await completeTask(e.taskId);
      });

      await runtimeExecutor.execute(run, definition, context);
      await sub.cancel();

      expect(queuedTitles.where((title) => title.contains('[quick-remediate]')).length, equals(1));
      expect(promotionCount, equals(1));
      expect(context['implement[0].quick_remediation_passes'], equals(1));
      expect(context['implement[0].story_result'], equals('Remediated implementation result'));
      final finalRun = await repository.getById(run.id);
      expect(finalRun?.status, WorkflowRunStatus.completed);
    });

    test('unreadable runtime quick review verdict fails closed and preserves spent tokens', () async {
      var promotionCount = 0;
      final iterationEvents = <MapIterationCompletedEvent>[];
      final definition = WorkflowDefinition(
        name: 'plan-runtime-review-invalid',
        description: 'Runtime quick review must fail closed on unreadable verdicts',
        gitStrategy: const WorkflowGitStrategy(
          bootstrap: true,
          worktree: 'per-map-item',
          quickReview: true,
          promotion: 'merge',
          publish: WorkflowGitPublishStrategy(enabled: false),
        ),
        steps: const [
          WorkflowStep(
            id: 'implement',
            name: 'Implement Stories',
            type: 'coding',
            project: 'my-project',
            prompts: ['Implement {{map.item.id}}'],
            mapOver: 'stories',
            maxParallel: 1,
            contextOutputs: ['story_result'],
          ),
        ],
      );

      final run = WorkflowRun(
        id: 'runtime-review-invalid-run',
        definitionName: definition.name,
        status: WorkflowRunStatus.running,
        startedAt: DateTime.now(),
        updatedAt: DateTime.now(),
        variablesJson: const {'PROJECT': 'my-project', 'BRANCH': 'main'},
        definitionJson: definition.toJson(),
      );
      await repository.insert(run);

      final context = WorkflowContext(
        data: {
          'stories': [
            {'id': 'S01'},
          ],
        },
        variables: const {'PROJECT': 'my-project', 'BRANCH': 'main'},
      );

      final runtimeExecutor = WorkflowExecutor(
        taskService: taskService,
        eventBus: eventBus,
        kvService: kvService,
        repository: repository,
        gateEvaluator: GateEvaluator(),
        contextExtractor: ContextExtractor(
          taskService: taskService,
          messageService: messageService,
          dataDir: tempDir.path,
        ),
        dataDir: tempDir.path,
        turnAdapter: WorkflowTurnAdapter(
          reserveTurn: (_) => Future.value('turn-1'),
          executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
          waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
          bootstrapWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async =>
              const WorkflowGitBootstrapResult(integrationBranch: 'dartclaw/integration/test'),
          promoteWorkflowBranch:
              ({
                required runId,
                required projectId,
                required branch,
                required integrationBranch,
                required strategy,
                String? storyId,
              }) async {
                promotionCount++;
                return const WorkflowGitPromotionSuccess(commitSha: 'abc123');
              },
        ),
      );

      final eventSub = eventBus.on<MapIterationCompletedEvent>().listen(iterationEvents.add);
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        final task = await taskService.get(e.taskId);
        if (task == null) return;

        if (task.title.contains('[quick-review]')) {
          final session = await sessionService.createSession(type: SessionType.task);
          await taskService.updateFields(task.id, sessionId: session.id);
          await kvService.set('session_cost:${session.id}', jsonEncode({'total_tokens': 3}));
        } else if (task.title.contains('Implement Stories')) {
          final session = await sessionService.createSession(type: SessionType.task);
          await taskService.updateFields(
            task.id,
            sessionId: session.id,
            worktreeJson: {
              'path': p.join(tempDir.path, 'worktrees', task.id),
              'branch': 'story-s01',
              'createdAt': DateTime.now().toIso8601String(),
            },
          );
          await kvService.set('session_cost:${session.id}', jsonEncode({'total_tokens': 10}));
        }
        await completeTask(e.taskId);
      });

      await runtimeExecutor.execute(run, definition, context);
      await sub.cancel();
      await eventSub.cancel();

      final finalRun = await repository.getById(run.id);
      expect(finalRun?.status, WorkflowRunStatus.paused);
      expect(promotionCount, equals(0));
      expect(context['implement[0].tokenCount'], equals(13));
      expect(iterationEvents, hasLength(1));
      expect(iterationEvents.single.success, isFalse);
      expect(iterationEvents.single.tokenCount, equals(13));
    });

    test('3-item array creates 3 tasks', () async {
      final collection = [
        {'id': 's01', 'name': 'Story 1'},
        {'id': 's02', 'name': 'Story 2'},
        {'id': 's03', 'name': 'Story 3'},
      ];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Map test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['produce'], contextOutputs: ['stories']),
          WorkflowStep(
            id: 'implement',
            name: 'Implement',
            prompts: ['Implement {{map.item}}'],
            mapOver: 'stories',
            maxParallel: 3,
            contextOutputs: ['results'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['stories'] = collection;

      final taskIds = <String>[];
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        taskIds.add(e.taskId);
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context, startFromStepIndex: 1);
      await sub.cancel();

      expect(taskIds.length, equals(3), reason: '3 tasks should be created, one per item');
    });

    test('results collected in index order (not completion order)', () async {
      final collection = ['item0', 'item1', 'item2'];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Map test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['items']),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['Process {{map.item}}'],
            mapOver: 'items',
            maxParallel: 3,
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      // Complete tasks in reverse order (2, 1, 0).
      final taskIds = <String>[];
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        taskIds.add(e.taskId);
      });

      // Run executor in background, manually complete tasks in reverse.
      final executorFuture = executor.execute(run, definition, context, startFromStepIndex: 1);

      // Wait for all 3 tasks to be created.
      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        return taskIds.length < 3;
      });
      await sub.cancel();

      // Complete in reverse order.
      for (final id in taskIds.reversed) {
        await completeTask(id);
        await Future<void>.delayed(Duration.zero);
      }
      await executorFuture;

      // Results should be index-ordered (3 slots, all null from default extraction).
      expect(context['mapped'], isA<List<Object?>>());
      expect((context['mapped'] as List).length, equals(3));
    });

    test('maxParallel: 1 (default) executes sequentially', () async {
      final collection = ['a', 'b', 'c'];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Map test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['items']),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['Process {{map.item}}'],
            mapOver: 'items',
            // maxParallel omitted → defaults to 1 (sequential)
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      var maxConcurrent = 0;
      var concurrent = 0;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        concurrent++;
        if (concurrent > maxConcurrent) maxConcurrent = concurrent;
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
        concurrent--;
      });

      await executor.execute(run, definition, context, startFromStepIndex: 1);
      await sub.cancel();

      expect(maxConcurrent, equals(1), reason: 'maxParallel default is 1 (sequential)');
    });

    test('maxParallel: "unlimited" dispatches all items', () async {
      final collection = ['a', 'b', 'c', 'd', 'e'];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Map test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['items']),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['Process {{map.item}}'],
            mapOver: 'items',
            maxParallel: 'unlimited',
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      final taskIds = <String>[];
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        taskIds.add(e.taskId);
      });

      final executorFuture = executor.execute(run, definition, context, startFromStepIndex: 1);

      // Wait for all tasks to be queued.
      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        return taskIds.length < 5;
      });
      await sub.cancel();

      for (final id in taskIds) {
        await completeTask(id);
        await Future<void>.delayed(Duration.zero);
      }
      await executorFuture;

      expect(taskIds.length, equals(5));
    });

    test('map iterations preserve project binding for coding tasks', () async {
      final collection = ['story-a', 'story-b'];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Project map test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['stories']),
          WorkflowStep(
            id: 'implement',
            name: 'Implement',
            type: 'coding',
            project: 'my-app',
            prompts: ['Implement {{map.item}}'],
            mapOver: 'stories',
            maxParallel: 2,
            contextOutputs: ['results'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['stories'] = collection;

      final projectIds = <String?>[];
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await taskService.get(e.taskId);
        projectIds.add(task?.projectId);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context, startFromStepIndex: 1);
      await sub.cancel();

      expect(projectIds, equals(['my-app', 'my-app']));
    });
  });

  group('error handling', () {
    test('promotion-aware map rejects unknown dependency IDs before dispatch', () async {
      final definition = WorkflowDefinition(
        name: 'promotion-aware-map',
        description: 'Unknown dependency validation',
        gitStrategy: const WorkflowGitStrategy(
          bootstrap: true,
          worktree: 'per-map-item',
          promotion: 'merge',
          publish: WorkflowGitPublishStrategy(enabled: false),
        ),
        steps: const [
          WorkflowStep(
            id: 'implement',
            name: 'Implement',
            type: 'coding',
            project: 'my-project',
            prompts: ['Implement {{map.item.id}}'],
            mapOver: 'stories',
            maxParallel: 2,
            contextOutputs: ['results'],
          ),
        ],
      );

      final run = WorkflowRun(
        id: 'run-unknown-deps',
        definitionName: definition.name,
        status: WorkflowRunStatus.running,
        startedAt: DateTime.now(),
        updatedAt: DateTime.now(),
        variablesJson: const {'PROJECT': 'my-project', 'BRANCH': 'main'},
        definitionJson: definition.toJson(),
      );
      await repository.insert(run);

      final context = WorkflowContext(
        data: {
          'stories': [
            {
              'id': 'S01',
              'dependencies': ['S99'],
            },
          ],
        },
        variables: const {'PROJECT': 'my-project', 'BRANCH': 'main'},
      );

      final promotionAwareExecutor = WorkflowExecutor(
        taskService: taskService,
        eventBus: eventBus,
        kvService: kvService,
        repository: repository,
        gateEvaluator: GateEvaluator(),
        contextExtractor: ContextExtractor(
          taskService: taskService,
          messageService: messageService,
          dataDir: tempDir.path,
        ),
        dataDir: tempDir.path,
        turnAdapter: WorkflowTurnAdapter(
          reserveTurn: (_) => Future.value('turn-1'),
          executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
          waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
          bootstrapWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async =>
              const WorkflowGitBootstrapResult(integrationBranch: 'dartclaw/integration/test'),
        ),
      );

      await promotionAwareExecutor.execute(run, definition, context);

      final finalRun = await repository.getById(run.id);
      expect(finalRun?.status, WorkflowRunStatus.paused);
      expect(finalRun?.errorMessage, contains('unknown dependency IDs'));
      final tasks = await taskService.list();
      expect(tasks.where((t) => t.workflowRunId == run.id), isEmpty, reason: 'Validation should fail before dispatch');
    });

    test('empty collection succeeds with empty result array', () async {
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Map test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['items']),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['Process {{map.item}}'],
            mapOver: 'items',
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = <Object?>[];

      await executor.execute(run, definition, context, startFromStepIndex: 1);

      final updatedRun = await repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.completed));
      expect(context['mapped'], isA<List<Object?>>());
      expect((context['mapped'] as List).length, equals(0));
    });

    test('mapOver references null key → step fails', () async {
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Map test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['items']),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['Process {{map.item}}'],
            mapOver: 'items',
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      // 'items' not set in context — should be null.
      final context = WorkflowContext();

      await executor.execute(run, definition, context, startFromStepIndex: 1);

      final updatedRun = await repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.paused));
      expect(updatedRun?.errorMessage, contains('null or missing'));
    });

    test('mapOver references non-List → step fails', () async {
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Map test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['items']),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['Process {{map.item}}'],
            mapOver: 'items',
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = 'not a list';

      await executor.execute(run, definition, context, startFromStepIndex: 1);

      final updatedRun = await repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.paused));
      expect(updatedRun?.errorMessage, contains('not a List'));
    });

    test('collection exceeding maxItems → step fails with decomposition hint', () async {
      final collection = List.generate(5, (i) => 'item$i');
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Map test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['items']),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['Process {{map.item}}'],
            mapOver: 'items',
            maxItems: 3,
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      await executor.execute(run, definition, context, startFromStepIndex: 1);

      final updatedRun = await repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.paused));
      expect(updatedRun?.errorMessage, contains('maxItems'));
      expect(updatedRun?.errorMessage, contains('decompos'));
    });

    test('single iteration failure — others continue, result array has error object', () async {
      final collection = ['a', 'b', 'c'];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Map test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['items']),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['Process {{map.item}}'],
            mapOver: 'items',
            maxParallel: 3,
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      // Fail the second task (index 1), succeed the others.
      final taskIds = <String>[];
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        taskIds.add(e.taskId);
      });

      final executorFuture = executor.execute(run, definition, context, startFromStepIndex: 1);

      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        return taskIds.length < 3;
      });
      await sub.cancel();

      // Complete tasks: fail index 1, succeed others.
      for (var i = 0; i < taskIds.length; i++) {
        await completeTask(taskIds[i], status: i == 1 ? TaskStatus.failed : TaskStatus.accepted);
        await Future<void>.delayed(Duration.zero);
      }
      await executorFuture;

      // Step should be paused (has failures).
      final updatedRun = await repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.paused));

      // Results array is still stored in context before pausing.
      expect(context['mapped'], isA<List<Object?>>());
      final mapped = context['mapped'] as List;
      expect(mapped.length, equals(3));

      // Index 1 should be an error object.
      final errorResult = mapped[1] as Map;
      expect(errorResult['error'], isTrue);
      expect(errorResult, contains('message'));
    });

    test('circular dependency detected at step start → step fails', () async {
      final collection = [
        {
          'id': 's01',
          'name': 'S1',
          'dependencies': ['s02'],
        },
        {
          'id': 's02',
          'name': 'S2',
          'dependencies': ['s01'],
        },
      ];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Dep test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['stories']),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['Implement {{map.item}}'],
            mapOver: 'stories',
            contextOutputs: ['results'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['stories'] = collection;

      await executor.execute(run, definition, context, startFromStepIndex: 1);

      final updatedRun = await repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.paused));
      expect(updatedRun?.errorMessage, contains('Circular dependency'));
    });
  });

  group('dependency ordering', () {
    test('item with dependency not dispatched until dep completes', () async {
      final collection = [
        {'id': 's01', 'name': 'S1'},
        {
          'id': 's02',
          'name': 'S2',
          'dependencies': ['s01'],
        },
      ];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Dep test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['stories']),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['Implement {{map.item}}'],
            mapOver: 'stories',
            maxParallel: 3,
            contextOutputs: ['results'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['stories'] = collection;

      // Track order of task creation.
      final taskIds = <String>[];
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        taskIds.add(e.taskId);
      });

      final executorFuture = executor.execute(run, definition, context, startFromStepIndex: 1);

      // Wait for first task to be queued.
      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        return taskIds.isEmpty;
      });

      // At this point only s01 (index 0) should be dispatched.
      expect(taskIds.length, equals(1), reason: 's02 blocked by s01 dependency');

      // Complete s01.
      await completeTask(taskIds[0]);
      await Future<void>.delayed(Duration.zero);

      // Wait for s02 to be dispatched.
      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        return taskIds.length < 2;
      });
      await sub.cancel();

      // Complete s02.
      await completeTask(taskIds[1]);
      await executorFuture;

      expect(taskIds.length, equals(2));
      final updatedRun = await repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('items without id field are all independent (dispatched immediately)', () async {
      final collection = ['plain-a', 'plain-b', 'plain-c'];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'No dep test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['items']),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['{{map.item}}'],
            mapOver: 'items',
            maxParallel: 3,
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      final taskIds = <String>[];
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        taskIds.add(e.taskId);
      });

      final executorFuture = executor.execute(run, definition, context, startFromStepIndex: 1);

      // All 3 should be dispatched immediately.
      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        return taskIds.length < 3;
      });
      await sub.cancel();

      expect(taskIds.length, equals(3), reason: 'no deps means all dispatched at once');

      for (final id in taskIds) {
        await completeTask(id);
        await Future<void>.delayed(Duration.zero);
      }
      await executorFuture;
    });
  });

  group('events', () {
    test('MapIterationCompletedEvent fired per iteration with correct fields', () async {
      final collection = ['x', 'y'];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Event test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['items']),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['{{map.item}}'],
            mapOver: 'items',
            maxParallel: 2,
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      final iterEvents = <MapIterationCompletedEvent>[];
      final iterSub = eventBus.on<MapIterationCompletedEvent>().listen(iterEvents.add);

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context, startFromStepIndex: 1);
      await sub.cancel();
      await iterSub.cancel();

      expect(iterEvents.length, equals(2));
      expect(iterEvents.map((e) => e.iterationIndex).toSet(), equals({0, 1}));
      for (final e in iterEvents) {
        expect(e.runId, equals('run-1'));
        expect(e.stepId, equals('map'));
        expect(e.totalIterations, equals(2));
        expect(e.success, isTrue);
      }
    });

    test('MapStepCompletedEvent fired with aggregate stats', () async {
      final collection = ['x', 'y', 'z'];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Event test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['items']),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['{{map.item}}'],
            mapOver: 'items',
            maxParallel: 3,
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      MapStepCompletedEvent? completedEvent;
      final completeSub = eventBus.on<MapStepCompletedEvent>().listen((e) => completedEvent = e);

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context, startFromStepIndex: 1);
      await sub.cancel();
      await completeSub.cancel();

      expect(completedEvent, isNotNull);
      expect(completedEvent!.runId, equals('run-1'));
      expect(completedEvent!.stepId, equals('map'));
      expect(completedEvent!.stepName, equals('Map'));
      expect(completedEvent!.totalIterations, equals(3));
      expect(completedEvent!.successCount, equals(3));
      expect(completedEvent!.failureCount, equals(0));
      expect(completedEvent!.cancelledCount, equals(0));
    });

    test('persists map progress checkpoints between sequential map iterations', () async {
      final collection = ['a', 'b', 'c'];
      final definition = WorkflowDefinition(
        name: 'map-recovery',
        description: 'Map recovery',
        steps: const [
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['Process {{map.item}}'],
            mapOver: 'items',
            maxParallel: 1,
            contextOutputs: ['mapped'],
          ),
        ],
      );

      var run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      final queuedTitles = <String>[];
      final checkpointReady = Completer<void>();
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await taskService.get(e.taskId);
        if (task == null) return;
        queuedTitles.add(task.title);
        if (queuedTitles.length == 2 && !checkpointReady.isCompleted) {
          checkpointReady.complete();
        }
        await completeTask(e.taskId);
      });

      final executeFuture = executor.execute(run, definition, context);
      await checkpointReady.future;

      final checkpointed = await repository.getById('run-1');
      expect(checkpointed?.executionCursor?.nodeId, 'map');
      expect(checkpointed?.executionCursor?.completedIndices, [0]);

      await executeFuture;
      await sub.cancel();

      expect(queuedTitles, ['map-recovery — Map (1/3)', 'map-recovery — Map (2/3)', 'map-recovery — Map (3/3)']);
      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });
  });

  group('maxParallel resolution', () {
    test('maxParallel as int is used directly', () async {
      final collection = List.generate(4, (i) => 'item$i');
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'maxParallel test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['items']),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['{{map.item}}'],
            mapOver: 'items',
            maxParallel: 2,
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      var maxConcurrent = 0;
      var concurrent = 0;
      final taskIds = <String>[];

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        concurrent++;
        taskIds.add(e.taskId);
        if (concurrent > maxConcurrent) maxConcurrent = concurrent;
      });

      final executorFuture = executor.execute(run, definition, context, startFromStepIndex: 1);

      // Manually complete tasks to control concurrency observation.
      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        if (taskIds.isNotEmpty) {
          final id = taskIds.removeAt(0);
          await completeTask(id);
          concurrent--;
        }
        final updatedRun = await repository.getById('run-1');
        return updatedRun?.status == WorkflowRunStatus.running;
      });
      await sub.cancel();
      await executorFuture;

      expect(maxConcurrent, lessThanOrEqualTo(2));
    });

    test('invalid maxParallel string → step fails', () async {
      final collection = ['a', 'b'];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'maxParallel test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['items']),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['{{map.item}}'],
            mapOver: 'items',
            maxParallel: 'not-a-number',
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      await executor.execute(run, definition, context, startFromStepIndex: 1);

      final updatedRun = await repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.paused));
      expect(updatedRun?.errorMessage, contains('maxParallel'));
    });
  });
}
