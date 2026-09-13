import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  group('SqliteExecutionRepositoryTransactor', () {
    late SqliteBackend backend;
    late SqliteTaskRepository tasks;
    late SqliteAgentExecutionRepository agentExecutions;
    late SqliteWorkflowStepExecutionRepository stepExecutions;
    late SqliteExecutionRepositoryTransactor transactor;

    setUp(() async {
      backend = await openPreparedTaskBackend();
      tasks = SqliteTaskRepository(backend);
      agentExecutions = SqliteAgentExecutionRepository(backend);
      stepExecutions = SqliteWorkflowStepExecutionRepository(backend);
      transactor = SqliteExecutionRepositoryTransactor(backend);
    });

    tearDown(() async {
      await backend.close();
    });

    test('commits every participant when the body succeeds', () async {
      await transactor.transaction(() async {
        await tasks.insert(_task('task-commit'));
        await agentExecutions.create(_agentExecution('agent-commit'));
        await stepExecutions.create(_stepExecution('task-commit', 'agent-commit'));
      });

      expect(await tasks.getById('task-commit'), isNotNull);
      expect(await agentExecutions.get('agent-commit'), isNotNull);
      expect(await stepExecutions.getByTaskId('task-commit'), isNotNull);
    });

    test('rolls back every participant when the body throws', () async {
      final bodyError = StateError('stop the action');
      Object? receivedError;

      try {
        await transactor.transaction(() async {
          await tasks.insert(_task('task-rollback'));
          await agentExecutions.create(_agentExecution('agent-rollback'));
          await stepExecutions.create(_stepExecution('task-rollback', 'agent-rollback'));
          throw bodyError;
        });
      } catch (error) {
        receivedError = error;
      }

      expect(receivedError, same(bodyError));
      expect(await tasks.getById('task-rollback'), isNull);
      expect(await agentExecutions.get('agent-rollback'), isNull);
      expect(await stepExecutions.getByTaskId('task-rollback'), isNull);
    });

    test('outside operation waits and nested action is rejected', () async {
      final bodyStarted = Completer<void>();
      final attemptNested = Completer<void>();
      final nestedError = Completer<Object>();
      final releaseBody = Completer<void>();
      final bodyError = StateError('roll back the body');
      final completionOrder = <String>[];
      var actionSettled = false;

      final action = transactor.transaction<void>(() async {
        await agentExecutions.create(_agentExecution('inside-action'));
        bodyStarted.complete();
        await attemptNested.future;
        try {
          await transactor.transaction<void>(() async {});
        } catch (error) {
          nestedError.complete(error);
        }
        await releaseBody.future;
        throw bodyError;
      });
      final observedAction = action.then<Object?>(
        (_) {
          actionSettled = true;
          completionOrder.add('action');
          return null;
        },
        onError: (Object error) {
          actionSettled = true;
          completionOrder.add('action');
          return error;
        },
      );

      await bodyStarted.future;
      final outsideWrite = backend.execute('INSERT INTO agent_executions (id) VALUES (?)', ['outside-action']).then((
        changed,
      ) {
        expect(actionSettled, isTrue);
        completionOrder.add('outside');
        return changed;
      });
      attemptNested.complete();

      expect(await nestedError.future, isA<NestedTransactionError>());
      releaseBody.complete();
      expect(await observedAction, same(bodyError));
      expect(await outsideWrite, 1);
      expect(completionOrder, ['action', 'outside']);
      expect(await agentExecutions.get('inside-action'), isNull);
      expect(await agentExecutions.get('outside-action'), isNotNull);
    });
  });
}

Task _task(String id) => Task(
  id: id,
  title: 'Task $id',
  description: 'Transaction participant',
  createdAt: DateTime.parse('2026-09-08T00:00:00Z'),
);

AgentExecution _agentExecution(String id) => AgentExecution(id: id, provider: 'codex');

WorkflowStepExecution _stepExecution(String taskId, String agentExecutionId) => WorkflowStepExecution(
  taskId: taskId,
  agentExecutionId: agentExecutionId,
  workflowRunId: 'run-1',
  stepIndex: 0,
  stepId: 'step-1',
);
