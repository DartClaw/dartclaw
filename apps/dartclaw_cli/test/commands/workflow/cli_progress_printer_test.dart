import 'package:dartclaw_cli/src/commands/workflow/cli_progress_printer.dart';
import 'package:test/test.dart';

void main() {
  group('CliProgressPrinter', () {
    late List<String> output;
    late CliProgressPrinter printer;

    setUp(() {
      output = <String>[];
      printer = CliProgressPrinter(
        totalSteps: 6,
        workflowName: 'spec-and-implement',
        writeLine: output.add,
      );
    });

    test('workflowStarted outputs correct format', () {
      printer.workflowStarted();
      expect(output, hasLength(1));
      expect(output.first, '[workflow] Starting: spec-and-implement (6 steps)');
    });

    test('stepRunning includes provider when present', () {
      printer.stepRunning(0, 'research', 'Research & Design', 'claude');
      expect(output.first, '[step 1/6] research: Research & Design — running (claude)');
    });

    test('stepRunning omits provider suffix when null', () {
      printer.stepRunning(2, 'implement', 'Implement Feature', null);
      expect(output.first, '[step 3/6] implement: Implement Feature — running');
    });

    test('stepReview outputs auto-accepted message', () {
      printer.stepReview(1, 'spec');
      expect(output.first, '[step 2/6] spec: review (auto-accepted)');
    });

    test('stepCompleted formats seconds-only duration', () {
      printer.stepCompleted(0, 'research', const Duration(seconds: 45), 12000);
      expect(output.first, '[step 1/6] research: completed (45s, 12K tokens)');
    });

    test('stepCompleted formats minutes+seconds duration', () {
      printer.stepCompleted(1, 'spec', const Duration(minutes: 1, seconds: 2), 18400);
      expect(output.first, '[step 2/6] spec: completed (1m 2s, 18K tokens)');
    });

    test('stepCompleted formats small token count without K suffix', () {
      printer.stepCompleted(0, 'research', const Duration(seconds: 5), 500);
      expect(output.first, '[step 1/6] research: completed (5s, 500 tokens)');
    });

    test('stepFailed includes error when provided', () {
      printer.stepFailed(2, 'implement', 'Context window exceeded');
      expect(output.first, '[step 3/6] implement: failed — Context window exceeded');
    });

    test('stepFailed with null error has no suffix', () {
      printer.stepFailed(2, 'implement', null);
      expect(output.first, '[step 3/6] implement: failed');
    });

    test('workflowCompleted shows summary', () {
      printer.workflowStarted();
      output.clear();
      printer.workflowCompleted(6, 89000);
      expect(output.first, startsWith('[workflow] Completed: 6/6 steps ('));
      expect(output.first, contains('89K tokens'));
    });

    test('workflowFailed shows error', () {
      printer.workflowFailed(2, 'Step failed: timeout');
      expect(output.first, '[workflow] Failed at step 3/6: Step failed: timeout');
    });

    test('workflowFailed with null error has no suffix', () {
      printer.workflowFailed(2, null);
      expect(output.first, '[workflow] Failed at step 3/6');
    });

    test('workflowPaused shows reason', () {
      printer.workflowPaused(3, 'Budget exceeded');
      expect(output.first, '[workflow] Paused at step 4/6: Budget exceeded');
    });

    test('workflowCancelling outputs correct message', () {
      printer.workflowCancelling();
      expect(output.first, '[workflow] Cancelling...');
    });
  });
}
