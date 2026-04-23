import 'package:dartclaw_models/dartclaw_models.dart';
import 'package:dartclaw_workflow/src/workflow/bash_step_runner.dart';
import 'package:dartclaw_workflow/src/workflow/workflow_context.dart';
import 'package:dartclaw_workflow/src/workflow/workflow_runner_types.dart';
import 'package:test/test.dart';

void main() {
  group('bash_step_runner', () {
    test('exports uniform runner signature', () {
      Future<StepOutcome> Function(ActionNode, StepExecutionContext) runner = bashStepRun;
      expect(runner, same(bashStepRun));
    });

    test('shell-escapes context substitutions', () {
      final command = resolveBashCommand('printf {{context.value}}', WorkflowContext(data: {'value': 'a b'}));

      expect(command, equals("printf 'a b'"));
    });

    test('extracts line outputs from stdout', () {
      final outputs = extractBashOutputs(
        const WorkflowStep(
          id: 'bash',
          name: 'Bash',
          contextOutputs: ['lines'],
          outputs: {'lines': OutputConfig(format: OutputFormat.lines)},
        ),
        'a\nb\n',
      );

      expect(outputs['lines'], equals(['a', 'b']));
    });
  });
}
