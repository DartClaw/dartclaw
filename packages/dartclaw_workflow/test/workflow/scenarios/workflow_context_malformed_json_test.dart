import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show ContextExtractor, OutputConfig, OutputFormat, TaskType, WorkflowStep;
import 'package:test/test.dart';

import '../scenario_test_support.dart';

// Adversarial stub: an LLM occasionally emits a `<workflow-context>` block with
// truncated / invalid JSON. The extractor must surface the problem as a
// FormatException rather than silently passing through empty outputs — silent
// failure was observed in early 2026-04-24 investigations where a truncated
// payload left downstream steps reading stale context.

void main() {
  test('malformed workflow-context JSON fails extraction with a FormatException', () async {
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
      content: 'Done.\n\n<workflow-context>{"prd":"docs/prd.md", "unterminated:</workflow-context>',
    );
    await harness.tasks.create(
      id: 'task-malformed-ctx',
      title: 'Extract',
      description: 'Extract',
      type: TaskType.coding,
      autoStart: true,
    );
    await harness.tasks.updateFields('task-malformed-ctx', sessionId: session.id);

    final task = (await harness.tasks.get('task-malformed-ctx'))!;
    final step = const WorkflowStep(
      id: 'plan',
      name: 'Plan',
      outputs: {'prd': OutputConfig(format: OutputFormat.path)},
    );

    await expectLater(extractor.extract(step, task), throwsA(isA<FormatException>()));
  });

  test('workflow-context block containing a JSON array (not an object) fails extraction', () async {
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
      content: 'Done.\n\n<workflow-context>[1, 2, 3]</workflow-context>',
    );
    await harness.tasks.create(
      id: 'task-array-ctx',
      title: 'Extract',
      description: 'Extract',
      type: TaskType.coding,
      autoStart: true,
    );
    await harness.tasks.updateFields('task-array-ctx', sessionId: session.id);

    final task = (await harness.tasks.get('task-array-ctx'))!;
    final step = const WorkflowStep(
      id: 'plan',
      name: 'Plan',
      outputs: {'prd': OutputConfig(format: OutputFormat.path)},
    );

    await expectLater(extractor.extract(step, task), throwsA(isA<FormatException>()));
  });
}
