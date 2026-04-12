import 'dart:async' show Completer, StreamSubscription, TimeoutException, Timer;
import 'dart:collection' show Queue;
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        EventBus,
        KvService,
        LoopIterationCompletedEvent,
        MapIterationCompletedEvent,
        MapStepCompletedEvent,
        MessageService,
        OutputConfig,
        OutputFormat,
        ParallelGroupCompletedEvent,
        Task,
        TaskStatus,
        TaskStatusChangedEvent,
        TaskType,
        WorkflowApprovalRequestedEvent,
        WorkflowBudgetWarningEvent,
        WorkflowDefinition,
        WorkflowLoop,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowRunStatusChangedEvent,
        WorkflowStep,
        WorkflowStepCompletedEvent,
        WorkflowTaskService,
        atomicWriteJson;
import 'package:dartclaw_storage/dartclaw_storage.dart' show SqliteWorkflowRunRepository;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'context_extractor.dart';
import 'dependency_graph.dart';
import 'gate_evaluator.dart';
import 'json_extraction.dart';
import 'map_context.dart';
import 'map_step_context.dart';
import 'prompt_augmenter.dart';
import 'shell_escape.dart';
import 'skill_prompt_builder.dart';
import 'step_config_resolver.dart';
import 'built_in_workflow_workspace.dart';
import 'workflow_context.dart';
import 'workflow_template_engine.dart';
import 'workflow_turn_adapter.dart';

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

/// Result of a map/fan-out step execution.
class _MapStepResult {
  /// Index-ordered result array (one slot per collection item).
  final List<dynamic> results;

  /// Total tokens consumed across all iterations.
  final int totalTokens;

  /// Whether all iterations succeeded.
  final bool success;

  /// Error message if any iteration failed or the step itself failed.
  final String? error;

  const _MapStepResult({required this.results, required this.totalTokens, required this.success, this.error});
}

/// Sequential + parallel + iterative workflow execution engine.
///
/// Processes linear steps (sequentially or in parallel groups), then executes
/// loop constructs. Parallel steps use Future.wait(); loops iterate sequentially
/// with exit gate evaluation after each iteration.
class WorkflowExecutor {
  static final _log = Logger('WorkflowExecutor');

  final WorkflowTaskService _taskService;
  final EventBus _eventBus;
  final KvService _kvService;
  final SqliteWorkflowRunRepository _repository;
  final GateEvaluator _gateEvaluator;
  final ContextExtractor _contextExtractor;
  final WorkflowTemplateEngine _templateEngine;
  final SkillPromptBuilder _skillPromptBuilder;
  final MessageService? _messageService;
  final WorkflowTurnAdapter? _turnAdapter;
  final String _dataDir;
  final Uuid _uuid;
  String? _workflowWorkspaceDirCache;

  // Approval timeout timers keyed by "<runId>:<stepId>".
  final _approvalTimers = <String, Timer>{};

  WorkflowExecutor({
    required WorkflowTaskService taskService,
    required EventBus eventBus,
    required KvService kvService,
    required SqliteWorkflowRunRepository repository,
    required GateEvaluator gateEvaluator,
    required ContextExtractor contextExtractor,
    required String dataDir,
    WorkflowTemplateEngine? templateEngine,
    PromptAugmenter? promptAugmenter,
    SkillPromptBuilder? skillPromptBuilder,
    MessageService? messageService,
    WorkflowTurnAdapter? turnAdapter,
    Uuid? uuid,
  }) : _taskService = taskService,
       _eventBus = eventBus,
       _kvService = kvService,
       _repository = repository,
       _gateEvaluator = gateEvaluator,
       _contextExtractor = contextExtractor,
       _templateEngine = templateEngine ?? WorkflowTemplateEngine(),
       _skillPromptBuilder =
           skillPromptBuilder ?? SkillPromptBuilder(augmenter: promptAugmenter ?? const PromptAugmenter()),
       _messageService = messageService,
       _turnAdapter = turnAdapter,
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
    _log.info("Workflow '${definition.name}' (${run.id}) executing from step $startFromStepIndex");

    // Build set of loop-owned step IDs (iteration steps + finalizer steps).
    // Finalizer steps are excluded from the linear pass — executed by _executeLoop.
    final loopStepIds = {
      ...definition.loops.expand((l) => l.steps),
      ...definition.loops.map((l) => l.finally_).whereType<String>(),
    };
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

      if (step.mapOver != null) {
        // ── Map step ─────────────────────────────────────────────────────────
        // Evaluate gate before map step.
        if (step.gate != null) {
          final gatePasses = _gateEvaluator.evaluate(step.gate!, context);
          if (!gatePasses) {
            final msg = "Gate failed for map step '${step.name}': ${step.gate}";
            _log.info("Workflow '${run.id}': $msg");
            await _pauseRun(run, msg);
            return;
          }
        }

        // Budget check before map step.
        final refreshedRun = await _repository.getById(run.id) ?? run;
        run = refreshedRun;
        run = await _checkWorkflowBudgetWarning(run, definition);
        if (_workflowBudgetExceeded(run, definition)) {
          final msg = 'Workflow budget exceeded: ${run.totalTokens} / ${definition.maxTokens} tokens';
          _log.info("Workflow '${run.id}': $msg");
          await _pauseRun(run, msg);
          return;
        }

        final mapResult = await _executeMapStep(run, definition, step, context, stepIndex: stepIndex);
        if (mapResult == null) return; // Already paused.

        // Always store results in context (even on partial failure — completed
        // results are preserved; error slots contain error objects).
        for (final outputKey in step.contextOutputs) {
          context[outputKey] = mapResult.results;
        }

        if (!mapResult.success) {
          final msg = mapResult.error ?? "Map step '${step.id}' failed";
          _log.info("Workflow '${run.id}': $msg");
          // Persist results before pausing so they're available in context.
          run = run.copyWith(
            totalTokens: run.totalTokens + mapResult.totalTokens,
            contextJson: {
              for (final e in run.contextJson.entries)
                if (e.key.startsWith('_') && !e.key.startsWith('_map.current')) e.key: e.value,
              ...context.toJson(),
            },
            updatedAt: DateTime.now(),
          );
          await _persistContext(run.id, context);
          await _repository.update(run);
          await _pauseRun(run, msg);
          return;
        }

        run = run.copyWith(
          totalTokens: run.totalTokens + mapResult.totalTokens,
          currentStepIndex: stepIndex + 1,
          contextJson: {
            for (final e in run.contextJson.entries)
              if (e.key.startsWith('_') && !e.key.startsWith('_map.current')) e.key: e.value,
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
            taskId: '',
            success: true,
            tokenCount: mapResult.totalTokens,
            timestamp: DateTime.now(),
          ),
        );

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
        final group = isParallelResume ? fullGroup.where((s) => resumeFailedIds.contains(s.id)).toList() : fullGroup;

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
          final msg = 'Workflow budget exceeded: ${run.totalTokens} / ${definition.maxTokens} tokens';
          _log.info("Workflow '${run.id}': $msg");
          await _pauseRun(run, msg);
          return;
        }

        // Track parallel group state for resume support.
        run = run.copyWith(
          contextJson: {...run.contextJson, '_parallel.current.stepIds': fullGroupStepIds},
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
              if (e.key != '_parallel.current.stepIds' && e.key != '_parallel.failed.stepIds') e.key: e.value,
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
        final msg = 'Workflow budget exceeded: ${run.totalTokens} / ${definition.maxTokens} tokens';
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
        // Collect a human-readable reason for logging / pause message.
        final reason = result.error ?? result.task?.configJson['failReason'] as String?;
        final msg =
            "Step '${step.id}' (${step.name}) ${result.task?.status.name ?? 'failed'}"
            "${reason != null ? ': $reason' : ''}";
        _log.info("Workflow '${run.id}': $msg");

        if (step.onError == 'continue') {
          // Record failed-step metadata so downstream steps can inspect it.
          context.merge(result.outputs);
          if (!result.outputs.containsKey('${step.id}.status')) {
            context['${step.id}.status'] = 'failed';
          }
          context['${step.id}.tokenCount'] = result.tokenCount;

          run = run.copyWith(
            totalTokens: run.totalTokens + result.tokenCount,
            currentStepIndex: stepIndex + 1,
            contextJson: {
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
              taskId: result.task?.id ?? '',
              success: false,
              tokenCount: result.tokenCount,
              timestamp: DateTime.now(),
            ),
          );
          stepIndex++;
          continue;
        }

        await _pauseRun(run, msg);
        return;
      }

      context.merge(result.outputs);
      // Bash steps set their own status metadata in outputs; agent steps use task status.
      if (!result.outputs.containsKey('${step.id}.status')) {
        context['${step.id}.status'] = result.task!.status.name;
      }
      context['${step.id}.tokenCount'] = result.tokenCount;
      // Store session ID for downstream continueSession resolution.
      final stepSessionId = result.task?.sessionId;
      if (stepSessionId != null) {
        context['${step.id}.sessionId'] = stepSessionId;
      }

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
          taskId: result.task?.id ?? '',
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

      final iterStart = (loopIdx == loopStartIndex && startFromLoopIteration != null) ? startFromLoopIteration : 1;

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
  List<WorkflowStep> _collectParallelGroup(List<WorkflowStep> steps, int startIndex, Set<String> loopStepIds) {
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
  /// Uses the same per-step dispatcher as sequential execution so hybrid step
  /// semantics stay consistent across both code paths.
  Future<List<_ParallelStepResult>> _executeParallelGroup(
    WorkflowRun run,
    WorkflowDefinition definition,
    List<WorkflowStep> group,
    WorkflowContext context,
  ) async {
    final futures = group.map((step) async {
      try {
        final stepIndex = definition.steps.indexOf(step);
        final result = await _executeStep(run, definition, step, context, stepIndex: stepIndex);
        if (result == null) {
          return _ParallelStepResult(
            step: step,
            outputs: const {},
            tokenCount: 0,
            success: false,
            error: 'step did not complete',
          );
        }
        return result;
      } catch (e, st) {
        _log.severe("Parallel step '${step.name}' failed: $e", e, st);
        return _ParallelStepResult(step: step, outputs: {}, tokenCount: 0, success: false, error: e.toString());
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
      if (!result.outputs.containsKey('${result.step.id}.status')) {
        context['${result.step.id}.status'] = result.success ? (result.task?.status.name ?? 'unknown') : 'failed';
      }
      if (!result.outputs.containsKey('${result.step.id}.tokenCount')) {
        context['${result.step.id}.tokenCount'] = result.tokenCount;
      }
      final stepSessionId = result.task?.sessionId;
      if (stepSessionId != null) {
        context['${result.step.id}.sessionId'] = stepSessionId;
      }
    }
  }

  /// Accumulates token counts from all parallel results into [run.totalTokens].
  WorkflowRun _updateParallelBudget(WorkflowRun run, List<_ParallelStepResult> results) {
    final total = results.fold(0, (sum, r) => sum + r.tokenCount);
    return run.copyWith(totalTokens: run.totalTokens + total, updatedAt: DateTime.now());
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
          _log.info("Workflow '${run.id}' cancelled in loop '${loop.id}' iter $iteration");
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
            final msg = "Gate failed in loop '${loop.id}' iteration $iteration: ${step.gate}";
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
          final failMsg = "Loop '${loop.id}' step '${step.name}' failed in iteration $iteration";
          _log.info("Workflow '${run.id}': $failMsg");

          if (step.onError == 'continue') {
            // Record failed-step metadata and continue to next loop step.
            context.merge(result.outputs);
            if (!result.outputs.containsKey('${step.id}.status')) {
              context['${step.id}.status'] = 'failed';
            }
            context['${step.id}.tokenCount'] = result.tokenCount;
            run = run.copyWith(totalTokens: run.totalTokens + result.tokenCount, updatedAt: DateTime.now());
            onRunUpdated(run);
            _eventBus.fire(
              WorkflowStepCompletedEvent(
                runId: run.id,
                stepId: step.id,
                stepName: step.name,
                stepIndex: stepIndex,
                totalSteps: definition.steps.length,
                taskId: result.task?.id ?? '',
                success: false,
                tokenCount: result.tokenCount,
                timestamp: DateTime.now(),
              ),
            );
            continue;
          }

          // Run the finalizer before pausing (if defined).
          if (loop.finally_ != null) {
            final (updatedRun, finalizerMsg) = await _executeLoopFinalizer(
              run,
              definition,
              loop,
              context,
              onRunUpdated: onRunUpdated,
            );
            run = updatedRun;
            if (finalizerMsg != null) {
              await _pauseRun(run, finalizerMsg);
              return true;
            }
          }
          await _pauseRun(run, failMsg);
          return true;
        }

        context.merge(result.outputs);
        if (!result.outputs.containsKey('${step.id}.status')) {
          context['${step.id}.status'] = result.task!.status.name;
        }
        context['${step.id}.tokenCount'] = result.tokenCount;
        final loopStepSessionId = result.task?.sessionId;
        if (loopStepSessionId != null) {
          context['${step.id}.sessionId'] = loopStepSessionId;
        }

        run = run.copyWith(totalTokens: run.totalTokens + result.tokenCount, updatedAt: DateTime.now());
        onRunUpdated(run);

        _eventBus.fire(
          WorkflowStepCompletedEvent(
            runId: run.id,
            stepId: step.id,
            stepName: step.name,
            stepIndex: stepIndex,
            totalSteps: definition.steps.length,
            taskId: result.task?.id ?? '',
            success: result.success,
            tokenCount: result.tokenCount,
            timestamp: DateTime.now(),
          ),
        );
      }

      // Evaluate exit gate after all steps in this iteration.
      if (_gateEvaluator.evaluate(loop.exitGate, context)) {
        gatePassed = true;
        _log.info("Loop '${loop.id}' completed: exit gate passed at iteration $iteration");
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
        // Run the finalizer before exiting the loop (if defined).
        if (loop.finally_ != null) {
          final (updatedRun, finalizerMsg) = await _executeLoopFinalizer(
            run,
            definition,
            loop,
            context,
            onRunUpdated: onRunUpdated,
          );
          run = updatedRun;
          if (finalizerMsg != null) {
            await _pauseRun(run, finalizerMsg);
            return true;
          }
        }
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
      run = run.copyWith(contextJson: context.toJson(), updatedAt: DateTime.now());
      await _repository.update(run);
      onRunUpdated(run);
    }

    if (!gatePassed) {
      // Clear loop tracking before pausing.
      run = run.copyWith(
        contextJson: {
          for (final e in run.contextJson.entries)
            if (!e.key.startsWith('_loop.current')) e.key: e.value,
        },
        updatedAt: DateTime.now(),
      );
      await _repository.update(run);
      onRunUpdated(run);

      // Run the finalizer before pausing (if defined).
      if (loop.finally_ != null) {
        final (updatedRun, finalizerMsg) = await _executeLoopFinalizer(
          run,
          definition,
          loop,
          context,
          onRunUpdated: onRunUpdated,
        );
        run = updatedRun;
        if (finalizerMsg != null) {
          await _pauseRun(run, finalizerMsg);
          return true;
        }
      }

      final msg =
          "Loop '${loop.id}' reached max iterations (${loop.maxIterations}). "
          'Exit condition not met: ${loop.exitGate}';
      _log.info("Workflow '${run.id}': $msg");
      await _pauseRun(run, msg);
      return true;
    }

    // Clear loop tracking state on success.
    run = run.copyWith(
      contextJson: {
        for (final e in run.contextJson.entries)
          if (!e.key.startsWith('_loop.current')) e.key: e.value,
        ...context.toJson(),
      },
      updatedAt: DateTime.now(),
    );
    await _repository.update(run);
    onRunUpdated(run);

    return false;
  }

  /// Executes the finalizer step for a loop, if one is defined.
  ///
  /// Returns a record of (updated run, error message). If [errorMessage] is non-null,
  /// the caller should pause the run with that message. If null, the finalizer
  /// completed successfully and execution may continue.
  Future<(WorkflowRun, String?)> _executeLoopFinalizer(
    WorkflowRun run,
    WorkflowDefinition definition,
    WorkflowLoop loop,
    WorkflowContext context, {
    required void Function(WorkflowRun) onRunUpdated,
  }) async {
    final finallyStepId = loop.finally_!;
    final finallyStep = definition.steps.firstWhere((s) => s.id == finallyStepId);
    final stepIndex = definition.steps.indexOf(finallyStep);

    _log.info("Workflow '${run.id}': executing finalizer '${finallyStep.id}' for loop '${loop.id}'");

    final result = await _executeStep(run, definition, finallyStep, context, stepIndex: stepIndex);

    if (result == null) {
      // Task creation failed — already paused by _executeStep.
      return (run, null);
    }

    if (!result.success) {
      final msg = "Loop '${loop.id}' finalizer '${finallyStep.name}' failed";
      _log.info("Workflow '${run.id}': $msg");
      return (run, msg);
    }

    context.merge(result.outputs);
    context['${finallyStep.id}.status'] = result.task!.status.name;
    context['${finallyStep.id}.tokenCount'] = result.tokenCount;

    run = run.copyWith(totalTokens: run.totalTokens + result.tokenCount, updatedAt: DateTime.now());
    onRunUpdated(run);

    _eventBus.fire(
      WorkflowStepCompletedEvent(
        runId: run.id,
        stepId: finallyStep.id,
        stepName: finallyStep.name,
        stepIndex: stepIndex,
        totalSteps: definition.steps.length,
        taskId: result.task!.id,
        success: true,
        tokenCount: result.tokenCount,
        timestamp: DateTime.now(),
      ),
    );

    return (run, null);
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
    // Dispatch bash steps to the zero-task host executor.
    if (step.type == 'bash') {
      return _executeBashStep(run, step, context);
    }

    // Dispatch approval steps — zero-task pause with metadata persistence.
    if (step.type == 'approval') {
      await _executeApprovalStep(run, step, context, stepIndex: stepIndex);
      return null; // Already paused — caller must stop.
    }

    // Resolve effective config (per-step overrides matching stepDefaults entry).
    final resolved = resolveStepConfig(step, definition.stepDefaults);

    // Augment only the LAST prompt with schema instructions.
    final effectiveOutputs = step.outputs;
    final resolvedFirstPrompt = step.prompts != null ? _templateEngine.resolve(step.prompts!.first, context) : null;
    final contextSummary = step.skill != null && resolvedFirstPrompt == null
        ? SkillPromptBuilder.formatContextSummary({for (final key in step.contextInputs) key: context[key] ?? ''})
        : null;
    var taskConfig = _buildStepConfig(step, resolved);

    final continuedRootStep = step.continueSession != null ? _resolveContinueSessionRootStep(definition, step) : null;
    final effectiveProvider = continuedRootStep != null
        ? resolveStepConfig(continuedRootStep, definition.stepDefaults).provider
        : resolved.provider;
    final effectiveProjectId = _resolveProjectId(continuedRootStep ?? step, context);

    // continueSession: resolve root session and snapshot token baseline.
    if (continuedRootStep != null) {
      final prevSessionId = _resolveContinueSessionRootSessionId(definition, step, context);
      if (prevSessionId == null) {
        final msg =
            "Step '${step.id}' uses continueSession but no session ID found for root step "
            "'${continuedRootStep.id}'. Ensure the referenced step completed successfully first.";
        _log.warning("Workflow '${run.id}': $msg");
        await _pauseRun(run, msg);
        return null;
      }
      final baselineTokens = await _readSessionTokens(prevSessionId);
      taskConfig = {...taskConfig, '_continueSessionId': prevSessionId, '_sessionBaselineTokens': baselineTokens};
    }
    final taskId = _uuid.v4();

    // Subscribe before create to avoid race condition.
    final completer = Completer<Task>();
    final sub = _eventBus.on<TaskStatusChangedEvent>().where((e) => e.taskId == taskId).listen((event) async {
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

    // For single-prompt steps, augment the first (only) prompt now.
    // For multi-prompt, augment the last prompt later; first prompt is unaugmented.
    final firstTaskPrompt = step.isMultiPrompt
        ? _skillPromptBuilder.build(
            skill: step.skill,
            resolvedPrompt: resolvedFirstPrompt,
            contextSummary: contextSummary,
          )
        : _skillPromptBuilder.build(
            skill: step.skill,
            resolvedPrompt: resolvedFirstPrompt,
            contextSummary: contextSummary,
            outputs: effectiveOutputs,
          );

    try {
      await _taskService.create(
        id: taskId,
        title: title,
        description: firstTaskPrompt,
        type: _mapStepType(step.type),
        autoStart: true,
        provider: effectiveProvider,
        projectId: effectiveProjectId,
        maxTokens: resolved.maxTokens,
        maxRetries: resolved.maxRetries ?? 0,
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

    // If step failed at first prompt, return failure immediately.
    if (finalTask.status == TaskStatus.failed || finalTask.status == TaskStatus.cancelled) {
      return _ParallelStepResult(step: step, task: finalTask, outputs: {}, tokenCount: 0, success: false);
    }

    // Multi-prompt: send follow-up turns in the same session.
    if (step.isMultiPrompt) {
      final followUpResult = await _executeFollowUpPrompts(run, step, finalTask, context, effectiveOutputs);
      if (followUpResult == null) return null; // Paused by budget/error.
      finalTask = followUpResult.$1;
      // If a follow-up prompt failed, return failure.
      if (finalTask.status == TaskStatus.failed || finalTask.status == TaskStatus.cancelled) {
        return _ParallelStepResult(
          step: step,
          task: finalTask,
          outputs: {},
          tokenCount: followUpResult.$2,
          success: false,
        );
      }
    }

    Map<String, dynamic> outputs = {};
    int tokenCount = 0;
    try {
      outputs = await _contextExtractor.extract(step, finalTask);
    } catch (e, st) {
      _log.warning("Context extraction failed for step '${step.id}'", e, st);
    }
    tokenCount = await _readStepTokenCount(finalTask);

    // TI04: Auto-expose worktree metadata for coding steps.
    // Injects <stepId>.branch and <stepId>.worktree_path from persisted task.worktreeJson.
    // Empty string for absent metadata — downstream steps can check the value; no failure.
    if (finalTask.type == TaskType.coding) {
      final wj = finalTask.worktreeJson;
      outputs['${step.id}.branch'] = (wj?['branch'] as String?) ?? '';
      outputs['${step.id}.worktree_path'] = (wj?['path'] as String?) ?? '';
      if (wj == null) {
        _log.warning(
          "Workflow '${run.id}': step '${step.id}' is a coding task but has no worktree metadata — "
          'branch/worktree_path context values will be empty',
        );
      }
    }

    return _ParallelStepResult(step: step, task: finalTask, outputs: outputs, tokenCount: tokenCount, success: true);
  }

  // ── Bash step execution ─────────────────────────────────────────────────────

  /// Executes a `type: bash` step on the host via [Process.run].
  ///
  /// - Zero task creation; zero token accounting.
  /// - `{{context.*}}` substitutions are shell-escaped before execution.
  /// - stdout truncated at 64 KB with `[truncated]` marker.
  /// - `onError: continue` records failure and returns success=true with
  ///   `<stepId>.status == 'failed'` so downstream steps see the failure.
  /// - `onError: pause` (default) returns success=false → caller pauses run.
  static const _bashStdoutMaxBytes = 64 * 1024;

  Future<_ParallelStepResult> _executeBashStep(WorkflowRun run, WorkflowStep step, WorkflowContext context) async {
    // Resolve workdir.
    final String workDir;
    try {
      workDir = _resolveBashWorkdir(step, context);
    } catch (e) {
      return _bashFailure(step, 'workdir resolution failed: $e');
    }

    // Validate workdir existence before spawning.
    if (!Directory(workDir).existsSync()) {
      return _bashFailure(step, 'workdir does not exist: $workDir');
    }

    // Resolve template in the command (single-string prompt).
    final rawCommand = step.prompts?.firstOrNull ?? '';
    final String resolvedCommand;
    try {
      resolvedCommand = _resolveBashCommand(rawCommand, context);
    } catch (e) {
      return _bashFailure(step, 'command substitution failed: $e');
    }

    // Execute via Process.start so timed-out commands can be terminated explicitly.
    final timeoutSeconds = step.timeoutSeconds ?? 60;
    late Process process;
    try {
      process = await Process.start('/bin/sh', ['-c', resolvedCommand], workingDirectory: workDir, runInShell: false);
    } catch (e) {
      return _bashFailure(step, 'process execution failed: $e');
    }

    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();

    late int exitCode;
    try {
      exitCode = await process.exitCode.timeout(Duration(seconds: timeoutSeconds));
    } on TimeoutException {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
      }
      final stderr = await stderrFuture;
      return _bashFailure(step, 'timed out after ${timeoutSeconds}s', stderr: stderr);
    }

    // Capture and truncate stdout.
    final rawStdout = await stdoutFuture;
    final bool truncated = rawStdout.length > _bashStdoutMaxBytes;
    final stdout = truncated ? '${rawStdout.substring(0, _bashStdoutMaxBytes)}[truncated]' : rawStdout;
    final stderr = await stderrFuture;

    if (exitCode != 0) {
      _log.warning(
        "Workflow '${run.id}': bash step '${step.id}' exited $exitCode"
        "${stderr.isNotEmpty ? ': ${stderr.trim()}' : ''}",
      );
      return _bashFailure(step, 'exited with code $exitCode', stderr: stderr);
    }

    // Extract context outputs from stdout.
    final Map<String, dynamic> outputs;
    try {
      outputs = _extractBashOutputs(step, stdout);
    } on FormatException catch (e) {
      return _bashFailure(step, e.message, stderr: stderr);
    }

    // Record step metadata in context.
    return _ParallelStepResult(
      step: step,
      task: null,
      outputs: {
        ...outputs,
        '${step.id}.status': 'success',
        '${step.id}.exitCode': exitCode,
        '${step.id}.tokenCount': 0,
        '${step.id}.workdir': workDir,
        if (stderr.isNotEmpty) '${step.id}.stderr': stderr,
        if (truncated) '${step.id}.stdoutTruncated': true,
      },
      tokenCount: 0,
      success: true,
    );
  }

  /// Resolves the working directory for a bash step.
  ///
  /// Resolution order:
  ///   1. explicit `workdir` field (with template resolution)
  ///   2. workspace root (`<dataDir>/workspace`, created if absent)
  String _resolveBashWorkdir(WorkflowStep step, WorkflowContext context) {
    if (step.workdir != null) {
      final resolved = _templateEngine.resolve(step.workdir!, context).trim();
      if (resolved.isEmpty) {
        throw ArgumentError('workdir resolved to an empty path');
      }
      return resolved;
    }
    // Default: workspace root. Create it if absent so fresh installs work.
    final workspaceRoot = p.join(_dataDir, 'workspace');
    Directory(workspaceRoot).createSync(recursive: true);
    return workspaceRoot;
  }

  /// Resolves template references in [command], shell-escaping all
  /// `{{context.*}}` substitution values to prevent injection.
  String _resolveBashCommand(String command, WorkflowContext context) {
    return command.replaceAllMapped(RegExp(r'\{\{([^}]+)\}\}'), (match) {
      final ref = match.group(1)!.trim();
      if (ref.startsWith('context.')) {
        final key = ref.substring('context.'.length);
        final value = context[key];
        if (value == null) {
          _log.warning(
            'Bash command template reference {{$ref}} resolved to empty string '
            '(key "$key" not in context)',
          );
          return shellEscape('');
        }
        // Shell-escape context values to prevent injection.
        return shellEscape(value.toString());
      }
      // Variable references (non-context) are NOT shell-escaped — they are
      // author-controlled and expected to be safe command fragments.
      final value = context.variable(ref);
      if (value == null) {
        throw ArgumentError('Bash command references undefined variable: {{$ref}}');
      }
      return value;
    });
  }

  /// Extracts context outputs from bash [stdout] using the step's output config.
  Map<String, dynamic> _extractBashOutputs(WorkflowStep step, String stdout) {
    if (step.contextOutputs.isEmpty) return {};

    final outputs = <String, dynamic>{};
    for (final outputKey in step.contextOutputs) {
      final config = step.outputs?[outputKey];
      final format = config?.format ?? OutputFormat.text;

      switch (format) {
        case OutputFormat.json:
          if (stdout.trim().isEmpty) {
            throw FormatException('Bash step "${step.id}": empty stdout for json extraction of "$outputKey"');
          } else {
            try {
              outputs[outputKey] = extractJson(stdout);
            } on FormatException catch (e) {
              throw FormatException('Bash step "${step.id}": JSON extraction failed for "$outputKey": $e');
            }
          }
        case OutputFormat.lines:
          outputs[outputKey] = extractLines(stdout);
        case OutputFormat.text:
          outputs[outputKey] = stdout;
      }
    }
    return outputs;
  }

  /// Returns a failed [_ParallelStepResult] for a bash step.
  _ParallelStepResult _bashFailure(WorkflowStep step, String reason, {String? stderr}) {
    _log.info("Bash step '${step.id}' failed: $reason");
    return _ParallelStepResult(
      step: step,
      task: null,
      outputs: {
        '${step.id}.status': 'failed',
        '${step.id}.exitCode': -1,
        '${step.id}.tokenCount': 0,
        '${step.id}.error': reason,
        if (stderr != null && stderr.isNotEmpty) '${step.id}.stderr': stderr,
      },
      tokenCount: 0,
      success: false,
      error: reason,
    );
  }

  /// Executes a `type: approval` step — pauses the run with approval metadata.
  ///
  /// No child task is created and no tokens are consumed. Approval metadata is
  /// persisted in contextJson so the API and UI can surface it without task lookups.
  /// If [step.timeoutSeconds] is set, a timer auto-cancels the run on expiry.
  Future<void> _executeApprovalStep(
    WorkflowRun run,
    WorkflowStep step,
    WorkflowContext context, {
    required int stepIndex,
  }) async {
    final message = _templateEngine.resolve(step.prompts?.firstOrNull ?? '', context);
    final requestedAt = DateTime.now().toIso8601String();

    // Persist approval metadata — stored both in context (for downstream template access)
    // and as flat contextJson keys (for API/UI lookups without task joins).
    context['${step.id}.status'] = 'pending';
    context['${step.id}.approval.status'] = 'pending';
    context['${step.id}.approval.message'] = message;
    context['${step.id}.approval.requested_at'] = requestedAt;
    context['${step.id}.tokenCount'] = 0;

    final timeoutSeconds = step.timeoutSeconds;
    final approvalMeta = <String, dynamic>{
      '${step.id}.status': 'pending',
      '${step.id}.approval.status': 'pending',
      '${step.id}.approval.message': message,
      '${step.id}.approval.requested_at': requestedAt,
      '${step.id}.tokenCount': 0,
      // Store step index so resume can advance past the approval step.
      '_approval.pending.stepId': step.id,
      '_approval.pending.stepIndex': stepIndex,
    };

    if (timeoutSeconds != null) {
      final deadline = DateTime.now().add(Duration(seconds: timeoutSeconds)).toIso8601String();
      context['${step.id}.approval.timeout_deadline'] = deadline;
      approvalMeta['${step.id}.approval.timeout_deadline'] = deadline;
    }

    final pausedRun = run.copyWith(
      // Advance currentStepIndex past this approval step so on resume the
      // executor starts at the next step (approval step doesn't re-execute).
      currentStepIndex: stepIndex + 1,
      contextJson: {
        for (final e in run.contextJson.entries)
          if (e.key.startsWith('_')) e.key: e.value,
        ...context.toJson(),
        // Flat approval keys accessible directly on run.contextJson without data sub-key.
        ...approvalMeta,
      },
      updatedAt: DateTime.now(),
    );
    await _persistContext(run.id, context);
    await _repository.update(pausedRun);

    _eventBus.fire(
      WorkflowApprovalRequestedEvent(
        runId: run.id,
        stepId: step.id,
        message: message,
        timeoutSeconds: timeoutSeconds,
        timestamp: DateTime.now(),
      ),
    );

    await _pauseRun(pausedRun, 'approval required: ${step.id}');

    // Start timeout timer if configured.
    if (timeoutSeconds != null) {
      final timerKey = '${run.id}:${step.id}';
      _approvalTimers[timerKey] = Timer(Duration(seconds: timeoutSeconds), () async {
        _approvalTimers.remove(timerKey);
        final current = await _repository.getById(run.id);
        if (current == null || current.status != WorkflowRunStatus.paused) return;
        final updatedContext = Map<String, dynamic>.from(current.contextJson)
          ..['${step.id}.status'] = 'cancelled'
          ..['${step.id}.approval.status'] = 'timed_out'
          ..['${step.id}.approval.cancel_reason'] = 'timeout';
        final withReason = current.copyWith(contextJson: updatedContext, updatedAt: DateTime.now());
        await _repository.update(withReason);
        await _cancelRun(withReason, 'approval timeout: ${step.id}');
      });
    }
  }

  /// Cancels a workflow run (used for approval timeout).
  ///
  /// Parallel to [_pauseRun] and [_completeRun] — transitions run to cancelled
  /// and cancels any non-terminal child tasks.
  Future<void> _cancelRun(WorkflowRun run, String reason) async {
    final cancelled = run.copyWith(
      status: WorkflowRunStatus.cancelled,
      completedAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    await _repository.update(cancelled);
    _eventBus.fire(
      WorkflowRunStatusChangedEvent(
        runId: run.id,
        definitionName: run.definitionName,
        oldStatus: run.status,
        newStatus: WorkflowRunStatus.cancelled,
        errorMessage: reason,
        timestamp: DateTime.now(),
      ),
    );

    // Cancel any non-terminal child tasks.
    final allTasks = await _taskService.list();
    for (final task in allTasks) {
      if (task.workflowRunId == run.id && !task.status.terminal) {
        try {
          await _taskService.transition(task.id, TaskStatus.cancelled, trigger: 'approval-timeout');
        } on StateError {
          // Already transitioned concurrently.
        } catch (e) {
          _log.warning('Failed to cancel task ${task.id} on approval timeout: $e');
        }
      }
    }
  }

  /// Sends follow-up prompts (prompts[1..]) as continuation turns on the same session.
  ///
  /// Returns `(finalTask, cumulativeTokens)` on success, null if the step must be paused.
  Future<(Task, int)?> _executeFollowUpPrompts(
    WorkflowRun run,
    WorkflowStep step,
    Task task,
    WorkflowContext context,
    Map<String, OutputConfig>? effectiveOutputs,
  ) async {
    final messageService = _messageService;
    final turnAdapter = _turnAdapter;
    if (messageService == null || turnAdapter == null) {
      // No turn infrastructure available — multi-prompt not supported in this configuration.
      _log.warning(
        "Step '${step.id}' is multi-prompt but WorkflowExecutor has no MessageService/turn adapter. "
        'Follow-up prompts skipped.',
      );
      return (task, 0);
    }

    var currentTask = task;
    var cumulativeTokens = await _readStepTokenCount(currentTask);
    final prompts = step.prompts!;

    for (var i = 1; i < prompts.length; i++) {
      final isLast = i == prompts.length - 1;
      final rawPrompt = prompts[i];

      // Per-step budget check before each follow-up prompt.
      if (step.maxTokens != null && cumulativeTokens >= step.maxTokens!) {
        final msg =
            "Step '${step.id}' budget exceeded before prompt ${i + 1}: "
            '$cumulativeTokens / ${step.maxTokens} tokens';
        _log.info("Workflow '${run.id}': $msg");
        await _pauseRun(run, msg);
        return null;
      }

      // Resolve template variables/context refs.
      final resolvedFollowUp = _templateEngine.resolve(rawPrompt, context);

      // Augment only the final prompt with schema instructions.
      final prompt = isLast
          ? _skillPromptBuilder.build(
              skill: null, // skill prefix applied to first prompt only
              resolvedPrompt: resolvedFollowUp,
              outputs: effectiveOutputs,
            )
          : resolvedFollowUp;

      // Refresh task to get the session ID (set by TaskExecutor during first turn).
      currentTask = await _taskService.get(currentTask.id) ?? currentTask;
      final sessionId = currentTask.sessionId;
      if (sessionId == null) {
        final msg = "Step '${step.id}' has no session ID after prompt $i: cannot send follow-up";
        _log.warning("Workflow '${run.id}': $msg");
        await _pauseRun(run, msg);
        return null;
      }

      // Insert user message into the session.
      try {
        await messageService.insertMessage(sessionId: sessionId, role: 'user', content: prompt);
      } catch (e, st) {
        final msg = "Step '${step.id}' failed to insert follow-up message at prompt ${i + 1}: $e";
        _log.severe("Workflow '${run.id}': $msg", e, st);
        await _pauseRun(run, msg);
        return null;
      }

      // Reserve and execute the continuation turn.
      final String turnId;
      try {
        final workflowWorkspaceDir = _resolveWorkflowWorkspaceDir();
        final reserveWorkflowTurn = turnAdapter.reserveTurnWithWorkflowWorkspaceDir;
        turnId = reserveWorkflowTurn != null
            ? await reserveWorkflowTurn(sessionId, workflowWorkspaceDir)
            : await turnAdapter.reserveTurn(sessionId);
      } catch (e, st) {
        final msg = "Step '${step.id}' failed to reserve turn for prompt ${i + 1}: $e";
        _log.severe("Workflow '${run.id}': $msg", e, st);
        await _pauseRun(run, msg);
        return null;
      }

      // Fetch all session messages for the turn payload.
      final sessionMessages = await messageService.getMessages(sessionId);
      final turnMessages = sessionMessages
          .map(
            (message) => <String, dynamic>{
              'id': message.id,
              'sessionId': message.sessionId,
              'role': message.role,
              'content': message.content,
              'cursor': message.cursor,
              'metadata': message.metadata,
              'createdAt': message.createdAt.toIso8601String(),
            },
          )
          .toList(growable: false);

      turnAdapter.executeTurn(sessionId, turnId, turnMessages, source: 'workflow', resume: true);
      final outcome = await turnAdapter.waitForOutcome(sessionId, turnId);

      if (outcome.status != 'completed') {
        _log.info(
          "Workflow '${run.id}': step '${step.id}' follow-up prompt ${i + 1} failed "
          '(${outcome.status})',
        );
        // Return a failed task view — step fails.
        return (currentTask.copyWith(status: TaskStatus.failed), cumulativeTokens);
      }

      // Accumulate token count after each follow-up turn.
      cumulativeTokens = await _readStepTokenCount(currentTask);
      _log.fine(
        "Workflow '${run.id}': step '${step.id}' prompt ${i + 1}/${prompts.length} complete "
        '($cumulativeTokens tokens cumulative)',
      );
    }

    return (currentTask, cumulativeTokens);
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
          onTimeout: () =>
              throw TimeoutException('Step "${step.name}" timed out', Duration(seconds: step.timeoutSeconds!)),
        );
      } else {
        return await completer.future;
      }
    } finally {
      await sub.cancel();
    }
  }

  /// Builds configJson for a task from a workflow step and its resolved config.
  Map<String, dynamic> _buildStepConfig(WorkflowStep step, ResolvedStepConfig resolved) {
    final config = <String, dynamic>{};
    if (resolved.model != null) config['model'] = resolved.model;
    if (resolved.maxTokens != null) config['tokenBudget'] = resolved.maxTokens;
    if (resolved.allowedTools != null) config['allowedTools'] = resolved.allowedTools;
    if (resolved.maxCostUsd != null) config['maxCostUsd'] = resolved.maxCostUsd;
    config['_workflowWorkspaceDir'] = _resolveWorkflowWorkspaceDir();
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

  /// Returns the workflow workspace directory used for task behavior injection.
  ///
  /// Custom workflow workspaces are supplied by the turn adapter. When no
  /// custom workspace is configured, materializes the built-in workflow
  /// workspace under `<dataDir>/workflow-workspace`.
  String _resolveWorkflowWorkspaceDir() {
    final cached = _workflowWorkspaceDirCache;
    if (cached != null) return cached;

    final defaultDir = p.join(_dataDir, 'workflow-workspace');
    final configuredDir = _turnAdapter?.workflowWorkspaceDir?.trim();
    final resolvedDir = (configuredDir == null || configuredDir.isEmpty) ? defaultDir : configuredDir;

    if (resolvedDir == defaultDir) {
      final dir = Directory(resolvedDir);
      final agentsPath = p.join(resolvedDir, 'AGENTS.md');
      dir.createSync(recursive: true);
      final file = File(agentsPath);
      if (!file.existsSync() || file.readAsStringSync() != builtInWorkflowAgentsMd) {
        file.writeAsStringSync(builtInWorkflowAgentsMd);
      }
    }

    _workflowWorkspaceDirCache = resolvedDir;
    return resolvedDir;
  }

  /// Fires a warning event when the workflow reaches 80% of its token budget.
  ///
  /// Deduplicated via `_budget.warningFired` in [run.contextJson] — fires once per run.
  /// Returns updated [run] if the flag was set, otherwise returns [run] unchanged.
  Future<WorkflowRun> _checkWorkflowBudgetWarning(WorkflowRun run, WorkflowDefinition definition) async {
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
    run = run.copyWith(contextJson: {...run.contextJson, '_budget.warningFired': true}, updatedAt: DateTime.now());
    await _repository.update(run);
    return run;
  }

  /// Reads the step's cumulative token count from session KV or task metadata.
  ///
  /// For [continueSession] steps, subtracts the baseline stored in
  /// [Task.configJson]['_sessionBaselineTokens'] so workflow totals only reflect
  /// new turns, not the full shared-session history.
  Future<int> _readStepTokenCount(Task task) async {
    if (task.sessionId == null) return 0;
    try {
      final total = await _readSessionTokens(task.sessionId!);
      final baseline = (task.configJson['_sessionBaselineTokens'] as num?)?.toInt() ?? 0;
      return (total - baseline).clamp(0, double.maxFinite).toInt();
    } catch (_) {
      return 0;
    }
  }

  /// Reads the raw cumulative token total for [sessionId] from KV store.
  Future<int> _readSessionTokens(String sessionId) async {
    try {
      final raw = await _kvService.get('session_cost:$sessionId');
      if (raw == null) return 0;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return (json['total_tokens'] as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  String? _resolveProjectId(WorkflowStep step, WorkflowContext context) {
    final project = step.project;
    if (project == null) return null;
    final resolved = _templateEngine.resolve(project, context).trim();
    return resolved.isEmpty ? null : resolved;
  }

  WorkflowStep? _resolveContinueSessionRootStep(WorkflowDefinition definition, WorkflowStep step) {
    final visited = <String>{step.id};
    var current = step;

    while (current.continueSession != null) {
      final targetStepId = _resolveContinueSessionTargetStepId(definition, current);
      if (targetStepId == null || !visited.add(targetStepId)) {
        return null;
      }
      final targetStep = definition.steps.where((candidate) => candidate.id == targetStepId).firstOrNull;
      if (targetStep == null) return null;
      if (targetStep.continueSession == null) return targetStep;
      current = targetStep;
    }

    return null;
  }

  String? _resolveContinueSessionRootSessionId(
    WorkflowDefinition definition,
    WorkflowStep step,
    WorkflowContext context,
  ) {
    final rootStep = _resolveContinueSessionRootStep(definition, step);
    if (rootStep == null) return null;
    final raw = context['${rootStep.id}.sessionId'];
    return raw is String && raw.isNotEmpty ? raw : null;
  }

  String? _resolveContinueSessionTargetStepId(WorkflowDefinition definition, WorkflowStep step) {
    final ref = step.continueSession;
    if (ref == null) return null;
    if (ref == '@previous') {
      final idx = definition.steps.indexWhere((candidate) => candidate.id == step.id);
      return idx > 0 ? definition.steps[idx - 1].id : null;
    }
    return ref;
  }

  void dispose() {
    for (final timer in _approvalTimers.values) {
      timer.cancel();
    }
    _approvalTimers.clear();
  }

  /// Persists [context] to `<dataDir>/workflows/<runId>/context.json` atomically.
  Future<void> _persistContext(String runId, WorkflowContext context) async {
    final dir = Directory(p.join(_dataDir, 'workflows', runId));
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, 'context.json'));
    await atomicWriteJson(file, context.toJson());
  }

  // ── Map step execution ─────────────────────────────────────────────────────

  /// Resolves the `maxParallel` field from `step.maxParallel` at runtime.
  ///
  /// - `null` → default 1 (sequential)
  /// - `int` → use directly
  /// - `"unlimited"` → `null` (no cap)
  /// - template string (e.g. `"{{MAX_PARALLEL}}"`) → resolve via [context] then parse
  ///
  /// Throws [ArgumentError] if the resolved value cannot be parsed as an integer.
  int? _resolveMaxParallel(Object? raw, WorkflowContext context, String stepId) {
    if (raw == null) return 1; // Default: sequential.
    if (raw is int) return raw;
    if (raw is! String) return 1;

    // Resolve template references if present.
    final resolved = raw.contains('{{') ? _templateEngine.resolve(raw, context) : raw;

    if (resolved.toLowerCase() == 'unlimited') return null;
    final parsed = int.tryParse(resolved.trim());
    if (parsed != null) return parsed;
    throw ArgumentError(
      "Map step '$stepId': maxParallel '$raw' resolved to '$resolved' "
      'which is not an integer or "unlimited".',
    );
  }

  /// Builds a structured coding task result from a completed [task].
  ///
  /// Returns a Map with `text`, `task_id`, `diff`, and `worktree` fields.
  /// `diff` and `worktree` may be null if not available.
  Future<Map<String, dynamic>> _buildCodingResult(Task task, Map<String, dynamic> outputs) async {
    final text = outputs.values.whereType<String>().firstOrNull ?? '';
    final diff = await _readCodingDiff(task);
    final worktree = _readWorktreePath(task);
    return {'text': text, 'task_id': task.id, 'diff': diff, 'worktree': worktree};
  }

  /// Reads the diff summary from the task's `diff.json` artifact, if present.
  Future<String?> _readCodingDiff(Task task) async {
    try {
      final artifacts = await _taskService.listArtifacts(task.id);
      for (final artifact in artifacts) {
        if (artifact.path.endsWith('diff.json')) {
          final file = File(
            p.isAbsolute(artifact.path)
                ? artifact.path
                : p.join(_dataDir, 'tasks', task.id, 'artifacts', artifact.path),
          );
          if (!file.existsSync()) return null;
          final raw = await file.readAsString();
          try {
            final json = jsonDecode(raw) as Map<String, dynamic>;
            final files = (json['files'] as int?) ?? 0;
            final additions = (json['additions'] as int?) ?? 0;
            final deletions = (json['deletions'] as int?) ?? 0;
            return '$files files changed, +$additions -$deletions';
          } catch (_) {
            return raw;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// Extracts the worktree path from a task's `worktreeJson`, if available.
  String? _readWorktreePath(Task task) {
    final wj = task.worktreeJson;
    if (wj == null) return null;
    return wj['path'] as String?;
  }

  /// Executes a map/fan-out step.
  ///
  /// Resolves the collection from context, validates size, dispatches per-item
  /// tasks with bounded concurrency (respecting `maxParallel` and dependency
  /// ordering), collects index-ordered results, and fires progress events.
  ///
  /// Returns `null` if the executor has already paused the run (task creation
  /// failure). Returns a [_MapStepResult] on success or failure.
  Future<_MapStepResult?> _executeMapStep(
    WorkflowRun run,
    WorkflowDefinition definition,
    WorkflowStep step,
    WorkflowContext context, {
    required int stepIndex,
  }) async {
    // 1. Resolve collection from context.
    final rawCollection = context[step.mapOver!];
    if (rawCollection == null) {
      return _MapStepResult(
        results: const [],
        totalTokens: 0,
        success: false,
        error: "Map step '${step.id}': context key '${step.mapOver}' is null or missing",
      );
    }
    if (rawCollection is! List) {
      return _MapStepResult(
        results: const [],
        totalTokens: 0,
        success: false,
        error:
            "Map step '${step.id}': context key '${step.mapOver}' is not a List "
            '(got ${rawCollection.runtimeType})',
      );
    }
    final collection = rawCollection;

    // 2. Check maxItems.
    if (collection.length > step.maxItems) {
      return _MapStepResult(
        results: const [],
        totalTokens: 0,
        success: false,
        error:
            "Map step '${step.id}': collection has ${collection.length} items "
            'which exceeds maxItems (${step.maxItems}). '
            'Consider decomposing into smaller batches.',
      );
    }

    // 3. Resolve maxParallel.
    final int? maxParallel;
    try {
      maxParallel = _resolveMaxParallel(step.maxParallel, context, step.id);
    } on ArgumentError catch (e) {
      return _MapStepResult(results: const [], totalTokens: 0, success: false, error: e.message.toString());
    }

    // 4. Empty collection → succeed immediately.
    if (collection.isEmpty) {
      _log.warning(
        "Workflow '${run.id}': map step '${step.id}' has empty collection — "
        'succeeding with empty result array',
      );
      return const _MapStepResult(results: [], totalTokens: 0, success: true);
    }

    // 5. Validate dependencies (detect cycles before any dispatch).
    final depGraph = DependencyGraph(collection);
    if (depGraph.hasDependencies) {
      try {
        depGraph.validate();
      } on ArgumentError catch (e) {
        return _MapStepResult(
          results: const [],
          totalTokens: 0,
          success: false,
          error: "Map step '${step.id}': ${e.message}",
        );
      }
    }

    // 6. Create MapStepContext.
    final mapCtx = MapStepContext(collection: collection, maxParallel: maxParallel, maxItems: step.maxItems);

    // 7. Persist map tracking state.
    run = run.copyWith(
      contextJson: {...run.contextJson, '_map.current.stepId': step.id, '_map.current.total': collection.length},
      updatedAt: DateTime.now(),
    );
    await _repository.update(run);

    // 8. Resolve step config once for all iterations.
    final resolved = resolveStepConfig(step, definition.stepDefaults);

    // 9. Bounded concurrency dispatch loop.
    //    inFlight: index → Future that settles when the iteration completes/fails.
    //    pending: FIFO queue of indices yet to dispatch.
    //    completedIds: set of item IDs that have finished (for dep tracking).
    final inFlight = <int, Future<void>>{};
    final pending = Queue<int>.from(List.generate(collection.length, (i) => i));
    final completedIds = <String>{};
    var totalTokens = 0;

    while (pending.isNotEmpty || inFlight.isNotEmpty) {
      // Check budget before dispatching more items.
      if (mapCtx.budgetExhausted) {
        // Cancel all remaining pending items.
        while (pending.isNotEmpty) {
          final cancelIdx = pending.removeFirst();
          mapCtx.recordCancelled(cancelIdx, 'Cancelled: budget exhausted');
        }
        break;
      }

      // Dispatch eligible items up to the concurrency cap.
      final poolAvailable = _turnAdapter?.availableRunnerCount?.call();
      final concurrencyCap = mapCtx.effectiveConcurrency(poolAvailable);
      while (inFlight.length < concurrencyCap && pending.isNotEmpty) {
        // Find the next dependency-eligible index from the pending queue.
        int? nextIndex;
        if (depGraph.hasDependencies) {
          final ready = depGraph.getReady(completedIds);
          // Find first pending index that is in the ready set.
          for (final idx in pending) {
            if (ready.contains(idx)) {
              nextIndex = idx;
              break;
            }
          }
        } else {
          nextIndex = pending.first;
        }
        if (nextIndex == null) break; // All remaining blocked on deps.
        pending.remove(nextIndex);

        final iterIndex = nextIndex;
        final mapContext = MapContext(
          item: (collection[iterIndex] as Object?) ?? '',
          index: iterIndex,
          length: collection.length,
        );

        // Resolve per-iteration prompt (resolveWithMap handles {{map.*}}).
        final rawPrompt = step.prompt;
        final resolvedPrompt = rawPrompt != null
            ? _templateEngine.resolveWithMap(rawPrompt, context, mapContext)
            : null;
        final contextSummary = step.skill != null && resolvedPrompt == null
            ? SkillPromptBuilder.formatContextSummary({for (final key in step.contextInputs) key: context[key] ?? ''})
            : null;
        final effectiveOutputs = step.outputs;
        final iterPrompt = _skillPromptBuilder.build(
          skill: step.skill,
          resolvedPrompt: resolvedPrompt,
          contextSummary: contextSummary,
          outputs: effectiveOutputs,
        );
        final taskConfig = _buildStepConfig(step, resolved);
        final iterTitle = '${definition.name} — ${step.name} (${iterIndex + 1}/${collection.length})';

        // Dispatch: create the task and await its completion in a detached future.
        // Increment inFlight count synchronously before awaiting to prevent races.
        mapCtx.inFlightCount++;

        inFlight[iterIndex] =
            _dispatchIteration(
              run: run,
              definition: definition,
              step: step,
              stepIndex: stepIndex,
              iterIndex: iterIndex,
              iterPrompt: iterPrompt,
              iterTitle: iterTitle,
              taskConfig: taskConfig,
              resolved: resolved,
              mapCtx: mapCtx,
              context: context,
            ).then((_) {
              inFlight.remove(iterIndex);
              final itemId = mapCtx.itemId(iterIndex);
              if (itemId != null) completedIds.add(itemId);
            });
      }

      // If nothing dispatched and nothing in-flight but items remain — deadlock.
      if (inFlight.isEmpty && pending.isNotEmpty) {
        _log.warning(
          "Workflow '${run.id}': map step '${step.id}' — "
          '${pending.length} items blocked by unsatisfiable dependencies (deadlock guard).',
        );
        while (pending.isNotEmpty) {
          mapCtx.recordCancelled(pending.removeFirst(), 'Cancelled: dependency deadlock');
        }
        break;
      }

      if (inFlight.isEmpty) break;

      // Wait for any one in-flight iteration to complete.
      await Future.any(inFlight.values);

      // Budget check after each completion.
      final refreshedRun = await _repository.getById(run.id) ?? run;
      run = refreshedRun;
      if (_workflowBudgetExceeded(run, definition)) {
        mapCtx.budgetExhausted = true;
      }

      // Yield to event loop to prevent microtask starvation.
      await Future<void>.delayed(Duration.zero);
    }

    // 10. Wait for all remaining in-flight to settle.
    if (inFlight.isNotEmpty) {
      await Future.wait(inFlight.values, eagerError: false);
    }

    // Accumulate total tokens from context metadata keys.
    for (var i = 0; i < collection.length; i++) {
      final tokenKey = '${step.id}[$i].tokenCount';
      final t = context[tokenKey];
      if (t is int) totalTokens += t;
    }

    // 11. Fire MapStepCompletedEvent.
    _eventBus.fire(
      MapStepCompletedEvent(
        runId: run.id,
        stepId: step.id,
        stepName: step.name,
        totalIterations: collection.length,
        successCount: mapCtx.successCount,
        failureCount: mapCtx.failedIndices.length,
        cancelledCount: mapCtx.cancelledCount,
        totalTokens: totalTokens,
        timestamp: DateTime.now(),
      ),
    );

    // 12. Return result.
    if (mapCtx.hasFailures) {
      final failCount = mapCtx.failedIndices.length;
      return _MapStepResult(
        results: List<dynamic>.from(mapCtx.results),
        totalTokens: totalTokens,
        success: false,
        error: "Map step '${step.id}': $failCount iteration(s) failed",
      );
    }

    return _MapStepResult(results: List<dynamic>.from(mapCtx.results), totalTokens: totalTokens, success: true);
  }

  /// Executes a single map iteration: creates a task, awaits completion,
  /// extracts outputs, records result in [mapCtx], fires [MapIterationCompletedEvent].
  Future<void> _dispatchIteration({
    required WorkflowRun run,
    required WorkflowDefinition definition,
    required WorkflowStep step,
    required int stepIndex,
    required int iterIndex,
    required String iterPrompt,
    required String iterTitle,
    required Map<String, dynamic> taskConfig,
    required ResolvedStepConfig resolved,
    required MapStepContext mapCtx,
    required WorkflowContext context,
  }) async {
    final taskId = _uuid.v4();

    // Subscribe before create to avoid race condition.
    final completer = Completer<Task>();
    final sub = _eventBus.on<TaskStatusChangedEvent>().where((e) => e.taskId == taskId).listen((event) async {
      if (event.newStatus == TaskStatus.failed) {
        final t = await _taskService.get(taskId);
        if (t == null) return;
        if (t.status == TaskStatus.queued || t.status == TaskStatus.running) return;
        if (t.retryCount < t.maxRetries) return;
        if (!completer.isCompleted) completer.complete(t);
      } else if (event.newStatus.terminal) {
        if (!completer.isCompleted) {
          final t = await _taskService.get(taskId);
          if (t != null) completer.complete(t);
        }
      }
    });

    try {
      await _taskService.create(
        id: taskId,
        title: iterTitle,
        description: iterPrompt,
        type: _mapStepType(step.type),
        autoStart: true,
        provider: resolved.provider,
        maxTokens: resolved.maxTokens,
        maxRetries: resolved.maxRetries ?? 0,
        workflowRunId: run.id,
        stepIndex: stepIndex,
        configJson: taskConfig,
        trigger: 'workflow',
      );
    } catch (e, st) {
      await sub.cancel();
      _log.severe(
        "Workflow '${run.id}': map step '${step.id}' iteration $iterIndex "
        'failed to create task: $e',
        e,
        st,
      );
      mapCtx.recordFailure(iterIndex, 'Failed to create task: $e', null);
      mapCtx.inFlightCount--;
      _eventBus.fire(
        MapIterationCompletedEvent(
          runId: run.id,
          stepId: step.id,
          iterationIndex: iterIndex,
          totalIterations: mapCtx.collection.length,
          itemId: mapCtx.itemId(iterIndex),
          taskId: taskId,
          success: false,
          tokenCount: 0,
          timestamp: DateTime.now(),
        ),
      );
      return;
    }

    late Task finalTask;
    try {
      finalTask = await _waitForTaskCompletion(taskId, step, completer, sub);
    } on TimeoutException {
      _log.warning(
        "Workflow '${run.id}': map step '${step.id}' iteration $iterIndex "
        'timed out after ${step.timeoutSeconds}s',
      );
      mapCtx.recordFailure(iterIndex, 'Timed out after ${step.timeoutSeconds}s', taskId);
      mapCtx.inFlightCount--;
      _eventBus.fire(
        MapIterationCompletedEvent(
          runId: run.id,
          stepId: step.id,
          iterationIndex: iterIndex,
          totalIterations: mapCtx.collection.length,
          itemId: mapCtx.itemId(iterIndex),
          taskId: taskId,
          success: false,
          tokenCount: 0,
          timestamp: DateTime.now(),
        ),
      );
      return;
    } catch (e, st) {
      _log.severe(
        "Workflow '${run.id}': map step '${step.id}' iteration $iterIndex "
        'wait failed: $e',
        e,
        st,
      );
      mapCtx.recordFailure(iterIndex, 'Unexpected error: $e', taskId);
      mapCtx.inFlightCount--;
      _eventBus.fire(
        MapIterationCompletedEvent(
          runId: run.id,
          stepId: step.id,
          iterationIndex: iterIndex,
          totalIterations: mapCtx.collection.length,
          itemId: mapCtx.itemId(iterIndex),
          taskId: taskId,
          success: false,
          tokenCount: 0,
          timestamp: DateTime.now(),
        ),
      );
      return;
    }

    final taskFailed = finalTask.status == TaskStatus.failed || finalTask.status == TaskStatus.cancelled;

    int tokenCount = 0;
    if (!taskFailed) {
      tokenCount = await _readStepTokenCount(finalTask);
      Map<String, dynamic> outputs = {};
      try {
        outputs = await _contextExtractor.extract(step, finalTask);
      } catch (e, st) {
        _log.warning(
          "Workflow '${run.id}': context extraction failed for map step '${step.id}' "
          'iteration $iterIndex: $e',
          e,
          st,
        );
      }

      // Merge per-iteration outputs into context with indexed keys.
      for (final entry in outputs.entries) {
        context['${step.id}[$iterIndex].${entry.key}'] = entry.value;
      }
      context['${step.id}[$iterIndex].tokenCount'] = tokenCount;

      // Build result value.
      dynamic resultValue;
      if (step.type == 'coding') {
        resultValue = await _buildCodingResult(finalTask, outputs);
      } else if (outputs.length == 1) {
        resultValue = outputs.values.first;
      } else {
        resultValue = outputs;
      }

      mapCtx.recordResult(iterIndex, resultValue);
    } else {
      final reason = finalTask.configJson['failReason'] as String?;
      final msg = reason ?? finalTask.status.name;
      mapCtx.recordFailure(iterIndex, msg, taskId);
    }

    mapCtx.inFlightCount--;

    _eventBus.fire(
      MapIterationCompletedEvent(
        runId: run.id,
        stepId: step.id,
        iterationIndex: iterIndex,
        totalIterations: mapCtx.collection.length,
        itemId: mapCtx.itemId(iterIndex),
        taskId: taskId,
        success: !taskFailed,
        tokenCount: tokenCount,
        timestamp: DateTime.now(),
      ),
    );
  }

  /// Transitions the workflow run to paused and fires status changed event.
  Future<void> _pauseRun(WorkflowRun run, String reason) async {
    final paused = run.copyWith(status: WorkflowRunStatus.paused, errorMessage: reason, updatedAt: DateTime.now());
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
