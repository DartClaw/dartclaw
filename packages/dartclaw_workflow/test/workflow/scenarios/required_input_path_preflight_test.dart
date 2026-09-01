import 'package:dartclaw_core/dartclaw_core.dart' show TaskStatus;
import 'package:test/test.dart';

import '../scenario_test_support.dart';

// scenario-types: plain, map

void main() {
  test('required input path preflight fails before a harness turn starts', () async {
    final harness = await ScenarioTaskHarness.create();
    addTearDown(harness.dispose);

    final executor = harness.buildExecutor(
      worktreeManager: StaticPathWorktreeManager('${harness.tempDir.path}/missing-spec-worktree'),
    );
    addTearDown(executor.stop);

    await harness.tasks.create(
      id: 'task-missing-required-input-scenario',
      title: 'Implement Story',
      description: 'Implement fis/s01.md',
      autoStart: true,
      agentExecutionId: 'ae-task-missing-required-input-scenario',
      workflowRunId: 'wf-missing-required-input-scenario',
      configJson: const {'needsWorktree': true, 'requiredInputPath': 'fis/s01.md'},
    );
    await harness.seedWorkflowExecution(
      'task-missing-required-input-scenario',
      agentExecutionId: 'ae-task-missing-required-input-scenario',
      workflowRunId: 'wf-missing-required-input-scenario',
      stepId: 'implement',
      git: const {'worktree': 'per-map-item'},
      mapIterationIndex: 0,
    );

    final result = await harness.pollOnceAndWaitForTaskStatus(executor, 'task-missing-required-input-scenario', const {
      TaskStatus.failed,
    });

    expect(result.processed, isTrue);
    expect(harness.worker.turnCount, 0);

    expect(result.task.status, TaskStatus.failed);
    expect(result.task.configJson['errorSummary'], contains('required input path "fis/s01.md" is missing'));
  });
}
