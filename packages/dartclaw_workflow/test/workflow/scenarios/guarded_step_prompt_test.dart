import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'package:dartclaw_core/dartclaw_core.dart' show TaskStatus;
import 'package:test/test.dart';

import '../scenario_test_support.dart';

void main() {
  test('a workflow prompt blocked by the scenario fixture guard never reaches the harness', () async {
    final harness = await ScenarioTaskHarness.create();
    addTearDown(harness.dispose);
    final executor = harness.buildExecutor();
    addTearDown(executor.stop);

    await harness.tasks.create(
      id: 'task-blocked-scenario-prompt',
      title: 'Blocked workflow prompt',
      description: 'BLOCK_WORKFLOW_PROMPT',
      configJson: const {'needsWorktree': false},
      autoStart: true,
      agentExecutionId: 'ae-task-blocked-scenario-prompt',
      workflowRunId: 'wf-blocked-scenario-prompt',
      provider: 'claude',
    );
    await harness.seedWorkflowExecution(
      'task-blocked-scenario-prompt',
      agentExecutionId: 'ae-task-blocked-scenario-prompt',
      workflowRunId: 'wf-blocked-scenario-prompt',
    );

    await executor.pollOnce();
    await executor.drain();

    final task = (await harness.tasks.get('task-blocked-scenario-prompt'))!;
    expect(task.status, TaskStatus.failed);
    expect(harness.worker.turnCount, 0);
    final transcript = await harness.messages.getMessages(task.sessionId!);
    expect(transcript.last.content, startsWith('[Blocked by guard:'));
  });

  test('the scenario fixture applies and clears the task tool policy around a harness turn', () async {
    final harness = await ScenarioTaskHarness.create();
    addTearDown(harness.dispose);
    final duringTurn = <String, GuardVerdict>{};
    Future<GuardVerdict> probe(String sessionId, String toolName) => harness.taskToolFilterGuard.evaluate(
      GuardContext(hookPoint: 'beforeToolCall', toolName: toolName, sessionId: sessionId, timestamp: DateTime.now()),
    );
    harness.worker.beforeComplete = (sessionId) async {
      for (final toolName in ['shell', 'file_read', 'file_write']) {
        duringTurn[toolName] = await probe(sessionId, toolName);
      }
    };
    final executor = harness.buildExecutor();
    addTearDown(executor.stop);

    await harness.tasks.create(
      id: 'task-scenario-tool-policy',
      title: 'Tool policy workflow step',
      description: 'Observe the task policy during the harness turn.',
      autoStart: true,
      agentExecutionId: 'ae-task-scenario-tool-policy',
      workflowRunId: 'wf-task-scenario-tool-policy',
      provider: 'claude',
      configJson: const {
        'needsWorktree': false,
        'allowedTools': ['file_read'],
        'readOnly': true,
      },
    );
    await harness.seedWorkflowExecution(
      'task-scenario-tool-policy',
      agentExecutionId: 'ae-task-scenario-tool-policy',
      workflowRunId: 'wf-task-scenario-tool-policy',
    );

    await executor.pollOnce();
    await executor.drain();

    final task = (await harness.tasks.get('task-scenario-tool-policy'))!;
    expect(task.status, TaskStatus.review);
    expect(duringTurn['shell']?.isBlock, isTrue);
    expect(duringTurn['file_read']?.isPass, isTrue);
    expect(duringTurn['file_write']?.isBlock, isTrue);
    expect((await probe(task.sessionId!, 'shell')).isPass, isTrue);
    expect((await probe(task.sessionId!, 'file_write')).isPass, isTrue);
  });
}
