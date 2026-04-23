import 'package:dartclaw_workflow/src/workflow/step_outcome_normalizer.dart';
import 'package:dartclaw_workflow/src/workflow/workflow_runner_types.dart';
import 'package:test/test.dart';

import '../scenario_test_support.dart';

// scenario-types: multi-prompt, map

void main() {
  test('missing story spec artifacts fail normalization without sentinel outputs', () async {
    final harness = await ScenarioTaskHarness.create();
    addTearDown(harness.dispose);

    final handoff = normalizeOutputs(
      const {
        'story_specs': ['docs/plans/foo/fis/a.md', 'docs/plans/foo/fis/b.md'],
      },
      StepOutputNormalizationContext(projectRoot: harness.tempDir.path),
    );

    expect(handoff, isA<StepHandoffValidationFailed>());
    expect(handoff.validationFailure?.missingPaths, ['docs/plans/foo/fis/a.md', 'docs/plans/foo/fis/b.md']);
    expect(handoff.outputs, isEmpty);
    expect(handoff.outputs.keys.where((key) => key.startsWith('_dartclaw.internal')), isEmpty);
  });
}
