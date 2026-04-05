import 'dart:async' show Completer, StreamSubscription, TimeoutException;
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        EventBus,
        KvService,
        LoopIterationCompletedEvent,
        ParallelGroupCompletedEvent,
        Task,
        TaskStatus,
        TaskStatusChangedEvent,
        TaskType,
        WorkflowBudgetWarningEvent,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowLoop,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowRunStatusChangedEvent,
        WorkflowStep,
        WorkflowStepCompletedEvent,
        WorkflowTemplateEngine,
        atomicWriteJson;
import 'package:dartclaw_storage/dartclaw_storage.dart' show SqliteWorkflowRunRepository;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../task/task_service.dart';
import 'context_extractor.dart';
import 'gate_evaluator.dart';

/// Result of a single step within a parallel group.
class _ParallelStepResult {
  final WorkflowStep step;
  final Task? task;
  final Map<String, dynamic> outputs;
  final int tokenCount;
  final bool success;
  final String? error;

  const _ParallelStepResult({
    required this.step,
    this.task,
    this.outputs = const {},
    this.tokenCount = 0,
    required this.success,
    this.error,
  });
}

/// Sequential + parallel + iterative workflow execution engine.
///
/// Processes linear steps (sequentially or in parallel groups), then executes
/// loop constructs. Parallel steps use Future.wait(); loops iterate sequentially
/// with exit gate evaluation after each iteration.
class WorkflowExecutor {
  static final _log = Logger('WorkflowExecutor');

  final TaskService _taskService;
  final EventBus _eventBus;
  final KvService _kvService;
  final SqliteWorkflowRunRepository _repository;
  final GateEvaluator _gateEvaluator;
  final ContextExtractor _contextExtractor;
  final WorkflowTemplateEngine _templateEngine;
  final String _dataDir;
  final Uuid _uuid;

  WorkflowExecutor({
    required TaskService taskService,
    required EventBus eventBus,
    required KvService kvService,
    required SqliteWorkflowRunRepository repository,
    required GateEvaluator gateEvaluator,
    required ContextExtractor contextExtractor,
    required String dataDir,
    WorkflowTemplateEngine? templateEngine,
    Uuid? uuid,
  }) : _taskService = taskService,
       _eventBus = eventBus,
       _kvService = kvService,
       _repository = repository,
       _gateEvaluator = gateEvaluator,
       _contextExtractor = contextExtractor,
       _templateEngine = templateEngine ?? WorkflowTemplateEngine(),
       _dataDir = dataDir,
       _uuid = uuid ?? const Uuid();

  /// Executes a workflow run: linear pass then loop pass.
  ///
  /// Called for both fresh starts (startFromStepIndex=0) and crash recovery.
  /// Runs until completion, pause, failure, or cancellation.
  Future<void> execute(
    WorkflowRun run,
    WorkflowDefinition definition,
    WorkflowContext context, {
    int startFromStepIndex = 0,
    int? startFromLoopIndex,
    int? startFromLoopIteration,
    String? startFromLoopStepId,
    bool Function()? isCancelled,
  }) async {
    _log.info(
      "Workflow '${definition.name}' (${run.id}) executing from step $startFromStepIndex",
    );

    // Build set of loop-owned step IDs.
    final loopStepIds = definition.loops.expand((l) => l.steps).toSet();
    final totalSteps = definition.steps.length;

    // ── Linear pass ──────────────────────────────────────────────────────────
    var stepIndex = startFromStepIndex;
    while (stepIndex < definition.steps.length) {
      final step = definition.steps[stepIndex];

      // Check cancellation between steps.
      if (isCancelled?.call() ?? false) {
        _log.info("Workflow '${run.id}' cancelled before step ${step.id}");
        return;
      }

      // Skip loop-owned steps — handled in loop pass below.
      if (loopStepIds.contains(step.id)) {
        _log.fine("Workflow '${run.id}': skipping loop-owned step '${step.id}'");
        stepIndex++;
        continue;
      }

      if (step.parallel) {
        // ── Parallel group ───────────────────────────────────────────────────
        final fullGroup = _collectParallelGroup(definition.steps, stepIndex, loopStepIds);
        final fullGroupStepIds = fullGroup.map((s) => s.id).toList();

        // Check if this is a resume with previously failed steps.
        final failedStepIdsRaw = run.contextJson['_parallel.failed.stepIds'];
        final resumeFailedIds = failedStepIdsRaw is List
            ? Set<String>.from(failedStepIdsRaw.cast<String>())
            : <String>{};
        final isParallelResume = resumeFailedIds.isNotEmpty;
        final group = isParallelResume
            ? fullGroup.where((s) => resumeFailedIds.contains(s.id)).toList()
            : fullGroup;

        if (isParallelResume) {
          _log.info(
            "Workflow '${run.id}': resuming parallel group — "
            're-running ${group.length} failed step(s): '
            '${group.map((s) => s.id).join(', ')}',
          );
        }

        // Check gates for steps before dispatching the group.
        for (final groupStep in group) {
          if (groupStep.gate != null) {
            final gatePasses = _gateEvaluator.evaluate(groupStep.gate!, context);
            if (!gatePasses) {
              final msg = "Gate failed for parallel step '${groupStep.name}': ${groupStep.gate}";
              _log.info("Workflow '${run.id}': $msg");
              await _pauseRun(run, msg);
              return;
            }
          }
        }

        // Check workflow-level budget before the group.
        final refreshedRun = await _repository.getById(run.id) ?? run;
        run = refreshedRun;
        run = await _checkWorkflowBudgetWarning(run, definition);
        if (_workflowBudgetExceeded(run, definition)) {
          final msg =
              'Workflow budget exceeded: ${run.totalTokens} / ${definition.maxTokens} tokens';
          _log.info("Workflow '${run.id}': $msg");
          await _pauseRun(run, msg);
          return;
        }

        // Track parallel group state for resume support.
        run = run.copyWith(
          contextJson: {
            ...run.contextJson,
            '_parallel.current.stepIds': fullGroupStepIds,
          },
          updatedAt: DateTime.now(),
        );
        await _repository.update(run);

        // Execute group concurrently (full group or only failed steps on resume).
        final results = await _executeParallelGroup(run, definition, group, context);

        // Merge results in definition order.
        _mergeParallelResults(results, context);
        run = _updateParallelBudget(run, results);

        // Persist context to disk.
        await _persistContext(run.id, context);

        // Fire per-step completed events.
        for (final result in results) {
          final si = definition.steps.indexOf(result.step);
          _eventBus.fire(
            WorkflowStepCompletedEvent(
              runId: run.id,
              stepId: result.step.id,
              stepName: result.step.name,
              stepIndex: si,
              totalSteps: totalSteps,
              taskId: result.task?.id ?? '',
              success: result.success,
              tokenCount: result.tokenCount,
              timestamp: DateTime.now(),
            ),
          );
        }

        final failedSteps = results.where((r) => !r.success).toList();

        // Fire parallel group completed event.
        _eventBus.fire(
          ParallelGroupCompletedEvent(
            runId: run.id,
            stepIds: group.map((s) => s.id).toList(),
            successCount: results.length - failedSteps.length,
            failureCount: failedSteps.length,
            totalTokens: results.fold(0, (sum, r) => sum + r.tokenCount),
            timestamp: DateTime.now(),
          ),
        );

        if (failedSteps.isNotEmpty) {
          // Record failed step IDs for resume; keep currentStepIndex at group start.
          run = run.copyWith(
            currentStepIndex: stepIndex,
            contextJson: {
              ...run.contextJson,
              '_parallel.current.stepIds': fullGroupStepIds,
              '_parallel.failed.stepIds': failedSteps.map((r) => r.step.id).toList(),
            },
            updatedAt: DateTime.now(),
          );
          await _repository.update(run);

          final failedNames = failedSteps.map((r) => "'${r.step.name}'").join(', ');
          final msg = 'Parallel step(s) failed: $failedNames';
          _log.info("Workflow '${run.id}': $msg");
          await _pauseRun(run, msg);
          return;
        }

        // All steps passed — advance past the full group, clear parallel tracking state.
        run = run.copyWith(
          currentStepIndex: stepIndex + fullGroup.length,
          contextJson: {
            for (final e in run.contextJson.entries)
              if (e.key != '_parallel.current.stepIds' && e.key != '_parallel.failed.stepIds')
                e.key: e.value,
            ...context.toJson(),
          },
          updatedAt: DateTime.now(),
        );
        await _repository.update(run);

        stepIndex += fullGroup.length;
        continue;
      }

      // ── Sequential step ─────────────────────────────────────────────────────
      // Evaluate gate expression if present.
      if (step.gate != null) {
        final gatePasses = _gateEvaluator.evaluate(step.gate!, context);
        if (!gatePasses) {
          final msg = "Gate failed for step '${step.name}': ${step.gate}";
          _log.info("Workflow '${run.id}': $msg");
          await _pauseRun(run, msg);
          return;
        }
      }

      // Check workflow-level budget before starting next step.
      final refreshedRun = await _repository.getById(run.id) ?? run;
      run = refreshedRun;
      run = await _checkWorkflowBudgetWarning(run, definition);
      if (_workflowBudgetExceeded(run, definition)) {
        final msg =
            'Workflow budget exceeded: ${run.totalTokens} / ${definition.maxTokens} tokens';
        _log.info("Workflow '${run.id}': $msg");
        await _pauseRun(run, msg);
        return;
      }

      // Execute the step.
      final result = await _executeStep(run, definition, step, context, stepIndex: stepIndex);
      if (result == null) {
        // Task creation failed — already paused.
        return;
      }

      // Check cancellation after step completes.
      if (isCancelled?.call() ?? false) {
        _log.info("Workflow '${run.id}' cancelled after step ${step.id}");
        return;
      }

      if (!result.success) {
        final reason = result.task?.configJson['failReason'] as String?;
        final msg = "Step '${step.id}' (${step.name}) ${result.task?.status.name ?? 'failed'}"
            "${reason != null ? ': $reason' : ''}";
        _log.info("Workflow '${run.id}': $msg");
        await _pauseRun(run, msg);
        return;
      }

      context.merge(result.outputs);
      context['${step.id}.status'] = result.task!.status.name;
      context['${step.id}.tokenCount'] = result.tokenCount;

      run = run.copyWith(
        totalTokens: run.totalTokens + result.tokenCount,
        currentStepIndex: stepIndex + 1,
        contextJson: {
          // Preserve internal tracking keys (prefixed with '_').
          for (final e in run.contextJson.entries)
            if (e.key.startsWith('_')) e.key: e.value,
          ...context.toJson(),
        },
        updatedAt: DateTime.now(),
      );

      await _persistContext(run.id, context);
      await _repository.update(run);

      _eventBus.fire(
        WorkflowStepCompletedEvent(
          runId: run.id,
          stepId: step.id,
          stepName: step.name,
          stepIndex: stepIndex,
          totalSteps: totalSteps,
          taskId: result.task!.id,
          success: true,
          tokenCount: result.tokenCount,
          timestamp: DateTime.now(),
        ),
      );

      stepIndex++;
    }

    // ── Loop pass ─────────────────────────────────────────────────────────────
    final loopStartIndex = startFromLoopIndex ?? 0;
    for (var loopIdx = loopStartIndex; loopIdx < definition.loops.length; loopIdx++) {
      final loop = definition.loops[loopIdx];

      if (isCancelled?.call() ?? false) {
        _log.info("Workflow '${run.id}' cancelled before loop '${loop.id}'");
        return;
      }

      final iterStart = (loopIdx == loopStartIndex && startFromLoopIteration != null)
          ? startFromLoopIteration
          : 1;

      // Only pass the resume step ID for the first loop being resumed.
      final loopStepId = (loopIdx == loopStartIndex) ? startFromLoopStepId : null;

      final pauseOrCancel = await _executeLoop(
        run,
        definition,
        loop,
        context,
        isCancelled: isCancelled,
        startFromIteration: iterStart,
        startFromStepId: loopStepId,
        onRunUpdated: (updated) => run = updated,
      );

      if (pauseOrCancel) return; // Executor already paused or cancelled.
    }

    // All steps and loops completed.
    await _completeRun(run);
  }

  // ── Parallel group helpers ──────────────────────────────────────────────────

  /// Collects contiguous parallel steps starting at [startIndex], skipping
  /// loop-owned steps. Stops at the first non-parallel, non-loop-owned step.
  List<WorkflowStep> _collectParallelGroup(
    List<WorkflowStep> steps,
    int startIndex,
    Set<String> loopStepIds,
  ) {
    final group = <WorkflowStep>[];
    for (var i = startIndex; i < steps.length; i++) {
      final step = steps[i];
      if (loopStepIds.contains(step.id)) continue;
      if (!step.parallel) break;
      group.add(step);
    }
    return group;
  }

  /// Executes all steps in a parallel group concurrently via [Future.wait].
  ///
  /// Each step gets its own Task. Individual failures are caught — other steps
  /// continue to completion.
  Future<List<_ParallelStepResult>> _executeParallelGroup(
    WorkflowRun run,
    WorkflowDefinition definition,
    List<WorkflowStep> group,
    WorkflowContext context,
  ) async {
    final futures = group.map((step) async {
      // Warn if step has parallel:true inside a loop (shouldn't happen via this
      // path, but guard for clarity).
      final prompt = _templateEngine.resolve(step.prompt, context);
      final taskConfig = _buildStepConfig(step);
      final taskId = _uuid.v4();

      // Subscribe before create to avoid race condition.
      final completer = Completer<Task>();
      final sub = _eventBus
          .on<TaskStatusChangedEvent>()
          .where((e) => e.taskId == taskId)
          .listen((event) async {
            if (event.newStatus.terminal) {
              if (!completer.isCompleted) {
                final t = await _taskService.get(taskId);
                if (t != null) completer.complete(t);
              }
            }
          });

      try {
        await _taskService.create(
          id: taskId,
          title: '${definition.name} — ${step.name}',
          description: prompt,
          type: _mapStepType(step.type),
          autoStart: true,
          provider: step.provider,
          maxTokens: step.maxTokens,
          workflowRunId: run.id,
          stepIndex: definition.steps.indexOf(step),
          configJson: taskConfig,
          trigger: 'workflow',
        );

        final Task finalTask;
        try {
          if (step.timeoutSeconds != null) {
            finalTask = await completer.future.timeout(
              Duration(seconds: step.timeoutSeconds!),
              onTimeout: () => throw TimeoutException(
                'Step "${step.name}" timed out',
                Duration(seconds: step.timeoutSeconds!),
              ),
            );
          } else {
            finalTask = await completer.future;
          }
        } on TimeoutException catch (e) {
          _log.warning("Parallel step '${step.name}' timed out: $e");
          return _ParallelStepResult(
            step: step,
            outputs: {},
            tokenCount: 0,
            success: false,
            error: 'timed out after ${step.timeoutSeconds}s',
          );
        } finally {
          await sub.cancel();
        }

        final success =
            finalTask.status != TaskStatus.failed && finalTask.status != TaskStatus.cancelled;

        Map<String, dynamic> outputs = {};
        int tokenCount = 0;
        if (success) {
          try {
            outputs = await _contextExtractor.extract(step, finalTask);
          } catch (e) {
            _log.warning("Context extraction failed for parallel step '${step.id}': $e");
          }
          tokenCount = await _readStepTokenCount(finalTask);
        }

        return _ParallelStepResult(
          step: step,
          task: finalTask,
          outputs: outputs,
          tokenCount: tokenCount,
          success: success,
        );
      } catch (e, st) {
        await sub.cancel();
        _log.severe("Parallel step '${step.name}' failed: $e", e, st);
        return _ParallelStepResult(
          step: step,
          outputs: {},
          tokenCount: 0,
          success: false,
          error: e.toString(),
        );
      }
    }).toList();

    return Future.wait(futures);
  }

  /// Merges parallel group results into [context] in definition order.
  ///
  /// Sets automatic metadata keys for all steps regardless of success.
  /// Successful steps' outputs are merged; failed steps are skipped.
  void _mergeParallelResults(List<_ParallelStepResult> results, WorkflowContext context) {
    for (final result in results) {
      if (result.success) {
        context.merge(result.outputs);
      }
      context['${result.step.id}.status'] =
          result.success ? (result.task?.status.name ?? 'unknown') : 'failed';
      context['${result.step.id}.tokenCount'] = result.tokenCount;
    }
  }

  /// Accumulates token counts from all parallel results into [run.totalTokens].
  WorkflowRun _updateParallelBudget(WorkflowRun run, List<_ParallelStepResult> results) {
    final total = results.fold(0, (sum, r) => sum + r.tokenCount);
    return run.copyWith(
      totalTokens: run.totalTokens + total,
      updatedAt: DateTime.now(),
    );
  }

  // ── Loop execution ──────────────────────────────────────────────────────────

  /// Executes a single loop definition.
  ///
  /// Returns true if the workflow was paused or cancelled (caller should return).
  /// Returns false if the loop completed successfully.
  Future<bool> _executeLoop(
    WorkflowRun run,
    WorkflowDefinition definition,
    WorkflowLoop loop,
    WorkflowContext context, {
    bool Function()? isCancelled,
    int startFromIteration = 1,
    String? startFromStepId,
    required void Function(WorkflowRun) onRunUpdated,
  }) async {
    var gatePassed = false;
    // Track resume step — only applies to the first iteration when resuming.
    var resumeStepId = startFromStepId;

    for (var iteration = startFromIteration; iteration <= loop.maxIterations; iteration++) {
      if (isCancelled?.call() ?? false) {
        _log.info("Workflow '${run.id}' cancelled during loop '${loop.id}'");
        return true;
      }

      // Set iteration counter in context.
      context.setLoopIteration(loop.id, iteration);

      // Persist loop tracking state before the iteration.
      run = run.copyWith(
        contextJson: {
          ...run.contextJson,
          '_loop.current.id': loop.id,
          '_loop.current.iteration': iteration,
          // Clear step tracking at iteration start.
          if (resumeStepId == null) '_loop.current.stepId': null,
        },
        updatedAt: DateTime.now(),
      );
      await _repository.update(run);
      onRunUpdated(run);

      // Execute each loop step sequentially.
      for (final stepId in loop.steps) {
        // Skip completed steps when resuming from a specific failed step.
        if (resumeStepId != null && stepId != resumeStepId) {
          _log.fine(
            "Workflow '${run.id}': skipping completed loop step '$stepId' "
            "(resuming from '$resumeStepId')",
          );
          continue;
        }
        // Clear resume marker once we've reached the target step.
        resumeStepId = null;

        if (isCancelled?.call() ?? false) {
          _log.info(
            "Workflow '${run.id}' cancelled in loop '${loop.id}' iter $iteration",
          );
          return true;
        }

        final step = definition.steps.firstWhere((s) => s.id == stepId);

        if (step.parallel) {
          _log.warning(
            "Step '${step.id}' has parallel:true but is inside loop '${loop.id}' — "
            'executing sequentially (parallel flag ignored in loops)',
          );
        }

        // Gate check on individual loop step.
        if (step.gate != null) {
          final gatePasses = _gateEvaluator.evaluate(step.gate!, context);
          if (!gatePasses) {
            final msg =
                "Gate failed in loop '${loop.id}' iteration $iteration: ${step.gate}";
            _log.info("Workflow '${run.id}': $msg");
            await _pauseRun(run, msg);
            return true;
          }
        }

        // Workflow budget check.
        final refreshedRun = await _repository.getById(run.id) ?? run;
        run = refreshedRun;
        onRunUpdated(run);
        run = await _checkWorkflowBudgetWarning(run, definition);
        onRunUpdated(run);
        if (_workflowBudgetExceeded(run, definition)) {
          final msg = "Workflow budget exceeded during loop '${loop.id}'";
          _log.info("Workflow '${run.id}': $msg");
          await _pauseRun(run, msg);
          return true;
        }

        // Persist current step ID for resume support.
        run = run.copyWith(
          contextJson: {
            ...run.contextJson,
            '_loop.current.id': loop.id,
            '_loop.current.iteration': iteration,
            '_loop.current.stepId': stepId,
          },
          updatedAt: DateTime.now(),
        );
        await _repository.update(run);
        onRunUpdated(run);

        // Find step index in definition for task metadata.
        final stepIndex = definition.steps.indexOf(step);

        final result = await _executeStep(
          run,
          definition,
          step,
          context,
          stepIndex: stepIndex,
          loopId: loop.id,
          loopIteration: iteration,
        );
        if (result == null) return true; // Task creation failed — already paused.

        if (isCancelled?.call() ?? false) return true;

        if (!result.success) {
          final msg =
              "Loop '${loop.id}' step '${step.name}' failed in iteration $iteration";
          _log.info("Workflow '${run.id}': $msg");
          await _pauseRun(run, msg);
          return true;
        }

        context.merge(result.outputs);
        context['${step.id}.status'] = result.task!.status.name;
        context['${step.id}.tokenCount'] = result.tokenCount;

        run = run.copyWith(
          totalTokens: run.totalTokens + result.tokenCount,
          updatedAt: DateTime.now(),
        );
        onRunUpdated(run);

        _eventBus.fire(
          WorkflowStepCompletedEvent(
            runId: run.id,
            stepId: step.id,
            stepName: step.name,
            stepIndex: stepIndex,
            totalSteps: definition.steps.length,
            taskId: result.task!.id,
            success: true,
            tokenCount: result.tokenCount,
            timestamp: DateTime.now(),
          ),
        );
      }

      // Evaluate exit gate after all steps in this iteration.
      if (_gateEvaluator.evaluate(loop.exitGate, context)) {
        gatePassed = true;
        _log.info(
          "Loop '${loop.id}' completed: exit gate passed at iteration $iteration",
        );
        _eventBus.fire(
          LoopIterationCompletedEvent(
            runId: run.id,
            loopId: loop.id,
            iteration: iteration,
            maxIterations: loop.maxIterations,
            gateResult: true,
            timestamp: DateTime.now(),
          ),
        );
        break;
      }

      // Gate failed — fire event and continue to next iteration.
      _eventBus.fire(
        LoopIterationCompletedEvent(
          runId: run.id,
          loopId: loop.id,
          iteration: iteration,
          maxIterations: loop.maxIterations,
          gateResult: false,
          timestamp: DateTime.now(),
        ),
      );

      // Persist context after each iteration.
      await _persistContext(run.id, context);
      run = run.copyWith(
        contextJson: context.toJson(),
        updatedAt: DateTime.now(),
      );
      await _repository.update(run);
      onRunUpdated(run);
    }

    if (!gatePassed) {
      // Clear loop tracking before pausing.
      run = run.copyWith(
        contextJson: {
          for (final e in run.contextJson.entries)
            if (e.key != '_loop.current.id' && e.key != '_loop.current.iteration') e.key: e.value,
        },
        updatedAt: DateTime.now(),
      );
      await _repository.update(run);
      onRunUpdated(run);

      final msg = "Loop '${loop.id}' reached max iterations (${loop.maxIterations}). "
          'Exit condition not met: ${loop.exitGate}';
      _log.info("Workflow '${run.id}': $msg");
      await _pauseRun(run, msg);
      return true;
    }

    // Clear loop tracking state on success.
    run = run.copyWith(
      contextJson: {
        for (final e in run.contextJson.entries)
          if (e.key != '_loop.current.id' && e.key != '_loop.current.iteration') e.key: e.value,
        ...context.toJson(),
      },
      updatedAt: DateTime.now(),
    );
    await _repository.update(run);
    onRunUpdated(run);

    return false;
  }

  // ── Single step execution ───────────────────────────────────────────────────

  /// Executes a single step: resolves template, creates task, waits for terminal state.
  ///
  /// Returns null if task creation fails (workflow already paused by this method).
  /// Returns a [_ParallelStepResult] (success or failure) on completion.
  Future<_ParallelStepResult?> _executeStep(
    WorkflowRun run,
    WorkflowDefinition definition,
    WorkflowStep step,
    WorkflowContext context, {
    required int stepIndex,
    String? loopId,
    int? loopIteration,
  }) async {
    final prompt = _templateEngine.resolve(step.prompt, context);
    final taskConfig = _buildStepConfig(step);
    final taskId = _uuid.v4();

    // Subscribe before create to avoid race condition.
    final completer = Completer<Task>();
    final sub = _eventBus
        .on<TaskStatusChangedEvent>()
        .where((e) => e.taskId == taskId)
        .listen((event) async {
          if (event.newStatus == TaskStatus.failed) {
            // Check whether this is a retry-in-progress or permanent failure.
            final t = await _taskService.get(taskId);
            if (t == null) return; // task vanished — ignore, will timeout or get another event
            // If task already re-queued (retry happened fast), continue waiting.
            if (t.status == TaskStatus.queued || t.status == TaskStatus.running) return;
            // Retries remain — retry is imminent, continue waiting.
            if (t.retryCount < t.maxRetries) return;
            // All retries exhausted (or no retries configured) — permanent failure.
            if (!completer.isCompleted) completer.complete(t);
          } else if (event.newStatus.terminal) {
            if (!completer.isCompleted) {
              final t = await _taskService.get(taskId);
              if (t != null) completer.complete(t);
            }
          } else if (event.newStatus == TaskStatus.review) {
            // TaskExecutor handles auto-accept via configJson['reviewMode'].
          }
        });

    final title = loopId != null
        ? '${definition.name} — ${step.name} ($loopId iter $loopIteration)'
        : '${definition.name} — ${step.name}';

    try {
      await _taskService.create(
        id: taskId,
        title: title,
        description: prompt,
        type: _mapStepType(step.type),
        autoStart: true,
        provider: step.provider,
        maxTokens: step.maxTokens,
        maxRetries: step.maxRetries ?? 0,
        workflowRunId: run.id,
        stepIndex: stepIndex,
        configJson: taskConfig,
        trigger: 'workflow',
      );
    } catch (e, st) {
      await sub.cancel();
      final msg = "Failed to create task for step '${step.name}': $e";
      _log.severe("Workflow '${run.id}': $msg", e, st);
      await _pauseRun(run, msg);
      return null;
    }

    _log.fine("Workflow '${run.id}': step '${step.id}' → task $taskId");

    late Task finalTask;
    try {
      finalTask = await _waitForTaskCompletion(taskId, step, completer, sub);
    } on TimeoutException {
      final msg = 'Step "${step.name}" timed out after ${step.timeoutSeconds}s';
      _log.warning("Workflow '${run.id}': $msg");
      await _pauseRun(run, msg);
      return null;
    } catch (e, st) {
      final msg = "Step '${step.name}' wait failed: $e";
      _log.severe("Workflow '${run.id}': $msg", e, st);
      await _pauseRun(run, msg);
      return null;
    }

    final success =
        finalTask.status != TaskStatus.failed && finalTask.status != TaskStatus.cancelled;

    Map<String, dynamic> outputs = {};
    int tokenCount = 0;
    if (success) {
      try {
        outputs = await _contextExtractor.extract(step, finalTask);
      } catch (e, st) {
        _log.warning(
          "Context extraction failed for step '${step.id}'",
          e,
          st,
        );
      }
      tokenCount = await _readStepTokenCount(finalTask);
    }

    return _ParallelStepResult(
      step: step,
      task: finalTask,
      outputs: outputs,
      tokenCount: tokenCount,
      success: success,
    );
  }

  // ── Shared helpers ──────────────────────────────────────────────────────────

  /// Waits for a task to complete using a pre-created [completer] and [sub].
  Future<Task> _waitForTaskCompletion(
    String taskId,
    WorkflowStep step,
    Completer<Task> completer,
    StreamSubscription<TaskStatusChangedEvent> sub,
  ) async {
    try {
      if (step.timeoutSeconds != null) {
        return await completer.future.timeout(
          Duration(seconds: step.timeoutSeconds!),
          onTimeout: () => throw TimeoutException(
            'Step "${step.name}" timed out',
            Duration(seconds: step.timeoutSeconds!),
          ),
        );
      } else {
        return await completer.future;
      }
    } finally {
      await sub.cancel();
    }
  }

  /// Builds configJson for a task from a workflow step.
  Map<String, dynamic> _buildStepConfig(WorkflowStep step) {
    final config = <String, dynamic>{};
    if (step.model != null) config['model'] = step.model;
    if (step.maxTokens != null) config['tokenBudget'] = step.maxTokens;
    if (step.allowedTools != null) config['allowedTools'] = step.allowedTools;
    config['reviewMode'] = switch (step.review.name) {
      'never' => 'auto-accept',
      'always' => 'mandatory',
      'codingOnly' => 'coding-only',
      _ => 'coding-only',
    };
    return config;
  }

  /// Maps a workflow step type string to [TaskType].
  TaskType _mapStepType(String type) => switch (type) {
    'research' => TaskType.research,
    'analysis' => TaskType.analysis,
    'writing' => TaskType.writing,
    'coding' => TaskType.coding,
    'automation' => TaskType.automation,
    _ => TaskType.custom,
  };

  /// Returns true if the workflow-level budget has been exceeded.
  bool _workflowBudgetExceeded(WorkflowRun run, WorkflowDefinition definition) {
    if (definition.maxTokens == null) return false;
    return run.totalTokens >= definition.maxTokens!;
  }

  /// Fires a warning event when the workflow reaches 80% of its token budget.
  ///
  /// Deduplicated via `_budget.warningFired` in [run.contextJson] — fires once per run.
  /// Returns updated [run] if the flag was set, otherwise returns [run] unchanged.
  Future<WorkflowRun> _checkWorkflowBudgetWarning(
    WorkflowRun run,
    WorkflowDefinition definition,
  ) async {
    if (definition.maxTokens == null) return run;
    if (run.contextJson['_budget.warningFired'] == true) return run;
    final threshold = (definition.maxTokens! * 0.8).toInt();
    if (run.totalTokens < threshold) return run;

    _eventBus.fire(
      WorkflowBudgetWarningEvent(
        runId: run.id,
        definitionName: run.definitionName,
        consumedPercent: run.totalTokens / definition.maxTokens!,
        consumed: run.totalTokens,
        limit: definition.maxTokens!,
        timestamp: DateTime.now(),
      ),
    );
    _log.info(
      "Workflow '${run.id}': budget warning — "
      '${run.totalTokens}/${definition.maxTokens} tokens '
      '(${(run.totalTokens / definition.maxTokens! * 100).toStringAsFixed(0)}%)',
    );

    // Persist dedupe flag.
    run = run.copyWith(
      contextJson: {...run.contextJson, '_budget.warningFired': true},
      updatedAt: DateTime.now(),
    );
    await _repository.update(run);
    return run;
  }

  /// Reads the step's cumulative token count from session KV or task metadata.
  Future<int> _readStepTokenCount(Task task) async {
    if (task.sessionId == null) return 0;
    try {
      final raw = await _kvService.get('session_cost:${task.sessionId}');
      if (raw == null) return 0;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return (json['total_tokens'] as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Persists [context] to `<dataDir>/workflows/<runId>/context.json` atomically.
  Future<void> _persistContext(String runId, WorkflowContext context) async {
    final dir = Directory(p.join(_dataDir, 'workflows', runId));
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, 'context.json'));
    await atomicWriteJson(file, context.toJson());
  }

  /// Transitions the workflow run to paused and fires status changed event.
  Future<void> _pauseRun(WorkflowRun run, String reason) async {
    final paused = run.copyWith(
      status: WorkflowRunStatus.paused,
      errorMessage: reason,
      updatedAt: DateTime.now(),
    );
    await _repository.update(paused);
    _eventBus.fire(
      WorkflowRunStatusChangedEvent(
        runId: run.id,
        definitionName: run.definitionName,
        oldStatus: run.status,
        newStatus: WorkflowRunStatus.paused,
        errorMessage: reason,
        timestamp: DateTime.now(),
      ),
    );
  }

  /// Transitions the workflow run to completed and fires status changed event.
  Future<void> _completeRun(WorkflowRun run) async {
    final completed = run.copyWith(
      status: WorkflowRunStatus.completed,
      completedAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    await _repository.update(completed);
    _eventBus.fire(
      WorkflowRunStatusChangedEvent(
        runId: run.id,
        definitionName: run.definitionName,
        oldStatus: run.status,
        newStatus: WorkflowRunStatus.completed,
        timestamp: DateTime.now(),
      ),
    );
    _log.info("Workflow '${run.definitionName}' (${run.id}) completed successfully");
  }
}
