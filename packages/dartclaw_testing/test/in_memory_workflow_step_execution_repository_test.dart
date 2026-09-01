import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  group('InMemoryWorkflowStepExecutionRepository', () {
    test('stores workflow steps and lists a run by step then task id', () async {
      final repository = InMemoryWorkflowStepExecutionRepository();
      await repository.create(_execution(taskId: 'task-b', workflowRunId: 'run-1', stepIndex: 1));
      await repository.create(_execution(taskId: 'task-c', workflowRunId: 'run-2', stepIndex: 0));
      await repository.create(_execution(taskId: 'task-a', workflowRunId: 'run-1', stepIndex: 1));
      await repository.create(_execution(taskId: 'task-zero', workflowRunId: 'run-1', stepIndex: 0));

      expect(
        await repository.getByTaskId('task-a'),
        _execution(taskId: 'task-a', workflowRunId: 'run-1', stepIndex: 1),
      );
      expect((await repository.listByRunId('run-1')).map((execution) => execution.taskId), [
        'task-zero',
        'task-a',
        'task-b',
      ]);
    });

    test('rejects duplicate creates and updates only existing rows', () async {
      final repository = InMemoryWorkflowStepExecutionRepository();
      final execution = _execution();
      await repository.create(execution);

      await expectLater(repository.create(execution), throwsArgumentError);
      await repository.update(execution.copyWith(providerSessionId: 'session-1'));
      expect((await repository.getByTaskId(execution.taskId))?.providerSessionId, 'session-1');
      await expectLater(repository.update(_execution(taskId: 'missing')), throwsArgumentError);
    });

    test('deletes rows and records disposal', () async {
      final repository = InMemoryWorkflowStepExecutionRepository();
      final execution = _execution();
      await repository.create(execution);

      await repository.delete(execution.taskId);
      expect(await repository.getByTaskId(execution.taskId), isNull);

      await repository.dispose();
      expect(repository.disposed, isTrue);
    });
  });
}

WorkflowStepExecution _execution({String taskId = 'task-1', String workflowRunId = 'run-1', int stepIndex = 0}) =>
    WorkflowStepExecution(
      taskId: taskId,
      agentExecutionId: 'agent-$taskId',
      workflowRunId: workflowRunId,
      stepIndex: stepIndex,
      stepId: 'step-$stepIndex',
    );
