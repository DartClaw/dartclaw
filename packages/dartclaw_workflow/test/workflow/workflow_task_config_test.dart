import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowTaskConfig;
import 'package:test/test.dart';

void main() {
  late InMemoryWorkflowStepExecutionRepository repository;
  late Task task;
  late WorkflowStepExecution baseExecution;

  setUp(() {
    repository = InMemoryWorkflowStepExecutionRepository();
    task = Task(
      id: 'task-1',
      title: 'Workflow task',
      description: 'desc',
      type: TaskType.coding,
      createdAt: DateTime(2026),
      workflowRunId: 'run-1',
      stepIndex: 0,
    );
    baseExecution = const WorkflowStepExecution(
      taskId: 'task-1',
      agentExecutionId: 'ae-1',
      workflowRunId: 'run-1',
      stepIndex: 0,
      stepId: 'step-1',
    );
  });

  group('WorkflowTaskConfig reads', () {
    test('returns defaults when no WSE row exists', () async {
      expect(await WorkflowTaskConfig.readFollowUpPrompts(task, repository), isEmpty);
      expect(await WorkflowTaskConfig.readStructuredSchema(task, repository), isNull);
      expect(await WorkflowTaskConfig.readStructuredOutputPayload(task, repository), isNull);
      expect(await WorkflowTaskConfig.readProviderSessionId(task, repository), isNull);
      expect(await WorkflowTaskConfig.readContinueProviderSessionId(task, repository), isNull);
      expect(await WorkflowTaskConfig.readWorkflowStepId(task, repository), isNull);
      expect(await WorkflowTaskConfig.readInputTokensNew(task, repository), 0);
      expect(await WorkflowTaskConfig.readCacheReadTokens(task, repository), 0);
      expect(await WorkflowTaskConfig.readOutputTokens(task, repository), 0);
    });

    test('reads structured values from WSE storage', () async {
      await repository.create(
        baseExecution.copyWith(
          providerSessionId: '  sess-123  ',
          structuredSchemaJson: '{"type":"object","required":["answer"]}',
          structuredOutputJson: '{"answer":"ok"}',
          followUpPromptsJson: '["a",1,null]',
          stepTokenBreakdownJson: '{"inputTokensNew":12,"cacheReadTokens":4,"outputTokens":8}',
        ),
      );

      expect(await WorkflowTaskConfig.readFollowUpPrompts(task, repository), ['a', '1', 'null']);
      expect(await WorkflowTaskConfig.readStructuredSchema(task, repository), {
        'type': 'object',
        'required': ['answer'],
      });
      expect(await WorkflowTaskConfig.readStructuredOutputPayload(task, repository), {'answer': 'ok'});
      expect(await WorkflowTaskConfig.readProviderSessionId(task, repository), 'sess-123');
      expect(await WorkflowTaskConfig.readContinueProviderSessionId(task, repository), 'sess-123');
      expect(await WorkflowTaskConfig.readWorkflowStepId(task, repository), 'step-1');
      expect(await WorkflowTaskConfig.readInputTokensNew(task, repository), 12);
      expect(await WorkflowTaskConfig.readCacheReadTokens(task, repository), 4);
      expect(await WorkflowTaskConfig.readOutputTokens(task, repository), 8);
    });
  });

  group('WorkflowTaskConfig writes', () {
    test('updates repository-backed workflow metadata', () async {
      await repository.create(baseExecution);

      await WorkflowTaskConfig.writeFollowUpPrompts(task, repository, ['p1', 'p2']);
      await WorkflowTaskConfig.writeStructuredSchema(task, repository, {
        'type': 'object',
        'required': ['answer'],
      });
      await WorkflowTaskConfig.writeProviderSessionId(task, repository, 'sess-abc');
      await WorkflowTaskConfig.writeStructuredOutputPayload(task, repository, {'answer': 42});
      await WorkflowTaskConfig.writeTokenBreakdown(
        task,
        repository,
        inputTokensNew: 10,
        cacheReadTokens: 3,
        outputTokens: 7,
      );

      final stored = await repository.getByTaskId(task.id);
      expect(stored, isNotNull);
      expect(stored!.followUpPrompts, ['p1', 'p2']);
      expect(stored.structuredSchema, {
        'type': 'object',
        'required': ['answer'],
      });
      expect(stored.providerSessionId, 'sess-abc');
      expect(stored.structuredOutput, {'answer': 42});
      expect(stored.stepTokenBreakdown, {
        'inputTokensNew': 10,
        'cacheReadTokens': 3,
        'outputTokens': 7,
      });
    });

    test('mirrors token breakdown into task config keys for artifact consumers', () {
      final configJson = WorkflowTaskConfig.withTaskConfigTokenBreakdown(
        const {'existing': true},
        inputTokensNew: 600,
        cacheReadTokens: 400,
        outputTokens: 500,
      );

      expect(configJson, {
        'existing': true,
        '_workflowInputTokensNew': 600,
        '_workflowCacheReadTokens': 400,
        '_workflowOutputTokens': 500,
      });
    });

    test('builds a merge patch containing only the workflow token keys', () {
      final patch = WorkflowTaskConfig.taskConfigTokenBreakdownPatch(
        inputTokensNew: 600,
        cacheReadTokens: 400,
        outputTokens: 500,
      );

      // Patch is disjoint from other task-config fields, so
      // `TaskService.mergeConfigJson` can apply it atomically without
      // clobbering concurrent updates to unrelated keys.
      expect(patch, {
        '_workflowInputTokensNew': 600,
        '_workflowCacheReadTokens': 400,
        '_workflowOutputTokens': 500,
      });
    });

    test('throws when writing without an existing WSE row', () async {
      expect(
        () => WorkflowTaskConfig.writeProviderSessionId(task, repository, 'sess'),
        throwsA(isA<StateError>()),
      );
    });
  });
}
