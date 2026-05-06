import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/task/workflow_worktree_binder.dart';
import 'package:test/test.dart';

void main() {
  group('WorkflowWorktreeBinder', () {
    test('keeps full workflow run ID as the binding key', () async {
      final binder = _binder();
      final task = _workflowTask(
        workflowRunId: '3a711b3b-9bda-4523-8829-826b0019f205',
        git: const {'worktree': 'shared'},
      );

      expect(await binder.workflowOwnedWorktreeKey(task), '3a711b3b-9bda-4523-8829-826b0019f205');
    });

    test('uses a short stable token for shared worktree task IDs', () async {
      final binder = _binder();
      final task = _workflowTask(
        workflowRunId: '3a711b3b-9bda-4523-8829-826b0019f205',
        git: const {'worktree': 'shared'},
      );

      expect(await binder.workflowOwnedWorktreeTaskId(task), 'wf-72461246f28aea5c');
    });

    test('uses a short stable token for per-map-item worktree task IDs', () async {
      final binder = _binder();
      final task = _workflowTask(
        workflowRunId: '3a711b3b-9bda-4523-8829-826b0019f205',
        git: const {'worktree': 'per-map-item'},
        mapIterationIndex: 0,
      );

      expect(await binder.workflowOwnedWorktreeKey(task), '3a711b3b-9bda-4523-8829-826b0019f205:map:0');
      expect(await binder.workflowOwnedWorktreeTaskId(task), 'wf-72461246f28aea5c-map-0');
    });
  });
}

WorkflowWorktreeBinder _binder() => WorkflowWorktreeBinder(
  worktreeManager: null,
  workflowRunRepository: null,
  failTask: (_, {required errorSummary, required retryable}) async {},
);

Task _workflowTask({required String workflowRunId, required Map<String, dynamic> git, int? mapIterationIndex}) => Task(
  id: 'task-1',
  title: 'Workflow task',
  description: 'Workflow task',
  type: TaskType.coding,
  createdAt: DateTime.parse('2026-05-05T12:00:00Z'),
  workflowStepExecution: WorkflowStepExecution(
    taskId: 'task-1',
    agentExecutionId: 'ae-task-1',
    workflowRunId: workflowRunId,
    stepIndex: 0,
    stepId: 'implement',
    stepType: 'coding',
    gitJson: jsonEncode(git),
    mapIterationIndex: mapIterationIndex,
  ),
);
