import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show ContextExtractor, MissingArtifactFailure, OutputConfig, OutputFormat, TaskType, WorkflowStep;
import 'package:test/test.dart';

import '../scenario_test_support.dart';

// scenario-types: approval, plain

void main() {
  test('phantom path claim fails with MissingArtifactFailure', () async {
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
      content: 'Done.\n\n<workflow-context>{"prd":"docs/prd.md"}</workflow-context>',
    );
    await harness.tasks.create(
      id: 'task-phantom-prd',
      title: 'Discover',
      description: 'Discover',
      type: TaskType.coding,
      autoStart: true,
    );
    await harness.tasks.updateFields('task-phantom-prd', sessionId: session.id);

    final task = (await harness.tasks.get('task-phantom-prd'))!;
    final step = const WorkflowStep(
      id: 'discover',
      name: 'Discover',
      contextOutputs: ['prd'],
      outputs: {'prd': OutputConfig(format: OutputFormat.path)},
    );

    await expectLater(
      extractor.extract(step, task),
      throwsA(
        isA<MissingArtifactFailure>()
            .having((failure) => failure.claimedPaths, 'claimedPaths', ['docs/prd.md'])
            .having((failure) => failure.missingPaths, 'missingPaths', ['docs/prd.md']),
      ),
    );
  });
}
