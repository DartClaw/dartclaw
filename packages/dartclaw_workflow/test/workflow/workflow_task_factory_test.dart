import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show WorkflowStepExecution, WorkflowStepExecutionRepository;
import 'package:dartclaw_server/dartclaw_server.dart' show TaskService;
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        BashStepPolicy,
        ContextExtractor,
        EventBus,
        GateEvaluator,
        KvService,
        MessageService,
        OutputConfig,
        OutputFormat,
        StepExecutionContext,
        StepPromptConfiguration,
        TaskStatusChangedEvent,
        TaskType,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowRoleDefaults,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowStep;
import 'package:dartclaw_workflow/src/workflow/step_config_resolver.dart';
import 'package:dartclaw_workflow/src/workflow/workflow_task_factory.dart';
import 'package:dartclaw_workflow/src/workflow/workflow_template_engine.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

void main() {
  group('workflow_task_factory', () {
    late Directory tempDir;
    late Database db;
    late EventBus eventBus;
    late SqliteTaskRepository taskRepository;
    late SqliteAgentExecutionRepository agentExecutionRepository;
    late SqliteWorkflowStepExecutionRepository workflowStepExecutionRepository;
    late SqliteExecutionRepositoryTransactor executionTransactor;
    late TaskService taskService;
    late StepExecutionContext executionContext;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('workflow_task_factory_test_');
      db = sqlite3.openInMemory();
      eventBus = EventBus();
      taskRepository = SqliteTaskRepository(db);
      agentExecutionRepository = SqliteAgentExecutionRepository(db, eventBus: eventBus);
      workflowStepExecutionRepository = SqliteWorkflowStepExecutionRepository(db);
      executionTransactor = SqliteExecutionRepositoryTransactor(db);
      taskService = TaskService(
        taskRepository,
        agentExecutionRepository: agentExecutionRepository,
        executionTransactor: executionTransactor,
        eventBus: eventBus,
      );
      final messageService = MessageService(baseDir: p.join(tempDir.path, 'sessions'));
      executionContext = StepExecutionContext(
        taskService: taskService,
        eventBus: eventBus,
        kvService: KvService(filePath: p.join(tempDir.path, 'kv.json')),
        repository: SqliteWorkflowRunRepository(db),
        gateEvaluator: GateEvaluator(),
        contextExtractor: ContextExtractor(
          taskService: taskService,
          messageService: messageService,
          dataDir: tempDir.path,
          workflowStepExecutionRepository: workflowStepExecutionRepository,
        ),
        taskRepository: taskRepository,
        agentExecutionRepository: agentExecutionRepository,
        workflowStepExecutionRepository: workflowStepExecutionRepository,
        executionTransactor: executionTransactor,
      );
    });

    tearDown(() async {
      db.close();
      await tempDir.delete(recursive: true);
    });

    test('preserves default workspace root through configured and scoped contexts', () {
      final context = StepExecutionContext(
        taskService: taskService,
        eventBus: eventBus,
        kvService: KvService(filePath: p.join(tempDir.path, 'kv-copy.json')),
        repository: SqliteWorkflowRunRepository(db),
        gateEvaluator: GateEvaluator(),
        contextExtractor: executionContext.contextExtractor,
        defaultWorkspaceRoot: '/repo',
      );
      const definition = WorkflowDefinition(name: 'copy-context', description: 'copy context', steps: []);
      final run = WorkflowRun(
        id: 'run-copy-context',
        definitionName: definition.name,
        status: WorkflowRunStatus.running,
        startedAt: DateTime.parse('2026-03-24T10:00:00Z'),
        updatedAt: DateTime.parse('2026-03-24T10:00:00Z'),
        definitionJson: definition.toJson(),
      );

      final configured = context.configured(
        dataDir: tempDir.path,
        promptConfiguration: StepPromptConfiguration(),
        roleDefaults: const WorkflowRoleDefaults(),
        bashStepPolicy: const BashStepPolicy(),
        uuid: const Uuid(),
      );
      final scoped = configured.scoped(run: run, definition: definition, workflowContext: WorkflowContext());

      expect(configured.defaultWorkspaceRoot, '/repo');
      expect(scoped.defaultWorkspaceRoot, '/repo');
    });

    test('creates task triple atomically and fires queued event', () async {
      final events = <TaskStatusChangedEvent>[];
      final sub = eventBus.on<TaskStatusChangedEvent>().listen(events.add);
      addTearDown(sub.cancel);

      await createWorkflowTaskTriple(
        ctx: executionContext,
        workflowWorkspaceDir: p.join(tempDir.path, 'workflow-workspace'),
        taskId: 'task-1',
        run: _run(),
        step: const WorkflowStep(id: 'step-1', name: 'Step 1'),
        stepIndex: 0,
        title: 'Title',
        description: 'Prompt',
        type: TaskType.coding,
        provider: 'codex',
        projectId: 'proj',
        maxTokens: 100,
        taskConfig: {'model': 'gpt-test'},
      );

      final task = await taskRepository.getById('task-1');
      expect(task, isNotNull);
      expect(task!.agentExecution, isNotNull);
      expect(task.maxRetries, equals(0));
      expect(task.configJson.containsKey('model'), isFalse);
      expect((await agentExecutionRepository.list()).single.model, equals('gpt-test'));
      final stepExecution = await workflowStepExecutionRepository.getByTaskId('task-1');
      expect(stepExecution?.stepId, equals('step-1'));
      expect(stepExecution?.stepType, equals('agent'));
      expect(events.single.newStatus.name, equals('queued'));
    });

    test('workflow task always persists maxRetries == 0 — workflow engine owns retry authority', () async {
      // Supplying a positive maxTokens and a step with retry config should not
      // result in task-runtime retries; the workflow engine owns that authority.
      await createWorkflowTaskTriple(
        ctx: executionContext,
        workflowWorkspaceDir: p.join(tempDir.path, 'workflow-workspace'),
        taskId: 'task-retry-contract',
        run: _run(),
        step: const WorkflowStep(id: 'step-retry', name: 'Retry Step'),
        stepIndex: 0,
        title: 'Retry title',
        description: 'Prompt',
        type: TaskType.coding,
        provider: 'codex',
        projectId: 'proj',
        maxTokens: 1000,
        taskConfig: const {},
      );

      final task = await taskRepository.getById('task-retry-contract');
      expect(task, isNotNull);
      expect(
        task!.maxRetries,
        equals(0),
        reason: 'Workflow-spawned tasks must opt out of task-runtime retry; workflow engine owns retry authority',
      );
    });

    test('non-workflow task creation preserves configured maxRetries', () async {
      final task = await taskService.create(
        id: 'ordinary-task',
        title: 'Ordinary retry task',
        description: 'Created outside workflow dispatch.',
        type: TaskType.automation,
        maxRetries: 2,
      );

      expect(task.workflowRunId, isNull);
      expect(task.maxRetries, equals(2));
      expect((await taskRepository.getById('ordinary-task'))?.maxRetries, equals(2));
    });

    test('rolls back task and agent execution when step execution insert fails', () async {
      final failingContext = StepExecutionContext(
        taskService: taskService,
        eventBus: eventBus,
        kvService: KvService(filePath: p.join(tempDir.path, 'kv-fail.json')),
        repository: SqliteWorkflowRunRepository(db),
        gateEvaluator: GateEvaluator(),
        contextExtractor: executionContext.contextExtractor,
        taskRepository: taskRepository,
        agentExecutionRepository: agentExecutionRepository,
        workflowStepExecutionRepository: _ThrowingWorkflowStepExecutionRepository(),
        executionTransactor: executionTransactor,
      );

      await expectLater(
        createWorkflowTaskTriple(
          ctx: failingContext,
          workflowWorkspaceDir: p.join(tempDir.path, 'workflow-workspace'),
          taskId: 'task-rollback',
          run: _run(),
          step: const WorkflowStep(id: 'step-1', name: 'Step 1'),
          stepIndex: 0,
          title: 'Title',
          description: 'Prompt',
          type: TaskType.coding,
          provider: 'codex',
          projectId: null,
          maxTokens: null,
          taskConfig: const {},
        ),
        throwsStateError,
      );

      expect(await taskRepository.getById('task-rollback'), isNull);
      expect(await agentExecutionRepository.list(), isEmpty);
    });

    test('builds follow-up prompts and augments only the last one', () {
      final followUps = buildOneShotFollowUpPrompts(
        const WorkflowStep(
          id: 'step-1',
          name: 'Step 1',
          prompts: ['first', 'second {{NAME}}', 'third'],
          outputs: {'answer': OutputConfig()},
        ),
        WorkflowContext(variables: {'NAME': 'Alice'}),
        const {'answer': OutputConfig(format: OutputFormat.text)},
        outputKeys: const ['answer'],
        templateEngine: WorkflowTemplateEngine(),
        skillPromptBuilder: StepPromptConfiguration().skillPromptBuilder,
      );

      expect(followUps.first, equals('second Alice'));
      expect(followUps.last, contains('<step-outcome>'));
    });

    test('builds strict structured-output envelope schema for narrative outputs only', () {
      final schema = buildStructuredOutputEnvelopeSchema(const WorkflowStep(id: 'step-1', name: 'Step 1'), const {
        'summary': OutputConfig(format: OutputFormat.text),
        'files': OutputConfig(format: OutputFormat.lines),
      });

      expect(schema, containsPair('additionalProperties', false));
      expect(schema?['required'], equals(['summary']));
      expect((schema?['properties'] as Map).containsKey('files'), isFalse);
    });

    test('buildStepConfig and stripWorkflowStepConfig preserve public task config only', () {
      final config = buildStepConfig(
        _run(),
        const WorkflowDefinition(
          name: 'wf',
          description: 'test',
          project: 'proj',
          steps: [WorkflowStep(id: 'step-1', name: 'Step 1')],
        ),
        const WorkflowStep(id: 'step-1', name: 'Step 1'),
        const ResolvedStepConfig(model: 'm', allowedTools: ['file_write']),
        WorkflowContext(variables: {'BRANCH': 'feature'}),
        resolvedWorktreeMode: 'per-task',
        effectivePromotion: 'merge',
        workflowWorkspaceDir: '/tmp/workflow-workspace',
      );

      expect(config['_workflowNeedsWorktree'], isTrue);
      expect(config.keys.where((key) => key.contains('StepType')), isEmpty);
      expect(config['reviewMode'], equals('auto-accept'));
      expect(config['_baseRef'], equals('feature'));
      expect(stripWorkflowStepConfig({...config, 'keep': true}).containsKey('_workflowGit'), isFalse);
      expect(stripWorkflowStepConfig({...config, 'keep': true}).containsKey('model'), isFalse);
      expect(stripWorkflowStepConfig({...config, 'keep': true})['keep'], isTrue);
    });
  });
}

WorkflowRun _run() {
  final now = DateTime(2026, 1, 1);
  return WorkflowRun(
    id: 'run-1',
    definitionName: 'wf',
    status: WorkflowRunStatus.running,
    startedAt: now,
    updatedAt: now,
  );
}

final class _ThrowingWorkflowStepExecutionRepository implements WorkflowStepExecutionRepository {
  @override
  Future<void> create(WorkflowStepExecution execution) async => throw StateError('boom');

  @override
  Future<void> delete(String taskId) async {}

  @override
  Future<WorkflowStepExecution?> getByTaskId(String taskId) async => null;

  @override
  Future<List<WorkflowStepExecution>> listByRunId(String workflowRunId) async => const [];

  @override
  Future<void> update(WorkflowStepExecution execution) async {}
}
