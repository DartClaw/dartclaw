import 'package:dartclaw_cli/src/commands/workflow/cli_progress_printer.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_event_printer_dispatch.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show MapIterationCompletedEvent, WorkflowStepCompletedEvent;
import 'package:test/test.dart';

void main() {
  group('workflow event printer dispatch', () {
    test('maps step outcomes to printer statuses', () {
      final output = <String>[];
      final printer = CliProgressPrinter(totalSteps: 3, workflowName: 'demo', writeLine: output.add);
      final timestamp = DateTime.utc(2026, 4);

      dispatchWorkflowStepCompletedToPrinter(
        printer: printer,
        event: WorkflowStepCompletedEvent(
          runId: 'run-1',
          stepId: 'implement',
          stepName: 'Implement',
          stepIndex: 1,
          totalSteps: 3,
          taskId: 'task-1',
          success: false,
          outcome: 'needsInput',
          reason: 'operator decision',
          tokenCount: 0,
          timestamp: timestamp,
        ),
        duration: null,
        progressKey: 'task:task-1',
      );
      dispatchWorkflowStepCompletedToPrinter(
        printer: printer,
        event: WorkflowStepCompletedEvent(
          runId: 'run-1',
          stepId: 'verify',
          stepName: 'Verify',
          stepIndex: 2,
          totalSteps: 3,
          taskId: 'task-2',
          success: false,
          outcome: 'cancelled',
          reason: 'run teardown',
          tokenCount: 0,
          timestamp: timestamp,
        ),
        duration: null,
        progressKey: 'task:task-2',
      );
      dispatchWorkflowStepCompletedToPrinter(
        printer: printer,
        event: WorkflowStepCompletedEvent(
          runId: 'run-1',
          stepId: 'contradictory',
          stepName: 'Contradictory',
          stepIndex: 0,
          totalSteps: 3,
          taskId: 'task-3',
          success: true,
          outcome: 'failed',
          reason: 'explicit failure outcome',
          tokenCount: 9,
          timestamp: timestamp,
        ),
        duration: const Duration(seconds: 2),
        progressKey: 'task:task-3',
      );

      expect(output[0], '[step 2/3] implement: blocked (recoverable): operator decision');
      expect(output[1], '[step 3/3] verify: interrupted (resumable): run teardown');
      expect(output[2], '[step 1/3] contradictory: failed – explicit failure outcome');
    });

    test('maps map iteration blocked aliases and success fallback', () {
      final output = <String>[];
      final printer = CliProgressPrinter(totalSteps: 3, workflowName: 'demo', writeLine: output.add);
      final timestamp = DateTime.utc(2026, 4);

      dispatchMapIterationCompletedToPrinter(
        printer: printer,
        event: MapIterationCompletedEvent(
          runId: 'run-1',
          stepId: 'story-pipeline',
          iterationIndex: 0,
          totalIterations: 2,
          itemId: 'S01',
          taskId: '',
          success: false,
          outcome: 'blocked',
          reason: null,
          tokenCount: 0,
          timestamp: timestamp,
        ),
        stepIndex: 0,
        duration: null,
        progressKey: 'step:0:S01',
      );
      dispatchMapIterationCompletedToPrinter(
        printer: printer,
        event: MapIterationCompletedEvent(
          runId: 'run-1',
          stepId: 'story-pipeline',
          iterationIndex: 1,
          totalIterations: 2,
          itemId: 'S02',
          taskId: '',
          success: true,
          tokenCount: 7,
          timestamp: timestamp,
        ),
        stepIndex: 0,
        duration: null,
        progressKey: 'step:0:S02',
      );

      expect(output[0], '[step 1/3] story-pipeline[S01]: blocked (recoverable)');
      expect(output[1], '[step 1/3] story-pipeline[S02]: completed (7 tokens)');
    });
  });
}
