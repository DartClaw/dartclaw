import 'package:dartclaw_models/dartclaw_models.dart';
import 'package:dartclaw_workflow/src/workflow/approval_step_runner.dart';
import 'package:dartclaw_workflow/src/workflow/workflow_runner_types.dart';
import 'package:test/test.dart';

void main() {
  group('approval_step_runner', () {
    test('exports uniform runner signature', () {
      Future<StepOutcome> Function(ActionNode, StepExecutionContext) runner = approvalStepRun;
      expect(runner, same(approvalStepRun));
    });
  });
}
