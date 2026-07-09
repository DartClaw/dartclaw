import 'package:dartclaw_core/dartclaw_core.dart' show Task, humanizeSpan;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show WorkflowDefinition, WorkflowRun, WorkflowRunStatus, stepStatusFromTask;

import 'agent_text_scrub.dart';
import 'live_status_line.dart';

/// One per-step row in a settle-time [WorkflowRunDigest].
class WorkflowRunDigestRow {
  /// 0-based step index in the definition.
  final int stepIndex;

  /// Step identifier.
  final String stepId;

  /// Resolved step status (`completed`, `failed`, `blocked`, `running`,
  /// `not started`, …) — the single rollup the human and JSON renderers share.
  final String status;

  /// Operator-facing reason the step settled with this status, when recorded.
  final String? reason;

  /// Tokens consumed by the step, when known.
  final int? tokens;

  /// Human-readable duration string, when a task timed the step.
  final String? duration;

  const WorkflowRunDigestRow({
    required this.stepIndex,
    required this.stepId,
    required this.status,
    this.reason,
    this.tokens,
    this.duration,
  });

  Map<String, dynamic> toJson() => {
    'stepIndex': stepIndex,
    'stepId': stepId,
    'status': status,
    if (reason != null) 'reason': reason,
    if (tokens != null) 'tokens': tokens,
    if (duration != null) 'duration': duration,
  };
}

/// Structured per-story rollup printed when a standalone run settles.
///
/// One [WorkflowRunDigest] is rendered for every terminal/hold settle state.
/// The human and `--json` renderers consume the same object so the two stay
/// semantically identical (one builder, two renderers).
class WorkflowRunDigest {
  final String runId;
  final WorkflowRunStatus status;
  final List<WorkflowRunDigestRow> rows;

  /// Concrete next-action commands for this run id and settle state.
  final List<String> nextActions;

  const WorkflowRunDigest({required this.runId, required this.status, required this.rows, required this.nextActions});

  Map<String, dynamic> toJson() => {
    'type': 'workflow_run_digest',
    'runId': runId,
    'status': status.name,
    'steps': rows.map((row) => row.toJson()).toList(),
    'nextActions': nextActions,
  };
}

/// Builds the settle-time digest from a settled [run], its [definition], and the
/// run's child [childTasks]. Per-step status comes from [stepStatusFromTask]
/// (the shared mapper); reason/tokens come from the persisted run context.
WorkflowRunDigest buildWorkflowRunDigest({
  required WorkflowRun run,
  required WorkflowDefinition definition,
  required List<Task> childTasks,
}) {
  final contextData = switch (run.contextJson['data']) {
    final Map<String, dynamic> data => data,
    final Map<Object?, Object?> data => Map<String, dynamic>.from(data),
    _ => const <String, dynamic>{},
  };
  final taskByStepIndex = <int, Task>{};
  for (final task in childTasks) {
    final index = task.stepIndex;
    if (index != null) taskByStepIndex.putIfAbsent(index, () => task);
  }

  final rows = <WorkflowRunDigestRow>[];
  for (var index = 0; index < definition.steps.length; index++) {
    final step = definition.steps[index];
    final task = taskByStepIndex[index];
    var status = stepStatusFromTask(run, index, task, stepId: step.id);
    // Deterministic engine steps (bash gates, aggregate-reviews) settle with a
    // persisted `<step>.status` but no task row and no `step.<id>.outcome`, so
    // the task/outcome layers above leave them "pending". Promote that status
    // before the not-started guard so a settled gate reads as completed/failed.
    if (task == null && status == 'pending') {
      status = switch (contextData['${step.id}.status']) {
        'success' || 'accepted' => 'completed',
        'failed' => 'failed',
        'cancelled' => 'cancelled',
        _ => status,
      };
    }
    if (task == null && index >= run.currentStepIndex && status == 'pending') {
      status = 'not started';
    }
    // The persisted per-step outcome is the authoritative settle classification;
    // it covers steps with no task row (skipped/aggregate) and the blocked state.
    final outcome = contextData['step.${step.id}.outcome'];
    status = switch (outcome) {
      'succeeded' => 'completed',
      'failed' => 'failed',
      'needsInput' || 'blocked' => 'blocked',
      'skipped' => 'skipped',
      // Outcome 'cancelled' is written only for run-teardown interruption –
      // the step is resumable, so it shares the interrupted rollup rather than
      // reading as terminally cancelled.
      'cancelled' => 'interrupted',
      _ => status,
    };
    // A raw 'cancelled' row (task status or promoted `<step>.status`) under a
    // paused RUN is a run-teardown interruption – the step is resumable. Only
    // a terminally cancelled RUN keeps 'cancelled' rows.
    if (status == 'cancelled' && run.status == WorkflowRunStatus.paused) {
      status = 'interrupted';
    }
    // Scrubbed at the builder so both the human and JSON renderers emit clean
    // values – the persisted reason is agent-authored and untrusted.
    final rawReason = contextData['step.${step.id}.outcome.reason'] as String?;
    final reason = rawReason == null ? null : scrubAgentReportedText(rawReason);
    final tokens = (contextData['${step.id}.tokenCount'] as num?)?.toInt();
    final duration = task?.startedAt != null ? humanizeSpan(task!.startedAt!, task.completedAt, false, false) : null;
    rows.add(
      WorkflowRunDigestRow(
        stepIndex: index,
        stepId: step.id,
        status: status,
        reason: reason,
        tokens: tokens,
        duration: duration,
      ),
    );
  }

  return WorkflowRunDigest(
    runId: run.id,
    status: run.status,
    rows: rows,
    nextActions: _nextActions(run.id, run.status),
  );
}

List<String> _nextActions(String runId, WorkflowRunStatus status) => switch (status) {
  WorkflowRunStatus.completed => const [],
  WorkflowRunStatus.paused || WorkflowRunStatus.awaitingApproval => [
    'dartclaw workflow resume $runId --standalone',
    'dartclaw workflow cancel $runId --standalone',
  ],
  WorkflowRunStatus.failed => ['dartclaw workflow retry $runId --standalone'],
  // The service rejects retry for anything but failed, and the frozen
  // definition snapshot makes a fresh run the real path – suggest nothing.
  WorkflowRunStatus.cancelled => const [],
  WorkflowRunStatus.pending || WorkflowRunStatus.running => const [],
};

/// Renders the [digest] as human-readable lines for the live console. When
/// [color] is true each line carries ANSI color (per-status, matching the live
/// run output); when false the lines are plain text, byte-identical to the
/// concatenated spans — the form asserted by tests and emitted to pipes.
List<String> renderWorkflowRunDigestLines(WorkflowRunDigest digest, {bool color = false}) {
  String line(List<StyledSpan> spans) => renderStyledLine(spans, color: color);
  final lines = <String>[
    line([
      const StyledSpan('[digest]', ansiMagenta),
      const StyledSpan(' Run '),
      StyledSpan(digest.runId, ansiCyan),
      const StyledSpan(' – '),
      StyledSpan(digest.status.name, _runStatusColor(digest.status)),
    ]),
  ];
  for (final row in digest.rows) {
    final spans = <StyledSpan>[
      StyledSpan('  ${row.stepIndex + 1}.', ansiBrightWhite),
      const StyledSpan(' '),
      StyledSpan(row.stepId, ansiCyan),
      const StyledSpan(': '),
      StyledSpan(row.status, _stepStatusColor(row.status)),
    ];
    if (row.reason != null) {
      spans.add(const StyledSpan(' – ', ansiDim));
      spans.add(StyledSpan(row.reason!, ansiDim));
    }
    final metrics = <String>[if (row.tokens != null) '${row.tokens} tokens', if (row.duration != null) row.duration!];
    if (metrics.isNotEmpty) spans.add(StyledSpan(' (${metrics.join(', ')})', ansiDim));
    lines.add(line(spans));
  }
  if (digest.nextActions.isNotEmpty) {
    lines.add(line([const StyledSpan('[digest]', ansiMagenta), const StyledSpan(' Next:')]));
    for (final action in digest.nextActions) {
      lines.add(line([StyledSpan('  $action', ansiCyan)]));
    }
  }
  return lines;
}

/// Color for a run-level status word in the digest header.
String _runStatusColor(WorkflowRunStatus status) => switch (status) {
  WorkflowRunStatus.completed => ansiGreen,
  WorkflowRunStatus.failed || WorkflowRunStatus.cancelled => ansiRed,
  WorkflowRunStatus.paused || WorkflowRunStatus.awaitingApproval => ansiYellow,
  WorkflowRunStatus.pending || WorkflowRunStatus.running => ansiCyan,
};

/// Color for a per-step status word in a digest row.
String _stepStatusColor(String status) => switch (status) {
  'completed' => ansiGreen,
  'failed' => ansiRed,
  'blocked' || 'interrupted' => ansiYellow,
  'skipped' || 'not started' => ansiDim,
  _ => ansiCyan,
};
