import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show ContextExtractor, OutputConfig, OutputFormat, TaskType, WorkflowStep;
import 'package:test/test.dart';

import '../scenario_test_support.dart';

// Adversarial stub: an LLM can emit multiple `<workflow-context>` blocks inside
// a single assistant message (e.g. a thinking block followed by a final block).
// The extractor regex is non-greedy and should take the FIRST block in the
// message; tests pin the observed behavior so that future refactors that
// switch to last-block-wins (or merge semantics) flag it explicitly.
//
// If the desired contract changes, update this test — but do it deliberately:
// silently flipping which block the workflow trusts is a silent data-source
// change that's painful to debug from E2E failures.

void main() {
  test('multiple workflow-context blocks in one message — first block wins', () async {
    final harness = await ScenarioTaskHarness.create();
    addTearDown(harness.dispose);

    final extractor = ContextExtractor(
      taskService: harness.tasks,
      messageService: harness.messages,
      dataDir: harness.tempDir.path,
    );
    final session = await harness.sessions.getOrCreateMain();
    await harness.messages.insertMessage(
      sessionId: session.id,
      role: 'assistant',
      content:
          'Drafting…\n\n'
          '<workflow-context>{"diff_summary":"FIRST_BLOCK"}</workflow-context>\n'
          'Revising…\n\n'
          '<workflow-context>{"diff_summary":"SECOND_BLOCK"}</workflow-context>',
    );
    await harness.tasks.create(
      id: 'task-multi-block-ctx',
      title: 'Implement',
      description: 'Implement',
      type: TaskType.coding,
      autoStart: true,
    );
    await harness.tasks.updateFields('task-multi-block-ctx', sessionId: session.id);

    final task = (await harness.tasks.get('task-multi-block-ctx'))!;
    final step = const WorkflowStep(
      id: 'implement',
      name: 'Implement',
      outputs: {'diff_summary': OutputConfig(format: OutputFormat.text)},
    );

    final outputs = await extractor.extract(step, task);
    expect(
      outputs['diff_summary'],
      'FIRST_BLOCK',
      reason:
          'First <workflow-context> block in a message is authoritative. '
          'If this behavior changes, update the test deliberately — silently '
          'switching to last-block-wins is a hard-to-debug data-source flip.',
    );
  });

  test('later assistant message supersedes earlier context blocks', () async {
    final harness = await ScenarioTaskHarness.create();
    addTearDown(harness.dispose);

    final extractor = ContextExtractor(
      taskService: harness.tasks,
      messageService: harness.messages,
      dataDir: harness.tempDir.path,
    );
    final session = await harness.sessions.getOrCreateMain();
    await harness.messages.insertMessage(
      sessionId: session.id,
      role: 'assistant',
      content: '<workflow-context>{"diff_summary":"OLD"}</workflow-context>',
    );
    await harness.messages.insertMessage(
      sessionId: session.id,
      role: 'assistant',
      content: '<workflow-context>{"diff_summary":"CURRENT"}</workflow-context>',
    );
    await harness.tasks.create(
      id: 'task-later-msg-wins',
      title: 'Implement',
      description: 'Implement',
      type: TaskType.coding,
      autoStart: true,
    );
    await harness.tasks.updateFields('task-later-msg-wins', sessionId: session.id);

    final task = (await harness.tasks.get('task-later-msg-wins'))!;
    final step = const WorkflowStep(
      id: 'implement',
      name: 'Implement',
      outputs: {'diff_summary': OutputConfig(format: OutputFormat.text)},
    );

    final outputs = await extractor.extract(step, task);
    expect(outputs['diff_summary'], 'CURRENT');
  });
}
