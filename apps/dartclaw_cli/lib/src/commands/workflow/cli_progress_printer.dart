import 'package:dartclaw_core/dartclaw_core.dart' show humanizeDuration;

import '../serve_command.dart' show WriteLine;
import 'agent_text_scrub.dart';
import 'live_status_line.dart';

/// Formats and writes structured workflow progress lines to a [WriteLine] sink.
///
/// Output is human-readable and machine-parseable:
/// ```
/// [workflow] Starting: Spec & Implement (6 steps)
/// [step 1/6] research: Research & Design — running (claude)
/// [step 1/6] research: completed (45s, 12K tokens)
/// [workflow] Completed: 6/6 steps (4m 32s, 89K tokens)
/// ```
///
/// When a [LiveStatusLine] is supplied and enabled (interactive TTY, non-JSON),
/// a running step is shown as an animated spinner with live elapsed time and
/// token count instead of a static `— running` line; completion/failure lines
/// are printed above the spinner. With no live line (tests, CI, pipes, JSON)
/// the output is exactly the append-only form above.
class CliProgressPrinter {
  final int totalSteps;
  final String workflowName;
  final WriteLine _writeLine;
  final Stopwatch _stopwatch = Stopwatch();
  final LiveStatusLine? _live;

  /// Whether this run is driven by the in-process standalone engine (no server).
  /// Controls the resume/cancel guidance printed at an approval pause.
  final bool standalone;

  CliProgressPrinter({
    required this.totalSteps,
    required this.workflowName,
    required WriteLine writeLine,
    this.standalone = false,
    LiveStatusLine? liveStatusLine,
  }) : _writeLine = writeLine,
       _live = liveStatusLine;

  bool get _liveActive => _live != null && _live.enabled;

  /// Whether permanent lines (and the settle digest) should carry ANSI color —
  /// true only on an interactive TTY with a live line. Drivers thread this into
  /// the digest renderer so its coloring matches the rest of the run output.
  bool get colorEnabled => _live?.colorEnabled ?? false;

  void workflowStarted() {
    _stopwatch.start();
    _emitSpans([
      const StyledSpan('[workflow]', _cTag),
      const StyledSpan(' Starting: '),
      StyledSpan(workflowName, _cId),
      StyledSpan(' ($totalSteps steps)', _cMeta),
    ]);
  }

  void stepRunning(
    int stepIndex,
    String stepId,
    String stepName,
    String? provider, {
    String? displayScope,
    String? progressKey,
  }) {
    final providerSuffix = provider != null ? ' ($provider)' : '';
    final scopedId = _scopedStepId(stepId, displayScope);
    if (_liveActive && progressKey != null) {
      // Compact label: step id + provider only. The verbose task title (e.g.
      // "<workflow> – <Step Name>") is dropped here — it duplicates the id and
      // is the main cause of mid-run truncation; the completed line shows the
      // same id, so the live and settled views stay consistent.
      _live!.addStep(progressKey, '[step ${stepIndex + 1}/$totalSteps] $scopedId$providerSuffix');
      return;
    }
    _emitSpans([
      ..._stepPrefix(stepIndex, stepId, displayScope),
      StyledSpan(' $stepName'),
      const StyledSpan(' – running', _cInfo),
      StyledSpan(providerSuffix, _cMeta),
    ]);
  }

  /// Updates the live token count for the step tracked under [progressKey].
  /// No-op without a live line.
  void stepTokens(String progressKey, int cumulativeTokens) {
    _live?.updateTokens(progressKey, cumulativeTokens);
  }

  /// Retires the live entry for a step whose task settled ahead of its
  /// completion line (a parallel-group member settles before the barrier
  /// fires the step-completed event). Prints nothing – the permanent
  /// completion line still lands when that event arrives. [countTokens] is
  /// true only for a successful settle, folding the member's live-tick tokens
  /// into the run total until the barrier reconciles them.
  void stepSettled(String progressKey, {required bool countTokens}) =>
      _live?.settleStep(progressKey, countTokens: countTokens);

  void stepReview(int stepIndex, String stepId, {String? displayScope}) {
    _emitSpans([..._stepPrefix(stepIndex, stepId, displayScope), const StyledSpan(' review (auto-accepted)', _cInfo)]);
  }

  void stepCompleted(
    int stepIndex,
    String stepId,
    Duration? duration,
    int tokens, {
    String? displayScope,
    String? progressKey,
  }) {
    if (progressKey != null) _live?.completeStep(progressKey, tokens);
    final tokenStr = formatWorkflowTokens(tokens);
    // A null duration means the step was never timed (deterministic engine
    // steps have no task row to clock); omit it rather than print a fabricated
    // `0s` for a gate that may have run for minutes.
    _emitSpans([
      ..._stepPrefix(stepIndex, stepId, displayScope),
      const StyledSpan(' '),
      const StyledSpan('completed', _cDone),
      const StyledSpan(' (', _cMeta),
      if (duration != null) ...[
        StyledSpan(humanizeDuration(duration, dropZeroRemainder: false), _cMeta),
        const StyledSpan(', ', _cMeta),
      ],
      StyledSpan(tokenStr, _cTokens),
      const StyledSpan(')', _cMeta),
    ]);
  }

  void stepFailed(int stepIndex, String stepId, String? error, {String? displayScope, String? progressKey}) {
    if (progressKey != null) _live?.removeStep(progressKey);
    _emitSpans([
      ..._stepPrefix(stepIndex, stepId, displayScope),
      const StyledSpan(' '),
      const StyledSpan('failed', _cFail),
      if (error != null) ...[const StyledSpan(' – ', _cMeta), StyledSpan(scrubAgentReportedText(error), _cReason)],
    ]);
  }

  void stepBlocked(int stepIndex, String stepId, String? reason, {String? displayScope, String? progressKey}) {
    if (progressKey != null) _live?.removeStep(progressKey);
    _emitSpans([
      ..._stepPrefix(stepIndex, stepId, displayScope),
      const StyledSpan(' '),
      const StyledSpan('blocked (recoverable)', _cWarn),
      if (reason != null) ...[const StyledSpan(': ', _cMeta), StyledSpan(scrubAgentReportedText(reason), _cReason)],
    ]);
  }

  /// A cancelled (interrupted) step: resumable, not a failure – styled like
  /// [stepBlocked] so it never reads as a red terminal state.
  void stepInterrupted(int stepIndex, String stepId, String? reason, {String? displayScope, String? progressKey}) {
    if (progressKey != null) _live?.removeStep(progressKey);
    _emitSpans([
      ..._stepPrefix(stepIndex, stepId, displayScope),
      const StyledSpan(' '),
      const StyledSpan('interrupted (resumable)', _cWarn),
      if (reason != null) ...[const StyledSpan(': ', _cMeta), StyledSpan(scrubAgentReportedText(reason), _cReason)],
    ]);
  }

  void workflowCompleted(int completedSteps, int tokens) {
    _live?.stop();
    final elapsed = humanizeDuration(_stopwatch.elapsed, dropZeroRemainder: false);
    final tokenStr = formatWorkflowTokens(tokens);
    _emitSpans([
      const StyledSpan('[workflow]', _cTag),
      const StyledSpan(' '),
      const StyledSpan('Completed:', _cDone),
      StyledSpan(' $completedSteps/$totalSteps steps'),
      const StyledSpan(' (', _cMeta),
      StyledSpan(elapsed, _cMeta),
      const StyledSpan(', ', _cMeta),
      StyledSpan(tokenStr, _cTokens),
      const StyledSpan(')', _cMeta),
    ]);
  }

  void workflowFailed(int completedSteps, String? error) {
    _live?.stop();
    _emitSpans([
      const StyledSpan('[workflow]', _cTag),
      const StyledSpan(' '),
      StyledSpan('Failed at step ${completedSteps + 1}/$totalSteps', _cFail),
      if (error != null) ...[const StyledSpan(': ', _cMeta), StyledSpan(scrubAgentReportedText(error), _cReason)],
    ]);
  }

  void workflowPaused(int completedSteps, String? reason) {
    _live?.stop();
    _emitSpans([
      const StyledSpan('[workflow]', _cTag),
      const StyledSpan(' '),
      StyledSpan('Paused at step ${completedSteps + 1}/$totalSteps', _cWarn),
      if (reason != null) ...[const StyledSpan(': ', _cMeta), StyledSpan(scrubAgentReportedText(reason), _cReason)],
    ]);
  }

  void workflowApprovalPaused(String runId, int completedSteps, String stepId, String message) {
    _live?.stop();
    _emitSpans([
      const StyledSpan('[workflow]', _cTag),
      StyledSpan(' Awaiting approval at step ${completedSteps + 1}/$totalSteps', _cWarn),
      StyledSpan(' ($stepId)', _cMeta),
    ]);
    _emitSpans([
      const StyledSpan('[workflow]', _cTag),
      const StyledSpan(' Approval request: '),
      StyledSpan(scrubAgentReportedText(message)),
    ]);
    // Standalone runs resume the in-process engine with `--standalone` (no
    // server); connected runs reach the already-running server without it.
    final flag = standalone ? ' --standalone' : '';
    _emitSpans([
      const StyledSpan('[workflow]', _cTag),
      StyledSpan(
        ' Use `dartclaw workflow resume $runId$flag` to approve or `dartclaw workflow cancel $runId$flag` to reject.',
      ),
    ]);
  }

  void workflowCancelling() {
    _emitSpans([
      const StyledSpan('[workflow]', _cTag),
      const StyledSpan(' '),
      const StyledSpan('Cancelling...', _cWarn),
    ]);
  }

  /// Stops the live spinner and clears its line, if any. Idempotent. Drivers
  /// call this from their `finally` so a run that exits without a terminal
  /// status line (unexpected pending/running, a mid-drive throw, or a stream
  /// disconnect that settles terminally) still leaves a clean terminal and no
  /// orphaned animation timer.
  void disposeLive() => _live?.stop();

  /// The shared `[step N/M] <id>:` lead-in: a bright counter and the step
  /// identity in the accent color.
  List<StyledSpan> _stepPrefix(int stepIndex, String stepId, String? displayScope) => [
    StyledSpan('[step ${stepIndex + 1}/$totalSteps]', _cStep),
    const StyledSpan(' '),
    StyledSpan('${_scopedStepId(stepId, displayScope)}:', _cId),
  ];

  /// Renders [spans] above the live spinner (with per-segment color when the
  /// live line has color on) or, with no live line, as plain text on the sink
  /// — byte-identical to the spans concatenated, so non-TTY/JSON output is
  /// unchanged.
  void _emitSpans(List<StyledSpan> spans) {
    if (_liveActive) {
      _live!.writePermanent(renderStyledLine(spans, color: _live.colorEnabled));
    } else {
      _writeLine(renderStyledLine(spans, color: false));
    }
  }

  String _scopedStepId(String stepId, String? displayScope) {
    // Display scopes are agent-authored item ids and land in every step line
    // and the live label – scrub them like any other agent-reported text.
    final scrubbed = displayScope == null ? null : scrubAgentReportedText(displayScope);
    return scrubbed == null || scrubbed.isEmpty ? stepId : '$stepId[$scrubbed]';
  }
}

// Permanent-line color theme (per-segment ANSI roles). Applied only when the
// live line has color enabled; plain output is byte-identical without them.
const _cMeta = '\x1b[90m'; // gray — durations, parens (de-emphasized)
const _cStep = '\x1b[97m'; // bright white — the [step N/M] counter
const _cId = '\x1b[36m'; // cyan — step / workflow identity
const _cTokens = '\x1b[36m'; // cyan — token counts
const _cDone = '\x1b[1;32m'; // bold green — completed / success
const _cFail = '\x1b[1;31m'; // bold red — failed
const _cWarn = '\x1b[1;33m'; // bold yellow — blocked / paused / cancelling
const _cInfo = '\x1b[34m'; // blue — review / running
const _cTag = '\x1b[1;35m'; // bold magenta — the [workflow] tag
const _cReason = '\x1b[2m'; // dim — secondary reason text
