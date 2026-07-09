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
        FileSystemOutput,
        GateEvaluator,
        KvService,
        MessageService,
        OutputConfig,
        OutputFormat,
        OutputMode,
        StepExecutionContext,
        StepPromptConfiguration,
        TaskStatusChangedEvent,
        TaskType,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowRoleDefaults,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowStep,
        WorkflowTaskConfig,
        WorkflowTaskType;
import 'package:dartclaw_workflow/src/workflow/execution_envelope_schema.dart';
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
        dataDir: tempDir.path,
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

    test('exports the host-computed step artifacts dir env, surviving the strip list', () async {
      await createWorkflowTaskTriple(
        ctx: executionContext,
        workflowWorkspaceDir: p.join(tempDir.path, 'workflow-workspace'),
        taskId: 'task-step-artifacts',
        run: _run(),
        step: const WorkflowStep(id: 'review', name: 'Review'),
        stepIndex: 0,
        title: 'Review',
        description: '--auto --output-dir "\$DARTCLAW_STEP_ARTIFACTS_DIR" target',
        type: TaskType.coding,
        provider: 'codex',
        projectId: 'proj',
        maxTokens: null,
        taskConfig: const {},
      );

      final task = (await taskRepository.getById('task-step-artifacts'))!;
      // The description is never mutated — it keeps whatever the YAML authored.
      expect(task.description, '--auto --output-dir "\$DARTCLAW_STEP_ARTIFACTS_DIR" target');
      // The env key is NOT in the strip list, so it persists onto the task.
      expect(task.configJson.containsKey('_workflowStepArtifactsEnv'), isTrue);
      expect(WorkflowTaskConfig.readStepArtifactsEnv(task), {
        'DARTCLAW_STEP_ARTIFACTS_DIR': p.join(
          tempDir.path,
          'workflows',
          'runs',
          'run-1',
          'runtime-artifacts',
          'steps',
          'review',
        ),
      });
    });

    test('exports the step artifacts env on every task, with no --output-dir token required', () async {
      await createWorkflowTaskTriple(
        ctx: executionContext,
        workflowWorkspaceDir: p.join(tempDir.path, 'workflow-workspace'),
        taskId: 'task-no-outputdir',
        run: _run(),
        step: const WorkflowStep(id: 'plan', name: 'Plan'),
        stepIndex: 0,
        title: 'Plan',
        description: '--auto --mode plan target',
        type: TaskType.coding,
        provider: 'codex',
        projectId: 'proj',
        maxTokens: null,
        taskConfig: const {},
      );

      final task = (await taskRepository.getById('task-no-outputdir'))!;
      expect(task.description, '--auto --mode plan target');
      expect(
        WorkflowTaskConfig.readStepArtifactsEnv(task)!['DARTCLAW_STEP_ARTIFACTS_DIR'],
        endsWith(p.join('runtime-artifacts', 'steps', 'plan')),
      );
    });

    test('suffixes the step artifacts dir with the map iteration index', () async {
      await createWorkflowTaskTriple(
        ctx: executionContext,
        workflowWorkspaceDir: p.join(tempDir.path, 'workflow-workspace'),
        taskId: 'task-map-iteration',
        run: _run(),
        step: const WorkflowStep(id: 'story-review', name: 'Story Review'),
        stepIndex: 0,
        title: 'Story Review',
        description: 'Review the story',
        type: TaskType.coding,
        provider: 'codex',
        projectId: 'proj',
        maxTokens: null,
        taskConfig: const {'_mapIterationIndex': 2},
      );

      final task = (await taskRepository.getById('task-map-iteration'))!;
      expect(
        WorkflowTaskConfig.readStepArtifactsEnv(task)!['DARTCLAW_STEP_ARTIFACTS_DIR'],
        endsWith(p.join('runtime-artifacts', 'steps', 'story-review-2')),
      );
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
        dataDir: tempDir.path,
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

    test('builds last follow-up prompt with resolved gatingSeverity', () {
      final followUps = buildOneShotFollowUpPrompts(
        const WorkflowStep(
          id: 'review-step',
          name: 'Review Step',
          prompts: ['first', 'final'],
          outputs: {'gating_findings_count': OutputConfig(format: OutputFormat.json, schema: 'gating_findings_count')},
        ),
        WorkflowContext(),
        const {'gating_findings_count': OutputConfig(format: OutputFormat.json, schema: 'gating_findings_count')},
        outputKeys: const ['gating_findings_count'],
        gatingSeverity: 'critical',
        templateEngine: WorkflowTemplateEngine(),
        skillPromptBuilder: StepPromptConfiguration().skillPromptBuilder,
      );

      expect(followUps.single, contains('## Review Finding Scoring'));
      expect(followUps.single, contains('at or above `critical`'));
      expect(followUps.single, isNot(contains('at or above `high`')));
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

  group('execution envelope schema', () {
    Map<String, dynamic> outputsOf(Map<String, dynamic>? schema) =>
        (schema!['properties'] as Map)['outputs'] as Map<String, dynamic>;

    test('builds a closed envelope with required outputs and step_outcome', () {
      final schema = buildExecutionEnvelopeSchema(const WorkflowStep(id: 's', name: 'S'), const {
        'summary': OutputConfig(format: OutputFormat.text),
      });

      expect(schema!['type'], 'object');
      expect(schema['additionalProperties'], isFalse);
      expect(schema['required'], equals(['outputs', 'step_outcome']));
      final props = schema['properties'] as Map;
      expect(props.keys, containsAll(['outputs', 'step_outcome']));

      final outputs = outputsOf(schema);
      expect(outputs['additionalProperties'], isFalse);
      expect(outputs['required'], equals(['summary']));
      expect((outputs['properties'] as Map)['summary'], equals({'type': 'string'}));

      final stepOutcome = props['step_outcome'] as Map;
      expect(stepOutcome['additionalProperties'], isFalse);
      expect(stepOutcome['required'], equals(['outcome', 'reason']));
      expect(
        ((stepOutcome['properties'] as Map)['outcome'] as Map)['enum'],
        equals(['succeeded', 'failed', 'needsInput']),
      );
    });

    test('omits step_outcome for emitsOwnOutcome steps but keeps output finalization', () {
      final schema = buildExecutionEnvelopeSchema(const WorkflowStep(id: 's', name: 'S', emitsOwnOutcome: true), const {
        'summary': OutputConfig(format: OutputFormat.text),
      });

      expect(schema!['required'], equals(['outputs']));
      expect((schema['properties'] as Map).containsKey('step_outcome'), isFalse);
      expect((outputsOf(schema)['properties'] as Map).containsKey('summary'), isTrue);
    });

    test('excludes host-owned outputs (setValue, source, canonical *_source defaults)', () {
      final schema = buildExecutionEnvelopeSchema(const WorkflowStep(id: 's', name: 'S'), const {
        'summary': OutputConfig(format: OutputFormat.text),
        'pinned': OutputConfig(format: OutputFormat.text, setValue: 'x'),
        'branch': OutputConfig(format: OutputFormat.text, source: 'worktree.branch'),
        'plan_source': OutputConfig(format: OutputFormat.text),
      });

      final outputs = outputsOf(schema);
      expect(outputs['required'], equals(['summary']));
      final keys = (outputs['properties'] as Map).keys;
      expect(keys, isNot(anyElement(isIn(['pinned', 'branch', 'plan_source']))));
    });

    test('declares filesystem path claims as nullable so a no-claim null survives strict mode', () {
      final schema = buildExecutionEnvelopeSchema(const WorkflowStep(id: 's', name: 'S'), const {
        'report': OutputConfig(
          format: OutputFormat.path,
          resolverOverride: FileSystemOutput(pathPattern: '**/*.md', listMode: false),
        ),
      });

      final report = (outputsOf(schema)['properties'] as Map)['report'] as Map;
      expect(report['type'], equals(['string', 'null']));
    });

    test('deep-closes an author inline schema on the envelope copy without mutating the declaration', () {
      const declared = {
        'type': 'object',
        'properties': {
          'a': {'type': 'string'},
          'b': {'type': 'integer'},
        },
        'required': ['a'],
      };
      final schema = buildExecutionEnvelopeSchema(const WorkflowStep(id: 's', name: 'S'), const {
        'obj': OutputConfig(format: OutputFormat.json, schema: declared, outputMode: OutputMode.structured),
      });

      final closed = (outputsOf(schema)['properties'] as Map)['obj'] as Map;
      expect(closed['additionalProperties'], isFalse);
      expect((closed['required'] as List).toSet(), equals({'a', 'b'}));
      // Optional `b` became required + nullable; declared map is untouched.
      expect(((closed['properties'] as Map)['b'] as Map)['type'], equals(['integer', 'null']));
      expect(declared['required'], equals(['a']));
    });

    test('deep-close widens an optional enum property to admit null', () {
      const declared = {
        'type': 'object',
        'properties': {
          'risk': {
            'type': 'string',
            'enum': ['low', 'medium', 'high'],
          },
        },
        'required': <String>[],
      };
      final schema = buildExecutionEnvelopeSchema(const WorkflowStep(id: 's', name: 'S'), const {
        'obj': OutputConfig(format: OutputFormat.json, schema: declared, outputMode: OutputMode.structured),
      });

      final risk = ((outputsOf(schema)['properties'] as Map)['obj'] as Map)['properties'] as Map;
      final riskSchema = risk['risk'] as Map;
      // Optional enum became required + nullable: the type widened AND the enum
      // gained a null member, else the closed schema forbids the absent value.
      expect(riskSchema['type'], equals(['string', 'null']));
      expect(riskSchema['enum'], equals(['low', 'medium', 'high', null]));
      // Declared map is untouched.
      expect(
        (declared['properties'] as Map)['risk'],
        equals({
          'type': 'string',
          'enum': ['low', 'medium', 'high'],
        }),
      );
    });

    test('deep-close widens an optional const property to a nullable enum', () {
      const declared = {
        'type': 'object',
        'properties': {
          'mode': {'const': 'fixed'},
        },
        'required': <String>[],
      };
      final schema = buildExecutionEnvelopeSchema(const WorkflowStep(id: 's', name: 'S'), const {
        'obj': OutputConfig(format: OutputFormat.json, schema: declared, outputMode: OutputMode.structured),
      });

      final props = ((outputsOf(schema)['properties'] as Map)['obj'] as Map)['properties'] as Map;
      final modeSchema = props['mode'] as Map;
      expect(modeSchema.containsKey('const'), isFalse);
      expect(modeSchema['enum'], equals(['fixed', null]));
    });

    test('returns null when the step has no model-derived outputs', () {
      expect(buildExecutionEnvelopeSchema(const WorkflowStep(id: 's', name: 'S'), const {}), isNull);
      expect(
        buildExecutionEnvelopeSchema(const WorkflowStep(id: 's', name: 'S'), const {
          'pinned': OutputConfig(format: OutputFormat.text, setValue: 'x'),
        }),
        isNull,
      );
    });

    test('stepNeedsFinalizer gates on agent task type and model-derived outputs', () {
      const outputs = {'summary': OutputConfig(format: OutputFormat.text)};
      expect(stepNeedsFinalizer(const WorkflowStep(id: 's', name: 'S'), outputs), isTrue);
      expect(
        stepNeedsFinalizer(const WorkflowStep(id: 's', name: 'S', taskType: WorkflowTaskType.bash), outputs),
        isFalse,
      );
      expect(stepNeedsFinalizer(const WorkflowStep(id: 's', name: 'S'), const {}), isFalse);
      expect(
        stepNeedsFinalizer(const WorkflowStep(id: 's', name: 'S'), const {
          'pinned': OutputConfig(format: OutputFormat.text, setValue: 'x'),
        }),
        isFalse,
      );
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
