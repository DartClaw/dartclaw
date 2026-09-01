import 'package:dartclaw_core/dartclaw_core.dart' show TaskStatus;
import 'package:test/test.dart';

import '../scenario_test_support.dart';

// failure twin of: transient_codex_exit_one_retry_test.dart
// scenario-types: continueSession, plain

void main() {
  test('maxRetries=0 does not retry a typed harness failure', () async {
    final harness = await ScenarioTaskHarness.create();
    addTearDown(harness.dispose);

    harness.worker.enqueue(const ScriptedResponse(crash: true));
    final executor = harness.buildExecutor();
    addTearDown(executor.stop);

    await harness.tasks.create(
      id: 'task-no-retry',
      title: 'No retry after harness failure',
      description: 'Should fail permanently.',
      configJson: const {'needsWorktree': false},
      autoStart: true,
      maxRetries: 0, // no retries allowed
      agentExecutionId: 'ae-task-no-retry',
      workflowRunId: 'wf-no-retry',
      provider: 'codex',
    );
    await harness.seedWorkflowExecution(
      'task-no-retry',
      agentExecutionId: 'ae-task-no-retry',
      workflowRunId: 'wf-no-retry',
      stepId: 'quick-review',
    );

    final result = await harness.pollOnceAndWaitForTaskStatus(executor, 'task-no-retry', const {TaskStatus.failed});

    // With maxRetries=0, a single harness failure must result in failed, not queued.
    expect(result.task.status, TaskStatus.failed);
    // Only one attempt was made.
    expect(harness.worker.turnCount, 1);
  });
}
