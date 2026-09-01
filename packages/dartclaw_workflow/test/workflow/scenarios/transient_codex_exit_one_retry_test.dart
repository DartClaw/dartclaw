import 'package:dartclaw_core/dartclaw_core.dart' show TaskStatus, TurnResult;
import 'package:test/test.dart';

import '../scenario_test_support.dart';

// scenario-types: continueSession, plain

void main() {
  test('a transient typed harness failure retries once and then succeeds', () async {
    final harness = await ScenarioTaskHarness.create();
    addTearDown(harness.dispose);

    harness.worker.enqueueCrashThenSuccess(
      successContent: 'Recovered on retry.',
      successUsage: const TurnResult(inputTokens: 12, outputTokens: 4),
    );
    final executor = harness.buildExecutor();
    addTearDown(executor.stop);

    await harness.tasks.create(
      id: 'task-transient-codex',
      title: 'Retry transient harness failure',
      description: 'Retry once after a typed turn failure.',
      configJson: const {'needsWorktree': false},
      autoStart: true,
      maxRetries: 1,
      agentExecutionId: 'ae-task-transient-codex',
      workflowRunId: 'wf-transient-codex',
      provider: 'codex',
    );
    await harness.seedWorkflowExecution(
      'task-transient-codex',
      agentExecutionId: 'ae-task-transient-codex',
      workflowRunId: 'wf-transient-codex',
      stepId: 'quick-review',
    );

    final afterFirst = await harness.pollOnceAndWaitForTaskStatus(executor, 'task-transient-codex', const {
      TaskStatus.queued,
    }, trigger: 'retry');
    expect(afterFirst.task.status, TaskStatus.queued);
    expect(afterFirst.task.retryCount, 1);

    final afterSecond = await harness.pollOnceAndWaitForTaskStatus(executor, 'task-transient-codex', const {
      TaskStatus.review,
      TaskStatus.accepted,
    });
    expect(harness.worker.turnCount, 2);
    expect(afterSecond.task.status, anyOf(TaskStatus.review, TaskStatus.accepted));
    // The scripted second reply differs from the first, so this fails if the
    // retry path stops delivering or persisting the recovered response, and the
    // order pins it to the retry rather than the first attempt.
    final transcript = await harness.messages.getMessages(afterSecond.task.sessionId!);
    expect(transcript.where((m) => m.role == 'assistant').map((m) => m.content), [
      '[Turn failed]',
      'Recovered on retry.',
    ]);
  });
}
