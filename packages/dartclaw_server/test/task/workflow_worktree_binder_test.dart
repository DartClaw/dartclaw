import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/task/workflow_worktree_binder.dart';
import 'package:dartclaw_server/src/task/worktree_manager.dart';
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

    test('failed worktree creation does not leak an unhandled waiter error', () async {
      final unhandledErrors = <Object>[];
      await runZonedGuarded<Future<void>>(() async {
        final binder = _binder(worktreeManager: _ThrowingWorktreeManager());
        final task = _workflowTask(
          workflowRunId: '3a711b3b-9bda-4523-8829-826b0019f205',
          git: const {'worktree': 'per-map-item'},
          mapIterationIndex: 7,
        );

        await expectLater(
          () => binder.resolveWorkflowSharedWorktree(
            task,
            workflowWorktreeKey: '3a711b3b-9bda-4523-8829-826b0019f205:map:7',
            workflowWorktreeTaskId: 'wf-72461246f28aea5c-map-7',
            project: null,
            createBranch: true,
            baseRef: 'dartclaw/workflow/3a711b3b9bda45238829826b0019f205/integration',
          ),
          throwsA(isA<WorktreeException>()),
        );
        await Future<void>.delayed(Duration.zero);
      }, (error, _) => unhandledErrors.add(error));

      expect(unhandledErrors, isEmpty);
    });
  });
}

WorkflowWorktreeBinder _binder({WorktreeManager? worktreeManager}) => WorkflowWorktreeBinder(
  worktreeManager: worktreeManager,
  workflowRunRepository: null,
  failTask: (_, {required errorSummary, required retryable}) async {},
);

final class _ThrowingWorktreeManager extends WorktreeManager {
  _ThrowingWorktreeManager() : super(dataDir: '/tmp', projectDir: '/tmp');

  @override
  Future<WorktreeInfo> create(
    String taskId, {
    String? baseRef,
    Project? project,
    bool createBranch = true,
    Map<String, dynamic>? existingWorktreeJson,
  }) async {
    throw WorktreeException('Failed to create worktree at /tmp/$taskId', gitStderr: 'fatal: invalid reference');
  }
}

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
