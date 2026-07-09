part of 'workflow_executor.dart';

/// Outcome of running the loop controller.
///
/// Top-level loops only use [halted] (`true` ⇒ the run paused/cancelled/failed
/// and was already transitioned; `false` ⇒ the loop completed and the executor
/// should advance). Nested (foreach-owned) loops additionally use [converged]
/// vs [failureMessage] / [needsReviewReason] / [interrupted] to let the
/// enclosing foreach iteration record a per-item result without failing the
/// whole run, and [tokensConsumed] to attribute the loop body's tokens to
/// that iteration.
class WorkflowLoopExecutionResult {
  /// The run was paused/cancelled/failed and the caller must stop.
  final bool halted;

  /// The loop's exit (or entry-skip) gate was satisfied – a clean exit.
  final bool converged;

  /// Set when a nested loop ends without converging (max iterations reached or
  /// a body step failed); the enclosing foreach records the iteration failure.
  final String? failureMessage;

  /// Set when a nested loop exhausts and should pause for review instead of failing.
  final String? needsReviewReason;

  /// Set when a nested loop body task was cancelled and should resume from its checkpoint.
  final bool interrupted;

  /// Tokens consumed by the loop body, for per-iteration attribution.
  final int tokensConsumed;

  const WorkflowLoopExecutionResult({
    this.halted = false,
    this.converged = false,
    this.failureMessage,
    this.needsReviewReason,
    this.interrupted = false,
    this.tokensConsumed = 0,
  });
}

/// Per-iteration scope for a loop nested inside a `foreach` body.
///
/// The loop controller runs against the iteration's `iterContext`; resume
/// coordinates and a body-output snapshot are persisted into [runContext]
/// under `_loop.<loopId>.foreach.<foreachStepId>[<iterIndex>].*` (never the
/// global `_loop.current.*`), and [persist] flushes the enclosing foreach
/// progress so checkpoints survive after every body step.
class _NestedLoopScope {
  final String foreachStepId;
  final int iterIndex;

  /// IDs of all the enclosing foreach's children, for the foreach-scope budget basis.
  final List<String> childStepIds;
  final WorkflowContext runContext;
  final Future<void> Function() persist;
  final bool Function()? isCancelled;

  /// The enclosing foreach iteration's map context, so loop body tasks carry
  /// the item index (display grouping + per-item attribution).
  final MapContext? mapContext;

  /// The enclosing foreach controller's resolved `max_parallel`, so loop body
  /// steps resolve the same worktree scope (per-map-item) as sibling children.
  final int? enclosingMaxParallel;

  /// Records the enclosing foreach iteration's first task id for attribution.
  final void Function(String taskId)? onFirstTaskCreated;

  const _NestedLoopScope({
    required this.foreachStepId,
    required this.iterIndex,
    required this.childStepIds,
    required this.runContext,
    required this.persist,
    this.isCancelled,
    this.mapContext,
    this.enclosingMaxParallel,
    this.onFirstTaskCreated,
  });

  String keyBase(String loopId) => '_loop.$loopId.foreach.$foreachStepId[$iterIndex]';
}

/// Runs loop nodes, including checkpoints and optional finalizers.
extension WorkflowExecutorLoopStepRunner on WorkflowExecutor {
  /// Dispatches a `loop`-type child step of a `foreach` iteration.
  ///
  /// Runs the loop controller against the iteration's [iterContext] so review
  /// outputs and gate evaluation stay inside the iteration. Resume coordinates
  /// + a body snapshot are restored from [scope.runContext] before running.
  /// Returns a synthesized [StepOutcome] (no review outputs leak; the loop step
  /// declares no `outputs:`), or `null` when the run was halted (cancel/pause).
  Future<StepOutcome?> _executeNestedLoopStep(
    WorkflowRun run,
    WorkflowDefinition definition,
    WorkflowStep loopStep,
    WorkflowContext iterContext, {
    required _NestedLoopScope scope,
    required String? activeWorkspaceRoot,
  }) async {
    final loop = definition.loops.firstWhere(
      (l) => l.id == loopStep.id,
      orElse: () => throw StateError('Foreach-nested loop "${loopStep.id}" missing from definition snapshot'),
    );
    final base = scope.keyBase(loop.id);
    final startIteration = (scope.runContext['$base.iteration'] as int?) ?? 1;
    final startStepId = scope.runContext['$base.stepId'] as String?;
    final startTokens = (scope.runContext['$base.tokens'] as int?) ?? 0;
    // Restore completed body-step outputs of an in-flight iteration so a
    // resumed re-review step sees the prior remediation outputs.
    final snapshot = scope.runContext['$base.iterData'];
    if (snapshot is Map) {
      snapshot.forEach((key, value) => iterContext['$key'] = value);
    }

    final result = await _executeLoop(
      run,
      definition,
      loop,
      iterContext,
      activeWorkspaceRoot: activeWorkspaceRoot,
      isCancelled: scope.isCancelled,
      startFromIteration: startIteration,
      startFromStepId: startStepId,
      startFromTokens: startTokens,
      onRunUpdated: (_) {},
      nested: scope,
    );

    if (result.halted) return null;
    if (result.converged) {
      return StepOutcome(
        step: loopStep,
        task: null,
        outputs: const {},
        tokenCount: result.tokensConsumed,
        success: true,
        outcome: 'completed',
      );
    }
    if (result.interrupted) {
      return StepOutcome(
        step: loopStep,
        task: null,
        outputs: const {},
        tokenCount: result.tokensConsumed,
        success: false,
        outcome: 'cancelled',
        outcomeReason: 'Nested loop interrupted by cancelled body task; resume re-runs the cancelled step.',
      );
    }
    if (result.needsReviewReason != null) {
      _clearNestedLoopCheckpoint(scope, loop);
      await scope.persist();
      return StepOutcome(
        step: loopStep,
        task: null,
        outputs: const {},
        tokenCount: result.tokensConsumed,
        success: false,
        error: result.needsReviewReason,
        outcome: 'needsInput',
        outcomeReason: result.needsReviewReason,
        requiresDependencyHold: true,
      );
    }
    // Non-converged: drop the per-iteration resume snapshot so no nested-loop
    // state survives the (failed) iteration.
    _clearNestedLoopCheckpoint(scope, loop);
    await scope.persist();
    return StepOutcome(
      step: loopStep,
      task: null,
      outputs: const {},
      tokenCount: result.tokensConsumed,
      success: false,
      error: result.failureMessage,
      outcome: 'failed',
      outcomeReason: result.failureMessage,
    );
  }

  void _writeNestedLoopCheckpoint(
    _NestedLoopScope scope,
    WorkflowLoop loop,
    WorkflowContext iterContext, {
    required int iteration,
    required String? nextStepId,
    required int tokens,
  }) {
    final base = scope.keyBase(loop.id);
    scope.runContext['$base.iteration'] = iteration;
    scope.runContext['$base.stepId'] = nextStepId;
    scope.runContext['$base.tokens'] = tokens;
    scope.runContext['$base.iterData'] = Map<String, dynamic>.from(iterContext.data);
  }

  void _clearNestedLoopCheckpoint(_NestedLoopScope scope, WorkflowLoop loop) {
    final base = scope.keyBase(loop.id);
    scope.runContext.remove('$base.iteration');
    scope.runContext.remove('$base.stepId');
    scope.runContext.remove('$base.tokens');
    scope.runContext.remove('$base.iterData');
  }

  Future<WorkflowLoopExecutionResult> _executeLoop(
    WorkflowRun run,
    WorkflowDefinition definition,
    WorkflowLoop loop,
    WorkflowContext context, {
    required String? activeWorkspaceRoot,
    bool Function()? isCancelled,
    int startFromIteration = 1,
    String? startFromStepId,
    int startFromTokens = 0,
    required void Function(WorkflowRun) onRunUpdated,
    _NestedLoopScope? nested,
  }) async {
    var loopTokens = startFromTokens;
    var gatePassed = false;
    var resumeStepId = startFromStepId;
    final loopStartStepId = loop.steps.first;
    final loopStartStepIndex = definition.steps.indexWhere((step) => step.id == loopStartStepId);

    // Top-level loops fail the whole run; a nested loop reports the failure up
    // so the enclosing foreach iteration records it without failing the run.
    Future<WorkflowLoopExecutionResult> failLoop(String message) async {
      if (nested == null) {
        await _failRun(run, message);
        return WorkflowLoopExecutionResult(halted: true, tokensConsumed: loopTokens);
      }
      return WorkflowLoopExecutionResult(failureMessage: message, tokensConsumed: loopTokens);
    }

    Future<String?> runLoopFinalizer() async {
      if (loop.finally_ == null) return null;
      final (updatedRun, finalizerMsg) = await _executeLoopFinalizer(
        run,
        definition,
        loop,
        context,
        activeWorkspaceRoot: activeWorkspaceRoot,
        onRunUpdated: onRunUpdated,
        onFirstTaskCreated: nested?.onFirstTaskCreated,
      );
      run = updatedRun;
      return finalizerMsg;
    }

    Future<WorkflowLoopExecutionResult> Function()? pendingLoopExit;
    var finalizeBeforeConverged = false;

    iterationLoop:
    for (var iteration = startFromIteration; iteration <= loop.maxIterations; iteration++) {
      if (isCancelled?.call() ?? false) {
        WorkflowExecutor._log.info("Workflow '${run.id}' cancelled during loop '${loop.id}'");
        return WorkflowLoopExecutionResult(halted: true, tokensConsumed: loopTokens);
      }

      context.setLoopIteration(loop.id, iteration);
      if (nested == null) {
        run = run.copyWith(
          executionCursor: WorkflowExecutionCursor.loop(
            loopId: loop.id,
            stepIndex: loopStartStepIndex >= 0 ? loopStartStepIndex : 0,
            iteration: iteration,
            stepId: resumeStepId,
          ),
          contextJson: {
            ...run.contextJson,
            '_loop.current.id': loop.id,
            '_loop.current.iteration': iteration,
            if (resumeStepId == null) '_loop.current.stepId': null,
          },
          updatedAt: DateTime.now(),
        );
        await _repository.update(run);
        onRunUpdated(run);
      } else {
        _writeNestedLoopCheckpoint(
          nested,
          loop,
          context,
          iteration: iteration,
          nextStepId: resumeStepId,
          tokens: loopTokens,
        );
        await nested.persist();
      }

      final entryGate = loop.entryGate?.trim();
      if (entryGate != null && entryGate.isNotEmpty && !_gateEvaluator.evaluate(entryGate, context)) {
        gatePassed = true;
        WorkflowExecutor._log.info("Loop '${loop.id}' skipped: entry gate failed before iteration $iteration");
        // A top-level loop that never enters leaves its body steps with no task
        // and no outcome marker — indistinguishable from "not started" to the
        // digest/UI observers that read `step.<id>.outcome`. Mark them skipped
        // (mirroring step-level entryGate skips) so the shared status mapper
        // renders them as skipped with the gate as the reason. Guarded to the
        // genuine never-entered case: top-level only (a nested loop must not
        // leak body keys to run context), the very first iteration, and not a
        // mid-iteration resume — a later-iteration gate-false is a convergence
        // exit whose body steps already ran.
        if (nested == null && iteration == 1 && resumeStepId == null) {
          for (final bodyStepId in loop.steps) {
            context['step.$bodyStepId.outcome'] = 'skipped';
            context['step.$bodyStepId.outcome.reason'] = entryGate;
          }
        }
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
        finalizeBeforeConverged = true;
        break;
      }

      for (var loopStepIndex = 0; loopStepIndex < loop.steps.length; loopStepIndex++) {
        final stepId = loop.steps[loopStepIndex];
        if (resumeStepId != null && stepId != resumeStepId) {
          WorkflowExecutor._log.fine(
            "Workflow '${run.id}': skipping completed loop step '$stepId' "
            "(resuming from '$resumeStepId')",
          );
          continue;
        }
        resumeStepId = null;

        if (isCancelled?.call() ?? false) {
          WorkflowExecutor._log.info("Workflow '${run.id}' cancelled in loop '${loop.id}' iter $iteration");
          return WorkflowLoopExecutionResult(halted: true, tokensConsumed: loopTokens);
        }

        final step = definition.steps.firstWhere((s) => s.id == stepId);
        final stepIndex = definition.steps.indexOf(step);

        if (step.parallel) {
          WorkflowExecutor._log.warning(
            "Step '${step.id}' has parallel:true but is inside loop '${loop.id}' — "
            'executing sequentially (parallel flag ignored in loops)',
          );
        }

        final skippedRun = await _skipDueToEntryGate(run, step, stepIndex, context);
        if (skippedRun != null) {
          run = skippedRun;
          onRunUpdated(run);
          continue;
        }

        if (step.gate != null) {
          final gatePasses = _gateEvaluator.evaluate(step.gate!, context);
          if (!gatePasses) {
            final msg = "Gate failed in loop '${loop.id}' iteration $iteration: ${step.gate}";
            WorkflowExecutor._log.info("Workflow '${run.id}': $msg");
            return failLoop(msg);
          }
        }

        final refreshedRun = await _repository.getById(run.id) ?? run;
        run = refreshedRun;
        onRunUpdated(run);
        // A nested loop's body tokens – and all other foreach-scope tokens
        // (settled iterations, sibling in-flight children, this iteration's
        // pre-loop children) – reach run.totalTokens only when the enclosing
        // foreach completes, so the budget check and warning add them via the
        // evaluation-only additionalTokens basis; the run object itself stays
        // un-inflated (persisting the sum would double-count at foreach
        // completion). The scope sum excludes this loop's own checkpoint and
        // any stale prior-attempt tokenCount – both superseded by loopTokens.
        final budgetBasisTokens = nested == null
            ? 0
            : loopTokens +
                  workflow_budget_monitor.foreachScopeConsumedTokens(
                    nested.runContext.data,
                    foreachStepId: nested.foreachStepId,
                    childStepIds: nested.childStepIds,
                    excludeKeys: {'${nested.keyBase(loop.id)}.tokens', '${loop.id}[${nested.iterIndex}].tokenCount'},
                  );
        run = await _checkWorkflowBudgetWarning(run, definition, additionalTokens: budgetBasisTokens);
        onRunUpdated(run);
        if (_workflowBudgetExceeded(run, definition, additionalTokens: budgetBasisTokens)) {
          final msg = "Workflow budget exceeded during loop '${loop.id}'";
          WorkflowExecutor._log.info("Workflow '${run.id}': $msg");
          return failLoop(msg);
        }

        if (nested == null) {
          run = run.copyWith(
            executionCursor: WorkflowExecutionCursor.loop(
              loopId: loop.id,
              stepIndex: stepIndex,
              iteration: iteration,
              stepId: stepId,
            ),
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
        } else {
          _writeNestedLoopCheckpoint(
            nested,
            loop,
            context,
            iteration: iteration,
            nextStepId: stepId,
            tokens: loopTokens,
          );
          await nested.persist();
        }

        final result = await _executeStep(
          run,
          definition,
          step,
          context,
          activeWorkspaceRoot: activeWorkspaceRoot,
          stepIndex: stepIndex,
          loopId: loop.id,
          loopIteration: iteration,
          mapCtx: nested?.mapContext,
          enclosingMaxParallel: nested?.enclosingMaxParallel,
          onFirstTaskCreated: nested?.onFirstTaskCreated,
          // A nested loop never promotes mid-body: the enclosing foreach
          // iteration owns promotion after the loop converges.
          promoteAfterSuccess: nested != null
              ? false
              : _isLastBranchTouchingStepInScope(
                  definition,
                  step,
                  loop.steps
                      .skip(loopStepIndex + 1)
                      .map((id) => definition.steps.firstWhere((candidate) => candidate.id == id)),
                ),
        );
        if (result == null) return WorkflowLoopExecutionResult(halted: true, tokensConsumed: loopTokens);
        loopTokens += result.tokenCount;

        if (!result.success) {
          final failMsg = "Loop '${loop.id}' step '${step.name}' failed in iteration $iteration";
          WorkflowExecutor._log.info("Workflow '${run.id}': $failMsg");

          // Teardown interruption is checked before `onError: continue` (and
          // every other policy branch): continuing would dispatch the next
          // task mid-teardown. Keep the pre-step checkpoint/cursor (written
          // above, before _executeStep): it already points at this step with
          // the pre-step token total, so resume re-runs the cancelled step
          // fresh and its partial attempt is not charged – consistent with the
          // crash-resume path.
          if (result.outcome == 'cancelled') {
            WorkflowExecutor._log.info(
              "Workflow '${run.id}': loop '${loop.id}' interrupted by cancelled step '${step.id}' "
              'in iteration $iteration',
            );
            if (nested != null) {
              // The foreach cancelled branch drops the per-child tokenCount
              // key, so the checkpoint stays the single budget source
              // (never-overlap invariant).
              return WorkflowLoopExecutionResult(interrupted: true, tokensConsumed: loopTokens);
            }
            // Persist the outcome and fire the step event before pausing so
            // observers (digest, live console) classify the step interrupted,
            // matching the plain-step and foreach scopes.
            _mergeStepResultIntoContext(context, result, fallbackStatus: 'cancelled');
            run = run.copyWith(
              contextJson: {...privateContextEntries(run.contextJson), ...context.toJson()},
              updatedAt: DateTime.now(),
            );
            await _persistContext(run.id, context);
            await _repository.update(run);
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
                outcome: result.outcome,
                reason: result.outcomeReason,
                tokenCount: result.tokenCount,
                timestamp: DateTime.now(),
              ),
            );
            await _pauseRun(
              run,
              "Step '${step.id}' was interrupted by task cancellation; resume re-runs it from its checkpoint.",
            );
            return WorkflowLoopExecutionResult(halted: true, tokensConsumed: loopTokens);
          }

          if (step.onError == OnErrorPolicy.continueWorkflow) {
            _mergeStepResultIntoContext(context, result, fallbackStatus: 'failed');
            final nextLoopStepId = loopStepIndex + 1 < loop.steps.length ? loop.steps[loopStepIndex + 1] : null;
            if (nested == null) {
              run = run.copyWith(totalTokens: run.totalTokens + result.tokenCount, updatedAt: DateTime.now());
              final nextLoopStepIndex = nextLoopStepId == null
                  ? (loopStartStepIndex >= 0 ? loopStartStepIndex : stepIndex)
                  : definition.steps.indexWhere((candidate) => candidate.id == nextLoopStepId);
              run = await _persistLoopStepCheckpoint(
                run,
                context,
                loopId: loop.id,
                iteration: iteration,
                nextStepId: nextLoopStepId,
                nextStepIndex: nextLoopStepIndex >= 0 ? nextLoopStepIndex : stepIndex,
              );
              onRunUpdated(run);
            } else {
              _writeNestedLoopCheckpoint(
                nested,
                loop,
                context,
                iteration: iteration,
                nextStepId: nextLoopStepId,
                tokens: loopTokens,
              );
              await nested.persist();
            }
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
            if (isCancelled?.call() ?? false) {
              WorkflowExecutor._log.info(
                "Workflow '${run.id}' cancelled in loop '${loop.id}' iter $iteration after step '${step.id}'",
              );
              return WorkflowLoopExecutionResult(halted: true, tokensConsumed: loopTokens);
            }
            continue;
          }

          if (result.awaitingApproval) {
            pendingLoopExit = () async {
              run = await _transitionStepAwaitingApproval(
                run,
                step,
                context,
                stepIndex: stepIndex,
                reason: result.outcomeReason ?? failMsg,
              );
              return WorkflowLoopExecutionResult(halted: true, tokensConsumed: loopTokens);
            };
          } else {
            pendingLoopExit = () => failLoop(failMsg);
          }
          break iterationLoop;
        }

        _mergeStepResultIntoContext(context, result, fallbackStatus: result.task?.status.name ?? 'completed');
        final nextLoopStepId = loopStepIndex + 1 < loop.steps.length ? loop.steps[loopStepIndex + 1] : null;
        if (nested == null) {
          run = run.copyWith(totalTokens: run.totalTokens + result.tokenCount, updatedAt: DateTime.now());
          final nextLoopStepIndex = nextLoopStepId == null
              ? (loopStartStepIndex >= 0 ? loopStartStepIndex : stepIndex)
              : definition.steps.indexWhere((candidate) => candidate.id == nextLoopStepId);
          run = await _persistLoopStepCheckpoint(
            run,
            context,
            loopId: loop.id,
            iteration: iteration,
            nextStepId: nextLoopStepId,
            nextStepIndex: nextLoopStepIndex >= 0 ? nextLoopStepIndex : stepIndex,
          );
          onRunUpdated(run);
        } else {
          _writeNestedLoopCheckpoint(
            nested,
            loop,
            context,
            iteration: iteration,
            nextStepId: nextLoopStepId,
            tokens: loopTokens,
          );
          await nested.persist();
        }

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

        if (isCancelled?.call() ?? false) {
          WorkflowExecutor._log.info(
            "Workflow '${run.id}' cancelled in loop '${loop.id}' iter $iteration after step '${step.id}'",
          );
          return WorkflowLoopExecutionResult(halted: true, tokensConsumed: loopTokens);
        }
      }

      if (_gateEvaluator.evaluate(loop.exitGate, context)) {
        gatePassed = true;
        WorkflowExecutor._log.info("Loop '${loop.id}' completed: exit gate passed at iteration $iteration");
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
        finalizeBeforeConverged = true;
        break;
      }

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

      if (nested == null) {
        await _persistContext(run.id, context);
        run = run.copyWith(contextJson: context.toJson(), updatedAt: DateTime.now());
        await _repository.update(run);
        onRunUpdated(run);
      } else {
        // Advance the checkpoint to the next iteration's first step; the
        // foreach persist flushes the run-level context.
        _writeNestedLoopCheckpoint(
          nested,
          loop,
          context,
          iteration: iteration + 1,
          nextStepId: null,
          tokens: loopTokens,
        );
        await nested.persist();
      }
    }

    if (!gatePassed && pendingLoopExit == null) {
      // A top-level loop with `onMaxIterations: continue` advances to the next
      // step (e.g. a deterministic verify gate) rather than failing the run, so
      // it also persists the loop body's outputs for that step; `fail` only
      // clears the cursor before failLoop. Nested loops can opt into
      // `escalate`, which records a recoverable blocked item for review.
      final fallThroughOnExhaustion = loop.onMaxIterations == WorkflowLoop.onMaxIterationsContinue && nested == null;
      final escalateOnExhaustion = loop.onMaxIterations == WorkflowLoop.onMaxIterationsEscalate && nested != null;
      if (nested == null) {
        run = run.copyWith(
          executionCursor: null,
          contextJson: {
            for (final e in run.contextJson.entries)
              if (!e.key.startsWith('_loop.current')) e.key: e.value,
            if (fallThroughOnExhaustion) ...context.toJson(),
          },
          updatedAt: DateTime.now(),
        );
        if (fallThroughOnExhaustion) await _persistContext(run.id, context);
        await _repository.update(run);
        onRunUpdated(run);
      }

      pendingLoopExit = () async {
        if (fallThroughOnExhaustion) {
          WorkflowExecutor._log.info(
            "Workflow '${run.id}': loop '${loop.id}' reached max iterations (${loop.maxIterations}); "
            'onMaxIterations=continue – advancing to the next step.',
          );
          return WorkflowLoopExecutionResult(converged: true, tokensConsumed: loopTokens);
        }

        final baseMsg =
            "Loop '${loop.id}' reached max iterations (${loop.maxIterations}). "
            'Exit condition not met: ${loop.exitGate}';
        if (escalateOnExhaustion) {
          final residual = _loopResidualFindingsDetail(context);
          final msg = residual == null ? baseMsg : '$baseMsg $residual';
          WorkflowExecutor._log.info(
            "Workflow '${run.id}': $msg; onMaxIterations=escalate – recording needsInput for review.",
          );
          return WorkflowLoopExecutionResult(needsReviewReason: msg, tokensConsumed: loopTokens);
        }
        WorkflowExecutor._log.info("Workflow '${run.id}': $baseMsg");
        return failLoop(baseMsg);
      };
    }

    if (pendingLoopExit != null || finalizeBeforeConverged) {
      final finalizerMsg = await runLoopFinalizer();
      if (finalizerMsg != null) {
        return failLoop(finalizerMsg);
      }
      if (pendingLoopExit != null) return pendingLoopExit();
    }

    if (nested == null) {
      run = run.copyWith(
        executionCursor: null,
        contextJson: {
          for (final e in run.contextJson.entries)
            if (!e.key.startsWith('_loop.current')) e.key: e.value,
          ...context.toJson(),
        },
        updatedAt: DateTime.now(),
      );
      await _repository.update(run);
      onRunUpdated(run);
    } else {
      // Converged: drop the per-iteration resume coordinates + snapshot so no
      // nested-loop state (and no bare review keys) survives the iteration.
      _clearNestedLoopCheckpoint(nested, loop);
      await nested.persist();
    }

    return WorkflowLoopExecutionResult(converged: true, tokensConsumed: loopTokens);
  }

  Future<WorkflowRun> _persistLoopStepCheckpoint(
    WorkflowRun run,
    WorkflowContext context, {
    required String loopId,
    required int iteration,
    required String? nextStepId,
    required int nextStepIndex,
  }) async {
    final updatedRun = run.copyWith(
      executionCursor: WorkflowExecutionCursor.loop(
        loopId: loopId,
        stepIndex: nextStepIndex,
        iteration: iteration,
        stepId: nextStepId,
      ),
      contextJson: {
        ...privateContextEntries(run.contextJson, exclude: '_map.current'),
        ...context.toJson(),
        '_loop.current.id': loopId,
        '_loop.current.iteration': iteration,
        '_loop.current.stepId': nextStepId,
      },
      updatedAt: DateTime.now(),
    );
    await _persistContext(run.id, context);
    await _repository.update(updatedRun);
    return updatedRun;
  }

  Future<(WorkflowRun, String?)> _executeLoopFinalizer(
    WorkflowRun run,
    WorkflowDefinition definition,
    WorkflowLoop loop,
    WorkflowContext context, {
    required String? activeWorkspaceRoot,
    required void Function(WorkflowRun) onRunUpdated,
    void Function(String taskId)? onFirstTaskCreated,
  }) async {
    final finallyStepId = loop.finally_!;
    final finallyStep = definition.steps.firstWhere((s) => s.id == finallyStepId);
    final stepIndex = definition.steps.indexOf(finallyStep);

    WorkflowExecutor._log.info("Workflow '${run.id}': executing finalizer '${finallyStep.id}' for loop '${loop.id}'");
    final result = await _executeStep(
      run,
      definition,
      finallyStep,
      context,
      activeWorkspaceRoot: activeWorkspaceRoot,
      stepIndex: stepIndex,
      onFirstTaskCreated: onFirstTaskCreated,
    );
    if (result == null) {
      return (run, null);
    }

    if (!result.success) {
      // Deliberately includes teardown-cancelled finalizers: a finalizer has
      // no resume anchor, so a clear loop failure beats a silently skipped
      // finalizer. On the exhaustion path this also means a failing finalizer
      // wins over `onMaxIterations: escalate`/`continue` – the caller routes
      // finalizerMsg to failLoop before the escalate/fall-through branches.
      final msg = "Loop '${loop.id}' finalizer '${finallyStep.name}' failed";
      WorkflowExecutor._log.info("Workflow '${run.id}': $msg");
      return (run, msg);
    }

    _mergeStepResultIntoContext(context, result, fallbackStatus: result.task?.status.name ?? 'completed');
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
}

/// Builds the residual-findings sentence for an escalated loop's pause reason.
///
/// `gating_findings_count` carries the residual measure; `review_report_path` is
/// a review-report *path* (key-per-concept convention), so it is labeled as a
/// report pointer, never as findings prose. Both live in the loop's
/// iteration context for the built-in remediation loops; custom loops
/// without these keys get the bare exhaustion message.
String? _loopResidualFindingsDetail(WorkflowContext context) {
  final rawCount = context['gating_findings_count'];
  final count = rawCount is int ? rawCount : int.tryParse('$rawCount');
  final rawPath = context['review_report_path'];
  final path = rawPath is String && rawPath.trim().isNotEmpty ? _sanitizeAgentReportedText(rawPath) : null;
  final countText = count != null && count > 0 ? '$count gating finding${count == 1 ? ' remains' : 's remain'}' : null;
  if (countText == null && path == null) return null;
  if (countText == null) return 'Residual findings report: $path';
  if (path == null) return '$countText.';
  return '$countText; report: $path';
}
