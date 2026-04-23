import 'package:dartclaw_models/dartclaw_models.dart';
import 'package:dartclaw_workflow/src/workflow/workflow_runner_types.dart';
import 'package:test/test.dart';

void main() {
  group('StepHandoff', () {
    test('constructs success handoff from StepOutcome', () {
      const step = WorkflowStep(id: 's1', name: 'Step 1', prompts: ['do it']);
      const outcome = StepOutcome(step: step, outputs: {'answer': 42}, tokenCount: 7, success: true);

      final handoff = StepHandoffSuccess(
        outputs: Map<String, Object?>.from(outcome.outputs),
        cost: const StepTokenBreakdown(totalTokens: 7),
        outcome: outcome,
      );

      expect(handoff.outputs, equals({'answer': 42}));
      expect(handoff.validationFailure, isNull);
      expect(handoff.cost.totalTokens, equals(7));
      expect(handoff.outcome, same(outcome));
    });

    test('supports exhaustive pattern matching over subtypes', () {
      const failure = StepValidationFailure(reason: 'missing files', missingArtifacts: ['a.md']);
      final handoffs = <StepHandoff>[
        StepHandoffSuccess(outputs: const {'ok': true}),
        StepHandoffValidationFailed(outputs: const {}, validationFailure: failure),
        StepHandoffRetrying(outputs: const {}, retryState: const StepRetryState(attempt: 1, maxAttempts: 2)),
      ];

      final labels = handoffs.map((handoff) {
        return switch (handoff) {
          StepHandoffSuccess() => 'success',
          StepHandoffValidationFailed(:final validationFailure) => validationFailure.missingPaths.join(','),
          StepHandoffRetrying(:final retryState) => 'retry-${retryState.attempt}',
        };
      }).toList();

      expect(labels, equals(['success', 'a.md', 'retry-1']));
    });
  });
}
