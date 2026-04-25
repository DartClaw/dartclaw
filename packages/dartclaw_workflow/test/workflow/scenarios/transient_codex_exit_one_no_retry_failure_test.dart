import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' show TaskStatus, TaskType;
import 'package:dartclaw_server/dartclaw_server.dart' show WorkflowCliProviderConfig, WorkflowCliRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeCodexProcess;
import 'package:test/test.dart';

import '../scenario_test_support.dart';

// failure twin of: transient_codex_exit_one_retry_test.dart
// scenario-types: continueSession, plain

void main() {
  test('maxRetries=0 does not retry on exit 1 — task fails permanently', () async {
    final harness = await ScenarioTaskHarness.create();
    addTearDown(harness.dispose);

    var invocations = 0;
    final runner = WorkflowCliRunner(
      providers: const {'codex': WorkflowCliProviderConfig(executable: 'codex')},
      processStarter: (exe, args, {workingDirectory, environment}) async {
        final attempt = invocations++;
        final exitCode = Completer<int>();
        final process = FakeCodexProcess(exitCodeFuture: exitCode.future);
        scheduleMicrotask(() {
          process.emitLine({'type': 'thread.started', 'thread_id': 'codex-thread-${attempt + 1}'});
          exitCode.complete(1); // always exit 1
        });
        return process;
      },
    );
    final executor = harness.buildExecutor(workflowCliRunner: runner);
    addTearDown(executor.stop);

    await harness.tasks.create(
      id: 'task-no-retry',
      title: 'No retry on exit 1',
      description: 'Should fail permanently.',
      type: TaskType.coding,
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

    await executor.pollOnce();
    final afterPoll = await harness.tasks.get('task-no-retry');

    // With maxRetries=0, a single exit 1 must result in failed, not queued.
    expect(afterPoll?.status, TaskStatus.failed);
    // Only one attempt was made.
    expect(invocations, 1);
  });
}
