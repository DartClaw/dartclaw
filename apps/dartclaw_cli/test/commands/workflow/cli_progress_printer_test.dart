import 'package:dartclaw_cli/src/commands/workflow/cli_progress_printer.dart';
import 'package:dartclaw_cli/src/commands/workflow/live_status_line.dart';
import 'package:dartclaw_cli/src/commands/workflow/standalone_run_harness.dart'
    show progressStartKey, taskProgressKey, taskSettlesLiveEntry;
import 'package:dartclaw_core/dartclaw_core.dart' show TaskStatus;
import 'package:test/test.dart';

void main() {
  group('CliProgressPrinter', () {
    late List<String> output;
    late CliProgressPrinter printer;

    setUp(() {
      output = <String>[];
      printer = CliProgressPrinter(totalSteps: 6, workflowName: 'spec-and-implement', writeLine: output.add);
    });

    test('workflowStarted outputs correct format', () {
      printer.workflowStarted();
      expect(output, hasLength(1));
      expect(output.first, '[workflow] Starting: spec-and-implement (6 steps)');
    });

    test('stepRunning includes provider when present', () {
      printer.stepRunning(0, 'research', 'Research & Design', 'claude');
      expect(output.first, '[step 1/6] research: Research & Design – running (claude)');
    });

    test('stepRunning includes display scope when present', () {
      printer.stepRunning(5, 'implement', 'Implement Story', 'codex', displayScope: 'S01');
      expect(output.first, '[step 6/6] implement[S01]: Implement Story – running (codex)');
    });

    test('stepRunning omits provider suffix when null', () {
      printer.stepRunning(2, 'implement', 'Implement Feature', null);
      expect(output.first, '[step 3/6] implement: Implement Feature – running');
    });

    test('stepReview outputs auto-accepted message', () {
      printer.stepReview(1, 'spec');
      expect(output.first, '[step 2/6] spec: review (auto-accepted)');
    });

    test('stepCompleted formats seconds-only duration', () {
      printer.stepCompleted(0, 'research', const Duration(seconds: 45), 12000);
      expect(output.first, '[step 1/6] research: completed (45s, 12K tokens)');
    });

    test('stepCompleted includes display scope when present', () {
      printer.stepCompleted(5, 'implement', const Duration(minutes: 4, seconds: 41), 91000, displayScope: 'S01');
      expect(output.first, '[step 6/6] implement[S01]: completed (4m 41s, 91K tokens)');
    });

    test('stepCompleted formats minutes+seconds duration', () {
      printer.stepCompleted(1, 'spec', const Duration(minutes: 1, seconds: 2), 18400);
      expect(output.first, '[step 2/6] spec: completed (1m 2s, 18K tokens)');
    });

    test('stepCompleted formats small token count without K suffix', () {
      printer.stepCompleted(0, 'research', const Duration(seconds: 5), 500);
      expect(output.first, '[step 1/6] research: completed (5s, 500 tokens)');
    });

    test('stepCompleted omits duration for an untimed (deterministic) step', () {
      printer.stepCompleted(4, 'verify-all', null, 0);
      expect(output.first, '[step 5/6] verify-all: completed (0 tokens)');
    });

    test('stepFailed includes error when provided', () {
      printer.stepFailed(2, 'implement', 'Context window exceeded');
      expect(output.first, '[step 3/6] implement: failed – Context window exceeded');
    });

    test('stepFailed with null error has no suffix', () {
      printer.stepFailed(2, 'implement', null);
      expect(output.first, '[step 3/6] implement: failed');
    });

    test('workflowApprovalPaused gives --standalone resume guidance in standalone mode', () {
      final standalonePrinter = CliProgressPrinter(
        totalSteps: 6,
        workflowName: 'plan-and-implement-inline',
        writeLine: output.add,
        standalone: true,
      );
      standalonePrinter.workflowApprovalPaused('run-x', 9, 're-review-story', 'needs human decision');
      expect(output[0], '[workflow] Awaiting approval at step 10/6 (re-review-story)');
      expect(output[1], '[workflow] Approval request: needs human decision');
      expect(output[2], contains('dartclaw workflow resume run-x --standalone'));
      expect(output[2], contains('dartclaw workflow cancel run-x --standalone'));
      // A standalone run has no server to start.
      expect(output[2], isNot(contains('dartclaw serve')));
    });

    test('workflowApprovalPaused omits --standalone in connected mode', () {
      // Default printer (standalone: false) targets an already-running server.
      printer.workflowApprovalPaused('run-x', 9, 're-review-story', 'needs human decision');
      expect(output[2], contains('dartclaw workflow resume run-x'));
      expect(output[2], isNot(contains('--standalone')));
      expect(output[2], isNot(contains('dartclaw serve')));
    });

    test('stepBlocked renders recoverable with reason', () {
      printer.stepBlocked(5, 'implement', 'Docker Desktop must be started…', displayScope: 'S02');
      expect(output.first, '[step 6/6] implement[S02]: blocked (recoverable): Docker Desktop must be started…');
    });

    test('stepBlocked with null reason omits the suffix', () {
      printer.stepBlocked(2, 'implement', null);
      expect(output.first, '[step 3/6] implement: blocked (recoverable)');
    });

    test('stepInterrupted renders a resumable interruption with reason', () {
      printer.stepInterrupted(5, 'implement', 'run teardown', displayScope: 'S02');
      expect(output.first, '[step 6/6] implement[S02]: interrupted (resumable): run teardown');
    });

    test('stepInterrupted with null reason omits the suffix', () {
      printer.stepInterrupted(2, 'implement', null);
      expect(output.first, '[step 3/6] implement: interrupted (resumable)');
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

  group('CliProgressPrinter with a live status line', () {
    late List<String> writeLineOutput;
    late List<String> liveOutput;
    late CliProgressPrinter printer;

    setUp(() {
      writeLineOutput = <String>[];
      liveOutput = <String>[];
      printer = CliProgressPrinter(
        totalSteps: 6,
        workflowName: 'spec-and-implement',
        writeLine: writeLineOutput.add,
        liveStatusLine: LiveStatusLine(
          write: liveOutput.add,
          enabled: true,
          color: false,
          now: () => DateTime(2026),
          columns: () => 200,
        ),
      );
    });

    test('a completed line uses distinct per-segment colors yet strips to the exact plain line', () {
      final colorOut = <String>[];
      final colored = CliProgressPrinter(
        totalSteps: 6,
        workflowName: 'spec-and-implement',
        writeLine: (_) {},
        liveStatusLine: LiveStatusLine(
          write: colorOut.add,
          enabled: true,
          color: true,
          now: () => DateTime(2026),
          columns: () => 200,
        ),
      );
      colored.stepCompleted(0, 'research', const Duration(seconds: 45), 12000);
      final out = colorOut.join();
      expect(out, contains('\x1b[97m[step 1/6]\x1b[0m')); // bright-white counter
      expect(out, contains('\x1b[36mresearch:\x1b[0m')); // cyan id
      expect(out, contains('\x1b[1;32mcompleted\x1b[0m')); // bold green status
      expect(out, contains('\x1b[36m12K tokens\x1b[0m')); // cyan tokens
      // Stripping every SGR/escape sequence yields the byte-exact plain line.
      final stripped = out.replaceAll(RegExp(r'\x1b\[[0-9;?]*[A-Za-z]'), '').trim();
      expect(stripped, '[step 1/6] research: completed (45s, 12K tokens)');
    });

    test('a running step becomes a compact spinner, not a permanent "– running" line', () {
      printer.stepRunning(0, 'research', 'Research & Design', 'codex', progressKey: 'task:1');
      expect(writeLineOutput, isEmpty);
      final live = liveOutput.join();
      // Compact label: step id + provider; the verbose task title is dropped.
      expect(live, contains('[step 1/6] research (codex)'));
      expect(live, isNot(contains('Research & Design')));
      expect(live, isNot(contains('– running')));
      printer.workflowCompleted(6, 0);
    });

    test('stepTokens updates the live token count for the running step', () {
      printer.stepRunning(0, 'research', 'Research & Design', 'codex', progressKey: 'task:1');
      printer.stepTokens('task:1', 8400);
      expect(liveOutput.join(), contains('8K tokens'));
      printer.workflowCompleted(6, 0);
    });

    test('completion prints a permanent line above the spinner via the live sink', () {
      printer.stepRunning(0, 'research', 'Research & Design', 'codex', progressKey: 'task:1');
      liveOutput.clear();
      printer.stepCompleted(0, 'research', const Duration(seconds: 5), 5000, progressKey: 'task:1');
      expect(writeLineOutput, isEmpty);
      expect(liveOutput.join(), contains('[step 1/6] research: completed (5s, 5K tokens)\n'));
    });

    test('permanent lines route through the live sink, leaving writeLine untouched', () {
      printer.workflowStarted();
      expect(writeLineOutput, isEmpty);
      expect(liveOutput.join(), contains('[workflow] Starting: spec-and-implement (6 steps)'));
    });

    test('live token routing matches a running step regardless of how its key was built', () {
      // The token event keys on taskId alone; the running step keys on its real
      // stepIndex + displayScope. Both must collapse to the same `task:<id>` key
      // for the live token tick to land on the right step.
      final runningKey = progressStartKey(stepIndex: 3, taskId: '1', displayScope: 'S01');
      final tokenKey = taskProgressKey('1');
      expect(tokenKey, runningKey);
      expect(taskProgressKey('  '), isNull); // blank taskId never collapses to step:0

      printer.stepRunning(3, 'implement', 'Implement', 'codex', displayScope: 'S01', progressKey: runningKey);
      printer.stepTokens(tokenKey!, 6000);
      expect(liveOutput.join(), contains('6K tokens'));
    });

    test('stepSettled retires a settled parallel member without printing a permanent line', () {
      printer.stepRunning(0, 'review-a', 'Review A', 'claude', progressKey: 'task:1');
      printer.stepRunning(0, 'review-b', 'Review B', 'claude', progressKey: 'task:2');
      printer.stepTokens('task:1', 8400);
      liveOutput.clear();
      printer.stepSettled('task:1', countTokens: true);
      expect(writeLineOutput, isEmpty);
      final live = liveOutput.join();
      // Only the still-running member counts; the settled member's live-tick
      // tokens stay in the run total until the barrier reconciles them.
      expect(live, isNot(contains('2 steps running')));
      expect(live, contains('review-b'));
      expect(live, contains('8K total'));
      // The barrier's completion line still lands as permanent output.
      liveOutput.clear();
      printer.stepCompleted(0, 'review-a', const Duration(seconds: 5), 9000, progressKey: 'task:1');
      expect(liveOutput.join(), contains('[step 1/6] review-a: completed (5s, 9K tokens)'));
      printer.workflowCompleted(6, 0);
    });

    test('disposeLive clears a drawn spinner line and is idempotent', () {
      // A run that settles without a terminal printer call (unexpected
      // pending/running, a mid-drive throw, or a stream disconnect that settles
      // terminally) relies on disposeLive in the driver finally to leave the
      // terminal clean and cancel the animation timer.
      printer.stepRunning(0, 'research', 'Research & Design', 'codex', progressKey: 'task:1');
      liveOutput.clear();
      printer.disposeLive();
      expect(liveOutput.join(), '\r\x1b[2K\x1b[?25h'); // erase line + restore cursor
      liveOutput.clear();
      printer.disposeLive(); // second call is a no-op
      expect(liveOutput, isEmpty);
    });
  });

  group('taskSettlesLiveEntry', () {
    test('terminal statuses and interrupted retire the live entry', () {
      expect(taskSettlesLiveEntry(TaskStatus.accepted), isTrue);
      expect(taskSettlesLiveEntry(TaskStatus.rejected), isTrue);
      expect(taskSettlesLiveEntry(TaskStatus.failed), isTrue);
      expect(taskSettlesLiveEntry(TaskStatus.cancelled), isTrue);
      expect(taskSettlesLiveEntry(TaskStatus.interrupted), isTrue);
    });

    test('active and pre-run statuses keep the live entry', () {
      expect(taskSettlesLiveEntry(TaskStatus.running), isFalse);
      expect(taskSettlesLiveEntry(TaskStatus.review), isFalse);
      expect(taskSettlesLiveEntry(TaskStatus.queued), isFalse);
      expect(taskSettlesLiveEntry(TaskStatus.draft), isFalse);
    });
  });

  group('printer-boundary scrubbing of agent-derived text', () {
    late List<String> output;
    late CliProgressPrinter printer;

    setUp(() {
      output = <String>[];
      printer = CliProgressPrinter(totalSteps: 6, workflowName: 'spec-and-implement', writeLine: output.add);
    });

    const injected = 'residual\x1b[2Jfindings\r\nAPPROVED: run `rm -rf`\x07';
    const scrubbed = 'residualfindings APPROVED: run `rm -rf`';

    test('stepFailed strips ANSI/CSI and control characters from the error span', () {
      printer.stepFailed(2, 'implement', injected);
      expect(output.first, '[step 3/6] implement: failed – $scrubbed');
    });

    test('stepBlocked strips ANSI/CSI and control characters from the reason span', () {
      printer.stepBlocked(2, 'implement', injected);
      expect(output.first, '[step 3/6] implement: blocked (recoverable): $scrubbed');
    });

    test('workflowPaused and workflowFailed strip injected sequences from the reason', () {
      printer.workflowPaused(3, injected);
      printer.workflowFailed(3, injected);
      expect(output[0], '[workflow] Paused at step 4/6: $scrubbed');
      expect(output[1], '[workflow] Failed at step 4/6: $scrubbed');
    });

    test('workflowApprovalPaused strips injected sequences from the approval message', () {
      printer.workflowApprovalPaused('run-1', 2, 'gate', injected);
      expect(output[1], '[workflow] Approval request: $scrubbed');
    });

    test('stepInterrupted strips ANSI/CSI and control characters from the reason span', () {
      printer.stepInterrupted(2, 'implement', injected);
      expect(output.first, '[step 3/6] implement: interrupted (resumable): $scrubbed');
    });

    test('display scopes are scrubbed before they land in the step line', () {
      // Agent-authored item ids flow into every step line via _scopedStepId.
      printer.stepCompleted(0, 'implement', const Duration(seconds: 5), 500, displayScope: 'S01\x1b[2J\r\nS02\x07');
      expect(output.first, '[step 1/6] implement[S01 S02]: completed (5s, 500 tokens)');
      expect(output.first, isNot(contains('\x1b')));
    });
  });
}
