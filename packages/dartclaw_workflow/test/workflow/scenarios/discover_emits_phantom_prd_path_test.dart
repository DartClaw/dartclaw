import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show MissingArtifactFailure, OutputConfig, OutputFormat, WorkflowStep;
import 'package:test/test.dart';

import '../scenario_test_support.dart';

// scenario-types: approval, plain

void main() {
  test('phantom path claim fails with MissingArtifactFailure', () async {
    final harness = await ScenarioTaskHarness.create();
    addTearDown(harness.dispose);

    final extractor = harness.contextExtractor();
    final session = await harness.sessions.getOrCreateMainSession();
    await harness.tasks.create(
      id: 'task-phantom-prd',
      title: 'Discover',
      description: 'Discover',
      configJson: const {'needsWorktree': false},
      autoStart: true,
      workflowRunId: 'run-phantom-prd',
    );
    await harness.tasks.updateFields('task-phantom-prd', sessionId: session.id);
    await harness.seedEnvelopeOutputs(
      'task-phantom-prd',
      const {'prd': 'docs/prd.md'},
      workflowRunId: 'run-phantom-prd',
      stepId: 'discover',
    );

    final task = (await harness.tasks.get('task-phantom-prd'))!;
    final step = const WorkflowStep(
      id: 'discover',
      name: 'Discover',
      outputs: {'prd': OutputConfig(format: OutputFormat.path)},
    );

    await expectLater(
      extractor.extract(step, task),
      throwsA(
        isA<MissingArtifactFailure>().having((failure) => failure.claimedPaths, 'claimedPaths', ['docs/prd.md']).having(
          (failure) => failure.missingPaths,
          'missingPaths',
          ['docs/prd.md'],
        ),
      ),
    );
  });
}
