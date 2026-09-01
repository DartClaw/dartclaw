import 'package:dartclaw_cli/src/commands/workflow/cli_progress_printer.dart';
import 'package:dartclaw_cli/src/commands/workflow/connected_progress_decoder.dart';
import 'package:dartclaw_cli/src/commands/workflow/live_status_line.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_progress_renderer.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowDefinition, WorkflowStep;
import 'package:test/test.dart';

/// The connected lane's live-line settle path. Every command-level connected
/// test builds `LiveStatusLine.forStdout`, which is disabled off a TTY, so
/// `stepSettled` is a no-op there and none of them would notice this path
/// breaking. Driven here through the shipped decoder and renderer with the
/// live line enabled.
void main() {
  group('connected frames drive the shared renderer live line', () {
    final definition = WorkflowDefinition(
      name: 'connected',
      description: 'Two steps',
      steps: const [
        WorkflowStep(id: 'first', name: 'First', prompts: ['a'], provider: 'claude'),
        WorkflowStep(id: 'second', name: 'Second', prompts: ['b'], provider: 'claude'),
      ],
    );

    late List<String> liveOut;
    late WorkflowProgressRenderer renderer;

    setUp(() {
      liveOut = <String>[];
      final printer = CliProgressPrinter(
        totalSteps: definition.steps.length,
        workflowName: definition.name,
        writeLine: (_) {},
        liveStatusLine: LiveStatusLine(
          write: liveOut.add,
          enabled: true,
          color: false,
          now: () => DateTime(2026, 7, 1, 12),
          columns: () => 200,
        ),
      );
      // The connected lane's resolver: frame stepIndex plus the definition's step.
      renderer = WorkflowProgressRenderer(
        definition: definition,
        printer: printer,
        jsonOutput: false,
        resolveStepContext: (update) {
          final stepIndex = update.stepIndex;
          if (stepIndex == null || stepIndex >= definition.steps.length) return null;
          final step = definition.steps[stepIndex];
          return TaskStepContext(
            stepIndex: stepIndex,
            stepId: step.id,
            title: step.name,
            provider: step.provider,
            displayScope: update.displayScope,
          );
        },
      );
    });

    Future<void> frame(Map<String, dynamic> json) => renderConnectedWorkflowFrame(json, renderer);

    test('a terminal task status retires the connected lane live entry before the step barrier', () async {
      await frame({'type': 'task_status_changed', 'taskId': 't1', 'stepIndex': 0, 'newStatus': 'running'});
      await frame({'type': 'task_status_changed', 'taskId': 't2', 'stepIndex': 1, 'newStatus': 'running'});
      expect(liveOut.join(), contains('2 steps running'));

      liveOut.clear();
      await frame({'type': 'task_status_changed', 'taskId': 't1', 'stepIndex': 0, 'newStatus': 'accepted'});
      final afterSettle = liveOut.join();
      expect(afterSettle, isNot(contains('2 steps running')));
      expect(afterSettle, contains('[step 2/2] second'));
    });

    test('a live token tick lands under the settling task key', () async {
      await frame({'type': 'task_status_changed', 'taskId': 't1', 'stepIndex': 0, 'newStatus': 'running'});

      liveOut.clear();
      await frame({'type': 'workflow_cli_turn_progress', 'taskId': 't1', 'cumulativeTokens': 110});
      expect(liveOut.join(), contains('110 tokens'));

      liveOut.clear();
      await frame({'type': 'task_status_changed', 'taskId': 't1', 'stepIndex': 0, 'newStatus': 'interrupted'});
      expect(liveOut.join(), isNot(contains('first')));
    });
  });
}
