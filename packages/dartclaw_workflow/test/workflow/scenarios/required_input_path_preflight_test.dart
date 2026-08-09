import 'package:dartclaw_core/dartclaw_core.dart' show TaskType, TaskStatus;
import 'package:dartclaw_server/dartclaw_server.dart' show WorkflowCliProviderConfig, WorkflowCliRunner;
import 'package:test/test.dart';

import '../scenario_test_support.dart';

// scenario-types: plain, map

void main() {
  test('required input path preflight fails before the workflow runner starts', () async {
    final harness = await ScenarioTaskHarness.create();
    addTearDown(harness.dispose);

    var processStarted = false;
    final runner = WorkflowCliRunner(
      providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
      processStarter: (exe, args, {workingDirectory, environment}) async {
        processStarted = true;
        return throw StateError('workflow runner should not start when requiredInputPath is missing');
      },
    );

    final executor = harness.buildExecutor(
      workflowCliRunner: runner,
      worktreeManager: StaticPathWorktreeManager('${harness.tempDir.path}/missing-spec-worktree'),
    );
    addTearDown(executor.stop);

    await harness.tasks.create(
      id: 'task-missing-required-input-scenario',
      title: 'Implement Story',
      description: 'Implement fis/s01.md',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-missing-required-input-scenario',
      workflowRunId: 'wf-missing-required-input-scenario',
      configJson: const {'_workflowNeedsWorktree': true, 'requiredInputPath': 'fis/s01.md'},
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
    expect(processStarted, isFalse);

    expect(result.task.status, TaskStatus.failed);
    expect(result.task.configJson['errorSummary'], contains('required input path "fis/s01.md" is missing'));
  });
}
