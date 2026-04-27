// WorkflowExecutor session continuity: multi-prompt execution, continueSession
// runtime (session inheritance, delta accounting), and worktree context bridge
// (branch/worktree_path exposure for coding steps).
@Tags(['component'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        OutputConfig,
        OutputFormat,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowRunStatus,
        WorkflowStep;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart';

void main() {
  final h = WorkflowExecutorHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  group('multi-prompt execution', () {
    StreamSubscription<TaskStatusChangedEvent> autoAcceptQueuedTask() {
      return h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
        await Future<void>.delayed(Duration.zero);
        await h.completeTask(e.taskId);
      });
    }

    test('queues follow-up prompts in task config for one-shot execution', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['First prompt', 'Second prompt', 'Third prompt']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final sub = autoAcceptQueuedTask();

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      final createdTask = (await h.taskService.list()).single;
      expect(createdTask.description, equals('First prompt'));
      final followUps = (await h.workflowStepExecutionRepository.getByTaskId(createdTask.id))?.followUpPrompts;
      expect(followUps, isNotNull);
      expect(followUps, hasLength(2));
      expect(followUps![0], equals('Second prompt'));
      expect(followUps[1], startsWith('Third prompt'));
      expect(followUps[1], contains('## Step Outcome Protocol'));

      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('single-prompt step creates no follow-up turns', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Just one']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final sub = autoAcceptQueuedTask();

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      final createdTask = (await h.taskService.list()).single;
      expect(
        (await h.workflowStepExecutionRepository.getByTaskId(createdTask.id))?.followUpPrompts,
        isEmpty,
      );

      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('workflow-spawned agent execution stays unstarted while the task is queued', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Just one']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      late final StreamSubscription<TaskStatusChangedEvent> sub;
      sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
        await Future<void>.delayed(Duration.zero);
        final task = await h.taskService.get(e.taskId);
        expect(task?.agentExecution?.startedAt, isNull);
        await h.completeTask(e.taskId);
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();
    });

    test('workflow-spawned task leaves provider unset when no override is requested', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Just one']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      late final StreamSubscription<TaskStatusChangedEvent> sub;
      sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
        await Future<void>.delayed(Duration.zero);
        final task = await h.taskService.get(e.taskId);
        expect(task?.provider, isNull);
        await h.completeTask(e.taskId);
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();
    });

    test('completed workflow run preserves AE/WSE row-count invariants', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Just one']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final sub = autoAcceptQueuedTask();

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      final taskCount = (h.db.select('SELECT COUNT(*) AS c FROM tasks').first['c'] as int?) ?? 0;
      final tasksWithoutAe =
          (h.db.select('SELECT COUNT(*) AS c FROM tasks WHERE agent_execution_id IS NULL').first['c'] as int?) ?? 0;
      final workflowStepCount =
          (h.db.select('SELECT COUNT(*) AS c FROM workflow_step_executions').first['c'] as int?) ?? 0;
      final joinedWorkflowStepCount =
          (h.db
                  .select(
                    'SELECT COUNT(*) AS c FROM tasks t '
                    'JOIN workflow_step_executions wse ON wse.task_id = t.id',
                  )
                  .first['c']
              as int?) ??
          0;
      final agentExecutionCount = (h.db.select('SELECT COUNT(*) AS c FROM agent_executions').first['c'] as int?) ?? 0;

      expect(taskCount, 1);
      expect(tasksWithoutAe, 0);
      expect(workflowStepCount, taskCount);
      expect(joinedWorkflowStepCount, taskCount);
      expect(agentExecutionCount, greaterThanOrEqualTo(taskCount));
    });

    test('mixed-output steps without narrative outputs skip structured extraction schema', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'step1',
            name: 'Step 1',
            prompts: ['Plan this'],
            outputs: {
              'prd': OutputConfig(format: OutputFormat.text),
              'stories': OutputConfig(format: OutputFormat.json, schema: 'story-plan'),
            },
          ),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final sub = autoAcceptQueuedTask();

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      final createdTask = (await h.taskService.list()).single;
      expect(
        (await h.workflowStepExecutionRepository.getByTaskId(createdTask.id))!.structuredSchema,
        isNull,
      );
    });

    test('without turn infrastructure, multi-prompt step still completes (graceful degradation)', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['First', 'Second']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await h.completeTask(e.taskId);
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });
  });

  group('continueSession runtime', () {
    const sessionStep1 = '550e8400-e29b-41d4-a716-446655440101';

    void createSessionDir(String sessionId) {
      Directory(p.join(h.sessionsDir, sessionId)).createSync(recursive: true);
    }

    Future<void> seedSessionCost(String sessionId, int totalTokens) async {
      await h.kvService.set('session_cost:$sessionId', jsonEncode({'total_tokens': totalTokens}));
    }

    test('continued step receives _continueSessionId from preceding step', () async {
      createSessionDir(sessionStep1);

      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Investigate', prompts: ['Investigate the bug']),
          const WorkflowStep(id: 'step2', name: 'Fix', prompts: ['Fix the bug'], continueSession: 'step1'),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      var step1TaskId = '';
      var step2TaskId = '';

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        if (step1TaskId.isEmpty) {
          step1TaskId = e.taskId;
          await h.taskService.updateFields(e.taskId, sessionId: sessionStep1);
          await seedSessionCost(sessionStep1, 100);
        } else {
          step2TaskId = e.taskId;
        }
        await h.completeTask(e.taskId);
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      expect(step2TaskId, isNotEmpty);
      final step2Task = await h.taskService.get(step2TaskId);
      expect(step2Task?.configJson['_continueSessionId'], equals(sessionStep1));
    });

    test('continued step resolves root session from an explicit earlier step reference', () async {
      createSessionDir(sessionStep1);

      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Investigate', prompts: ['Investigate the bug']),
          const WorkflowStep(id: 'step2', name: 'Summarize', prompts: ['Summarize findings'], continueSession: 'step1'),
          const WorkflowStep(id: 'step3', name: 'Fix', prompts: ['Fix the bug'], continueSession: 'step1'),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      var createdCount = 0;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        createdCount++;
        if (createdCount == 1) {
          await h.taskService.updateFields(e.taskId, sessionId: sessionStep1);
          await seedSessionCost(sessionStep1, 100);
        }
        await h.completeTask(e.taskId);
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      final allTasks = await h.taskService.list();
      final step3Task = allTasks.firstWhere((t) => t.stepIndex == 2);
      expect(step3Task.configJson['_continueSessionId'], equals(sessionStep1));
    });

    test('continued step stores baseline tokens in _sessionBaselineTokens', () async {
      createSessionDir(sessionStep1);
      await seedSessionCost(sessionStep1, 250);

      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Research', prompts: ['Research the problem']),
          const WorkflowStep(id: 'step2', name: 'Implement', prompts: ['Implement fix'], continueSession: 'step1'),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      var step1Done = false;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        if (!step1Done) {
          step1Done = true;
          await h.taskService.updateFields(e.taskId, sessionId: sessionStep1);
        }
        await h.completeTask(e.taskId);
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      final allTasks = await h.taskService.list();
      final step2Task = allTasks.firstWhere(
        (t) => t.workflowRunId == 'run-1' && t.configJson['_continueSessionId'] != null,
      );
      expect(step2Task.configJson['_sessionBaselineTokens'], equals(250));
    });

    test('workflow totals reflect delta not cumulative shared-session tokens', () async {
      createSessionDir(sessionStep1);

      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['First']),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Second'], continueSession: 'step1'),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      var step1Done = false;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        if (!step1Done) {
          step1Done = true;
          await h.taskService.updateFields(e.taskId, sessionId: sessionStep1);
          await seedSessionCost(sessionStep1, 150);
        } else {
          await h.taskService.updateFields(e.taskId, sessionId: sessionStep1);
          await seedSessionCost(sessionStep1, 300);
        }
        await h.completeTask(e.taskId);
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.totalTokens, equals(300));
    });

    test('continueSession step pauses when previous step has no session ID', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['First']),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Second'], continueSession: 'step1'),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await h.completeTask(e.taskId);
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
      expect(finalRun?.errorMessage, contains('continueSession'));
    });

    test('fresh-session step after continueSession step is unaffected', () async {
      createSessionDir(sessionStep1);

      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['First']),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Second'], continueSession: 'step1'),
          const WorkflowStep(id: 'step3', name: 'Step 3', prompts: ['Third']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      var stepCount = 0;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        stepCount++;
        if (stepCount == 1) {
          await h.taskService.updateFields(e.taskId, sessionId: sessionStep1);
          await seedSessionCost(sessionStep1, 100);
        }
        await h.completeTask(e.taskId);
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
      final allTasks = await h.taskService.list();
      final step3Task = allTasks.where((t) => t.workflowRunId == 'run-1' && t.stepIndex == 2).firstOrNull;
      expect(step3Task?.configJson['_continueSessionId'], isNull);
    });
  });

  group('worktree context bridge', () {
    test('coding step with worktreeJson exposes branch and worktree_path to context', () async {
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'fix', name: 'Fix Bug', type: 'coding', prompts: ['Fix the bug']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await h.taskService.updateFields(
          e.taskId,
          worktreeJson: {
            'branch': 'feat/fix-issue-42',
            'path': '/worktrees/fix-issue-42',
            'createdAt': '2026-01-01T00:00:00.000Z',
          },
        );
        await h.completeTask(e.taskId);
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
      final contextData = finalRun?.contextJson['data'] as Map?;
      expect(contextData?['fix.branch'], equals('feat/fix-issue-42'));
      expect(contextData?['fix.worktree_path'], equals('/worktrees/fix-issue-42'));
    });

    test('coding step without worktreeJson exposes empty values and does not fail workflow', () async {
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'fix', name: 'Fix Bug', type: 'coding', prompts: ['Fix the bug']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await h.completeTask(e.taskId);
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
      final contextData = finalRun?.contextJson['data'] as Map?;
      expect(contextData?['fix.branch'], equals(''));
      expect(contextData?['fix.worktree_path'], equals(''));
    });

    test('workflow research step injects branch/worktree_path keys through the coding task path', () async {
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'research', name: 'Research', prompts: ['Research the issue']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await h.completeTask(e.taskId);
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      final finalRun = await h.repository.getById('run-1');
      final contextData = finalRun?.contextJson['data'] as Map?;
      expect(contextData?['research.branch'], equals(''));
      expect(contextData?['research.worktree_path'], equals(''));
    });
  });
}
