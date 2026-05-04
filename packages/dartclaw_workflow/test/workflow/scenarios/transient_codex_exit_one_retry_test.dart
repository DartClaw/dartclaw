import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' show TaskStatus, TaskType;
import 'package:dartclaw_server/dartclaw_server.dart' show WorkflowCliProviderConfig, WorkflowCliRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeCodexProcess;
import 'package:test/test.dart';

import '../scenario_test_support.dart';

// scenario-types: continueSession, plain

void main() {
  test('transient codex exit 1 retries once and then succeeds', () async {
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
          if (attempt != 0) {
            process.emitLine({
              'type': 'item.completed',
              'item': {'type': 'agent_message', 'text': 'Recovered on retry.'},
            });
            process.emitLine({
              'type': 'turn.completed',
              'usage': {'input_tokens': 12, 'output_tokens': 4},
            });
          }
          exitCode.complete(attempt == 0 ? 1 : 0);
        });
        return process;
      },
    );
    final executor = harness.buildExecutor(workflowCliRunner: runner);
    addTearDown(executor.stop);

    await harness.tasks.create(
      id: 'task-transient-codex',
      title: 'Retry transient codex exit',
      description: 'Retry once on exit 1.',
      type: TaskType.coding,
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

    await executor.pollOnce();
    final afterFirst = await harness.tasks.get('task-transient-codex');
    expect(afterFirst?.status, TaskStatus.queued);
    expect(afterFirst?.retryCount, 1);

    await executor.pollOnce();
    final afterSecond = await harness.tasks.get('task-transient-codex');
    expect(invocations, 2);
    expect(afterSecond?.status, anyOf(TaskStatus.review, TaskStatus.accepted));
  });
}
