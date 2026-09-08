import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show SqliteWorkflowRunRepository, WorkflowExecutionCursor, WorkflowRun, WorkflowWorktreeBinding;
import 'package:test/test.dart';

import 'database_backend_contract.dart';

final _instant = DateTime.parse('2026-09-09T10:11:12.000Z');

void repositoryContractGroups(ContractBackend Function() current) {
  group('[contract:repository.task] production repository', () {
    test('round-trips a task and artifact', () async {
      final repository = SqliteTaskRepository(current().backend);
      final task = _task();
      await repository.insert(task);
      expect((await repository.getById(task.id))?.toJson(), task.toJson());
      final artifact = TaskArtifact(
        id: 'artifact-1',
        taskId: task.id,
        name: 'report',
        kind: ArtifactKind.document,
        path: 'reports/result.txt',
        createdAt: _instant,
      );
      await repository.insertArtifact(artifact);
      expect((await repository.getArtifactById(artifact.id))?.toJson(), artifact.toJson());
      await repository.dispose();
    });
  });

  group('[contract:repository.goal] production repository', () {
    test('round-trips the complete goal value', () async {
      final repository = SqliteGoalRepository(current().backend);
      final goal = Goal(
        id: 'goal-1',
        title: 'Portable goal',
        parentGoalId: 'root',
        mission: 'Prove backend parity',
        createdAt: _instant,
        maxTokens: 4096,
      );
      await repository.insert(goal);
      expect((await repository.getById(goal.id))?.toJson(), goal.toJson());
      await repository.dispose();
    });
  });

  group('[contract:repository.agent_execution] production repository', () {
    test('round-trips scalar and timestamp fields', () async {
      final repository = SqliteAgentExecutionRepository(current().backend);
      const id = 'execution-1';
      final execution = AgentExecution(
        id: id,
        sessionId: 'session-1',
        provider: 'codex',
        model: 'contract-model',
        budgetTokens: 1234,
        startedAt: _instant,
      );
      await repository.create(execution);
      expect(await repository.get(id), execution);
      final row = (await current().backend.query(
        'SELECT started_at, budget_tokens FROM agent_executions WHERE id = ?',
        [id],
      )).single;
      expect(row['started_at'], _instant.toIso8601String());
      expect(row['budget_tokens'], 1234);
    });
  });

  group('[contract:repository.workflow_step_execution] production repository', () {
    test('round-trips the workflow link', () async {
      final backend = current().backend;
      final agentRepository = SqliteAgentExecutionRepository(backend);
      await agentRepository.create(AgentExecution(id: 'step-agent', startedAt: _instant));
      final taskRepository = SqliteTaskRepository(backend);
      await taskRepository.insert(_task(id: 'step-task', agentExecutionId: 'step-agent'));
      final repository = SqliteWorkflowStepExecutionRepository(backend);
      const execution = WorkflowStepExecution(
        taskId: 'step-task',
        agentExecutionId: 'step-agent',
        workflowRunId: 'run-1',
        stepIndex: 2,
        stepId: 'verify',
        stepType: 'command',
        structuredOutputJson: '{"ok":true}',
      );
      await repository.create(execution);
      expect((await repository.getByTaskId(execution.taskId))?.toJson(), execution.toJson());
      await taskRepository.dispose();
    });
  });

  group('[contract:repository.workflow_run] production repository', () {
    test('round-trips workflow state from the workflow package', () async {
      final repository = SqliteWorkflowRunRepository(current().backend);
      final run = WorkflowRun(
        id: 'run-1',
        definitionName: 'contract',
        status: WorkflowRunStatus.failed,
        contextJson: const {
          'subject': 'storage',
          'attempt': 2,
          'flags': ['portable'],
        },
        variablesJson: const {'ENGINE': 'portable', 'REGION': 'local'},
        startedAt: _instant,
        updatedAt: _instant.add(const Duration(minutes: 1)),
        completedAt: _instant.add(const Duration(minutes: 2)),
        errorMessage: 'contract failure',
        totalTokens: 321,
        currentStepIndex: 4,
        definitionJson: const {
          'name': 'contract',
          'steps': [
            {'id': 'search', 'type': 'agent'},
          ],
        },
        executionCursor: WorkflowExecutionCursor.foreach(
          stepId: 'search',
          stepIndex: 4,
          totalItems: 3,
          completedIndices: const [0],
          failedIndices: const [1],
          cancelledIndices: const [2],
          resultSlots: const [
            {'ok': true},
            null,
            null,
          ],
          completedSubStepIdsByIndex: const {
            0: ['collect'],
          },
        ),
        workflowWorktrees: const [
          WorkflowWorktreeBinding(
            key: 'primary',
            path: '/contract/worktree',
            branch: 'contract/run-1',
            workflowRunId: 'run-1',
          ),
        ],
      );
      await repository.insert(run);
      expect((await repository.getById(run.id))?.toJson(), run.toJson());
    });
  });

  group('[contract:repository.task_event] production service', () {
    test('round-trips event details', () async {
      final service = TaskEventService(current().backend);
      final event = TaskEvent(
        id: 'event-1',
        taskId: 'task-1',
        timestamp: _instant,
        kind: TaskEventKind.statusChanged,
        details: const {'from': 'draft', 'to': 'queued'},
      );
      await service.insert(event);
      expect((await service.listForTask(event.taskId)).single.toJson(), event.toJson());
    });
  });

  group('[contract:repository.turn_trace] production service', () {
    test('round-trips booleans as integers and timestamps as text', () async {
      final service = TurnTraceService(current().backend);
      final trace = TurnTrace(
        id: 'trace-1',
        sessionId: 'session-1',
        taskId: 'task-1',
        provider: 'codex',
        startedAt: _instant,
        endedAt: _instant.add(const Duration(seconds: 1)),
        inputTokens: 10,
        outputTokens: 5,
        isError: true,
        errorType: 'contract',
      );
      await service.insert(trace);
      expect(await service.getById(trace.id), trace);
      final row = (await current().backend.query('SELECT is_error, started_at FROM turns WHERE id = ?', [
        trace.id,
      ])).single;
      expect(row['is_error'], 1);
      expect(row['started_at'], _instant.toIso8601String());
      await service.dispose();
    });
  });

  group('[contract:repository.kg_fact] production service', () {
    test('round-trips the engine-assigned fact id', () async {
      final service = TemporalKnowledgeGraphService(current().backend);
      final id = await service.addFact(
        entity: 'DartClaw',
        predicate: 'supports',
        value: 'portable storage',
        validFrom: _instant.toIso8601String(),
        source: 'contract',
        owner: 'u-alpha',
      );
      final fact = await service.factById(id);
      expect(fact?.id, id);
      expect(fact?.entity, 'dartclaw');
      expect(fact?.predicate, 'supports');
      expect(fact?.value, 'portable storage');
      expect(fact?.owner, 'u-alpha');
    });
  });
}

Task _task({String id = 'task-1', String? agentExecutionId}) => Task(
  id: id,
  title: 'Portable task',
  description: 'Round-trip through the selected backend',
  status: TaskStatus.queued,
  acceptanceCriteria: 'Stored and loaded',
  configJson: const {'tokens': 100},
  createdAt: _instant,
  createdBy: 'contract',
  agentExecutionId: agentExecutionId,
  projectId: 'project-1',
);
