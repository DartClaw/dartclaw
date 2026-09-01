import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart'
    show MapIterationCompletedEvent, TaskStatus, WorkflowStepCompletedEvent;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowDefinition, WorkflowTaskType;

import 'cli_progress_printer.dart';
import 'workflow_event_printer_dispatch.dart';

/// A task transition in the renderer's lane-neutral progress vocabulary.
///
/// [stepIndex] and [displayScope] are the server-enriched fields the connected
/// lane's SSE frames carry; the standalone lane leaves them null because it
/// resolves the step context from the task row instead. [taskId] is nullable
/// because the wire does not guarantee it.
class TaskProgressUpdate {
  const new({required this.taskId, required this.newStatus, this.oldStatus, this.stepIndex, this.displayScope});

  final String? taskId;
  final TaskStatus newStatus;
  final TaskStatus? oldStatus;
  final int? stepIndex;
  final String? displayScope;
}

/// The step identity a running/review transition renders under, resolved by
/// the lane: from the task row on the standalone lane, from the frame's
/// `stepIndex` plus the definition's step on the connected one.
class TaskStepContext {
  const new({
    required this.stepIndex,
    required this.stepId,
    required this.title,
    required this.provider,
    required this.displayScope,
  });

  final int stepIndex;
  final String stepId;
  final String title;
  final String? provider;
  final String? displayScope;
}

/// Resolves a transition's step identity, or null when the transition is not
/// renderable (foreign run, no step index, index past the definition's steps).
typedef TaskStepContextResolver = FutureOr<TaskStepContext?> Function(TaskProgressUpdate update);

/// Lane-owned `--json` frame builders.
///
/// Supplied only by the standalone lane, whose `--json` payloads are
/// renderer-authored (`durationMs`, `definitionName`, conditional
/// `displayScope`/`outcome`/`reason`). The connected lane echoes the server's
/// frames in its transport and supplies no sink, so the renderer emits no JSON
/// there.
class WorkflowProgressJsonSink {
  const new({required this.taskTransition, required this.stepCompleted, required this.mapIterationCompleted});

  final void Function(TaskProgressUpdate update, TaskStepContext context) taskTransition;
  final void Function(WorkflowStepCompletedEvent event, Duration duration) stepCompleted;
  final void Function(MapIterationCompletedEvent event, int stepIndex, Duration duration) mapIterationCompleted;
}

/// The one event → step-progress renderer, driven by both workflow run lanes.
///
/// Owns the progress bookkeeping the lanes share: step start times, the
/// in-flight settle guard, live-entry retirement at task settle, token ticks
/// and the printer dispatch. Transport, `--json` framing, settle rendering,
/// exit-code mapping and interrupt handling stay lane-owned — the standalone
/// lane feeds this from its in-process [EventBus], the connected lane from its
/// SSE decoder.
class WorkflowProgressRenderer {
  new({
    required WorkflowDefinition definition,
    required CliProgressPrinter printer,
    required bool jsonOutput,
    required TaskStepContextResolver resolveStepContext,
    WorkflowProgressJsonSink? jsonSink,
  }) : _definition = definition,
       _printer = printer,
       _jsonOutput = jsonOutput,
       _resolveStepContext = resolveStepContext,
       _jsonSink = jsonSink;

  final WorkflowDefinition _definition;
  final CliProgressPrinter _printer;
  final bool _jsonOutput;
  final TaskStepContextResolver _resolveStepContext;
  final WorkflowProgressJsonSink? _jsonSink;

  final _stepStartTimes = <String, DateTime>{};

  // Task ids that settled while the step-context resolution below was still in
  // flight – their deferred stepRunning must not resurrect a live entry. Only
  // load-bearing for a lane whose resolver is asynchronous.
  final _settledTaskIds = <String>{};

  /// Renders a task transition: retirement at settle, or the running/review
  /// line once the lane resolves the transition's step identity.
  Future<void> taskStatusChanged(TaskProgressUpdate update) async {
    final taskId = update.taskId;
    if (taskSettlesLiveEntry(update.newStatus)) {
      // Parallel-group members settle long before the group barrier fires
      // WorkflowStepCompletedEvent – retire the live entry now so the live
      // line counts actually-running tasks. Keys are task-scoped, so a
      // foreign run's task id can never match an entry; no run scoping needed.
      if (taskId != null) _settledTaskIds.add(taskId);
      if (!_jsonOutput) {
        final key = taskProgressKey(taskId);
        if (key != null) _printer.stepSettled(key, countTokens: update.newStatus == TaskStatus.accepted);
      }
      return;
    }
    if (update.newStatus != TaskStatus.running && update.newStatus != TaskStatus.review) return;
    // A fresh running supersedes an earlier settle (failed/interrupted tasks
    // re-queue on retry under the same id).
    if (update.newStatus == TaskStatus.running && taskId != null) _settledTaskIds.remove(taskId);

    final context = await _resolveStepContext(update);
    if (context == null) return;
    final runningKey = progressStartKey(
      stepIndex: context.stepIndex,
      taskId: taskId,
      displayScope: context.displayScope,
    );
    if (update.newStatus == TaskStatus.running) {
      _stepStartTimes[runningKey] = DateTime.now();
    }
    if (_jsonOutput) {
      _jsonSink?.taskTransition(update, context);
      return;
    }
    if (update.newStatus == TaskStatus.running) {
      // Settled while the resolution was in flight – the live entry is gone
      // and must stay gone.
      if (taskId != null && _settledTaskIds.contains(taskId)) return;
      _printer.stepRunning(
        context.stepIndex,
        context.stepId,
        context.title,
        context.provider,
        displayScope: context.displayScope,
        progressKey: runningKey,
      );
    } else {
      _printer.stepReview(context.stepIndex, context.stepId, displayScope: context.displayScope);
    }
  }

  /// Renders a step barrier. [displayScope] is lane-resolved: the standalone
  /// lane reads the event's typed scope, the connected lane the frame's
  /// `displayScope ?? itemId`.
  void stepCompleted(WorkflowStepCompletedEvent event, {required String? displayScope}) {
    final key = progressStartKey(stepIndex: event.stepIndex, taskId: event.taskId, displayScope: displayScope);
    final duration = _takeDuration(key);
    if (_jsonOutput) {
      _jsonSink?.stepCompleted(event, duration ?? Duration.zero);
      return;
    }
    dispatchWorkflowStepCompletedToPrinter(printer: _printer, event: event, duration: duration, progressKey: key);
  }

  /// Renders a map iteration barrier, skipping iterations of a `foreach` step
  /// that carry a task id (those settle through their inner steps instead).
  void mapIterationCompleted(MapIterationCompletedEvent event, {required String? displayScope}) {
    final stepIndex = _definition.steps.indexWhere((step) => step.id == event.stepId);
    if (stepIndex < 0) return;
    if (_definition.steps[stepIndex].taskType == WorkflowTaskType.foreach && event.taskId.trim().isNotEmpty) return;
    final key = progressStartKey(stepIndex: stepIndex, taskId: event.taskId, displayScope: displayScope);
    final duration = _takeDuration(key);
    if (_jsonOutput) {
      _jsonSink?.mapIterationCompleted(event, stepIndex, duration ?? Duration.zero);
      return;
    }
    dispatchMapIterationCompletedToPrinter(
      printer: _printer,
      event: event,
      stepIndex: stepIndex,
      duration: duration,
      progressKey: key,
      displayScope: displayScope,
    );
  }

  /// Feeds a live per-turn token tick to the step running under [taskId].
  /// `stepTokens` is a no-op unless that task is a currently-running step of
  /// this run, so it needs no run-id scoping.
  void turnProgress({required String? taskId, required int? cumulativeTokens}) {
    if (_jsonOutput || cumulativeTokens == null) return;
    final key = taskProgressKey(taskId);
    if (key != null) _printer.stepTokens(key, cumulativeTokens);
  }

  /// A null duration means the step was never seen running, so the caller
  /// omits the timing rather than printing a fabricated `0s`.
  Duration? _takeDuration(String progressKey) {
    final startTime = _stepStartTimes.remove(progressKey);
    return startTime == null ? null : DateTime.now().difference(startTime);
  }
}

/// Stable key for matching a step's start time to its completion event,
/// keyed by task id when present, else step index plus optional display scope.
String progressStartKey({required int stepIndex, String? taskId, String? displayScope}) {
  final normalizedTaskId = taskId?.trim();
  if (normalizedTaskId != null && normalizedTaskId.isNotEmpty) {
    return 'task:$normalizedTaskId';
  }
  final normalizedScope = displayScope?.trim();
  if (normalizedScope != null && normalizedScope.isNotEmpty) {
    return 'step:$stepIndex:$normalizedScope';
  }
  return 'step:$stepIndex';
}

/// Key for matching a task-scoped event (live token tick, terminal settle) to
/// its running step. Such events carry only a taskId, which always dominates
/// [progressStartKey]'s step-index path – so this returns that `task:<id>` key
/// directly and yields null for a blank taskId, rather than letting it
/// collapse to `step:0` and mis-attribute the event to whichever step holds
/// that key.
String? taskProgressKey(String? taskId) {
  final normalized = taskId?.trim();
  if (normalized == null || normalized.isEmpty) return null;
  return progressStartKey(stepIndex: 0, taskId: normalized);
}

/// Whether [status] means the task is no longer executing, so its live-line
/// entry must be retired immediately. Terminal states plus `interrupted`
/// (execution stopped, resumable) qualify; `review` does not – workflow tasks
/// auto-accept, so review resolves within the same settle.
bool taskSettlesLiveEntry(TaskStatus status) => status.terminal || status == TaskStatus.interrupted;
