import 'dart:convert';

import 'package:dartclaw_server/src/task/task_config_view.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  group('TaskConfigView', () {
    test('allowedTools handles null, wrong type, and valid values', () {
      expect(TaskConfigView(_task()).allowedTools, isNull);
      expect(TaskConfigView(_task(configJson: {'allowedTools': 'shell'})).allowedTools, isNull);
      expect(
        TaskConfigView(
          _task(
            configJson: {
              'allowedTools': ['shell', 1],
            },
          ),
        ).allowedTools,
        isNull,
      );
      expect(
        TaskConfigView(
          _task(
            configJson: {
              'allowedTools': ['shell', 'file_read'],
            },
          ),
        ).allowedTools,
        ['shell', 'file_read'],
      );
    });

    test('boolean and workflow readers handle default and valid values', () {
      expect(TaskConfigView(_task()).isReadOnly, isFalse);
      expect(TaskConfigView(_task(configJson: {'readOnly': 'true'})).isReadOnly, isFalse);
      expect(TaskConfigView(_task(configJson: {'readOnly': true})).isReadOnly, isTrue);

      expect(TaskConfigView(_task()).isWorkflowOrchestrated, isFalse);
      expect(TaskConfigView(_task(workflowStepExecution: _workflowStepExecution())).isWorkflowOrchestrated, isTrue);

      expect(TaskConfigView(_task()).needsWorktree, isFalse);
      expect(TaskConfigView(_task(type: TaskType.coding)).needsWorktree, isTrue);
      expect(TaskConfigView(_task(configJson: {'_workflowNeedsWorktree': true})).needsWorktree, isTrue);
    });

    test('reviewMode and postCompletionStatus validate known modes', () {
      expect(TaskConfigView(_task()).reviewMode, isNull);
      expect(TaskConfigView(_task(configJson: {'reviewMode': 12})).reviewMode, isNull);
      expect(TaskConfigView(_task(configJson: {'reviewMode': 'unknown'})).reviewMode, isNull);
      expect(TaskConfigView(_task(configJson: {'reviewMode': ' auto-accept '})).reviewMode, 'auto-accept');
      expect(
        TaskConfigView(_task(configJson: {'reviewMode': 'auto-accept'})).postCompletionStatus,
        TaskStatus.accepted,
      );
      expect(TaskConfigView(_task(configJson: {'reviewMode': 'mandatory'})).postCompletionStatus, TaskStatus.review);
      expect(
        TaskConfigView(_task(configJson: {'reviewMode': 'coding-only'})).postCompletionStatus,
        TaskStatus.accepted,
      );
      expect(
        TaskConfigView(_task(type: TaskType.coding, configJson: {'reviewMode': 'coding-only'})).postCompletionStatus,
        TaskStatus.review,
      );
    });

    test('model, effort, tokenBudget, and baseRef handle null, wrong type, and valid values', () {
      expect(TaskConfigView(_task()).model, isNull);
      expect(TaskConfigView(_task(model: 'gpt-5.4')).model, 'gpt-5.4');

      expect(TaskConfigView(_task()).effort, isNull);
      expect(TaskConfigView(_task(configJson: {'effort': 1})).effort, isNull);
      expect(TaskConfigView(_task(configJson: {'effort': ' high '})).effort, 'high');

      expect(TaskConfigView(_task()).pushBackComment, isNull);
      expect(TaskConfigView(_task(configJson: {'pushBackComment': 1})).pushBackComment, isNull);
      expect(TaskConfigView(_task(configJson: {'pushBackComment': ' revise '})).pushBackComment, 'revise');
      expect(TaskConfigView(_task(configJson: {'lastError': 1})).lastError, isNull);
      expect(TaskConfigView(_task(configJson: {'lastError': 'failed'})).lastError, 'failed');
      expect(TaskConfigView(_task(configJson: {'_continueSessionId': 1})).continueSessionId, isNull);
      expect(TaskConfigView(_task(configJson: {'_continueSessionId': ' session-1 '})).continueSessionId, 'session-1');

      expect(TaskConfigView(_task()).tokenBudget, isNull);
      expect(TaskConfigView(_task(configJson: {'tokenBudget': '100'})).tokenBudget, isNull);
      expect(TaskConfigView(_task(configJson: {'tokenBudget': 100.9})).tokenBudget, 100);
      expect(TaskConfigView(_task(maxTokens: 250, configJson: {'tokenBudget': 100})).tokenBudget, 250);
      expect(TaskConfigView(_task(configJson: {'budget': 50})).tokenBudget, 50);

      expect(TaskConfigView(_task()).baseRef, isNull);
      expect(TaskConfigView(_task(configJson: {'baseRef': 42})).baseRef, isNull);
      expect(TaskConfigView(_task(configJson: {'baseRef': ' main '})).baseRef, 'main');
      expect(TaskConfigView(_task(configJson: {'_baseRef': ' feature ', 'baseRef': 'main'})).baseRef, 'feature');
    });

    test('delegates workflow-owned values to WorkflowTaskConfig', () async {
      final repo = InMemoryWorkflowStepExecutionRepository();
      final task = _task(workflowStepExecution: _workflowStepExecution());
      await repo.create(_workflowStepExecution());

      expect(await TaskConfigView.readWorkflowFollowUpPrompts(task, repo), ['second']);
      expect(await TaskConfigView.readWorkflowStructuredSchema(task, repo), {'type': 'object'});
      expect(await TaskConfigView.readWorkflowStructuredOutputPayload(task, repo), {'result': 'ok'});
      expect(await TaskConfigView.readWorkflowProviderSessionId(task, repo), 'provider-session');
    });
  });
}

Task _task({
  TaskType type = TaskType.custom,
  Map<String, dynamic>? configJson,
  WorkflowStepExecution? workflowStepExecution,
  String? model,
  int? maxTokens,
}) {
  return Task(
    id: 'task-1',
    title: 'Task',
    description: 'Do work',
    type: type,
    configJson: configJson,
    createdAt: DateTime(2026),
    workflowStepExecution: workflowStepExecution,
    model: model,
    maxTokens: maxTokens,
  );
}

WorkflowStepExecution _workflowStepExecution() {
  return WorkflowStepExecution(
    taskId: 'task-1',
    agentExecutionId: 'agent-1',
    workflowRunId: 'run-1',
    stepIndex: 0,
    stepId: 'step-1',
    stepType: 'coding',
    providerSessionId: 'provider-session',
    followUpPromptsJson: jsonEncode(['second']),
    structuredSchemaJson: jsonEncode({'type': 'object'}),
    structuredOutputJson: jsonEncode({'result': 'ok'}),
  );
}
