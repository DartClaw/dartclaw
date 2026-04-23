part of 'workflow_executor.dart';

/// Uniform runner signature for loop nodes.
Future<StepOutcome> loopRun(LoopNode node, StepExecutionContext ctx) async {
  throw UnsupportedError('loopRun is coordinated by WorkflowExecutor for cursor and terminal-state ownership.');
}

/// Runs loop nodes, including checkpoints and optional finalizers.
extension WorkflowExecutorLoopStepRunner on WorkflowExecutor {
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
    var resumeStepId = startFromStepId;
    final loopStartStepId = loop.steps.first;
    final loopStartStepIndex = definition.steps.indexWhere((step) => step.id == loopStartStepId);

    for (var iteration = startFromIteration; iteration <= loop.maxIterations; iteration++) {
      if (isCancelled?.call() ?? false) {
        WorkflowExecutor._log.info("Workflow '${run.id}' cancelled during loop '${loop.id}'");
        return true;
      }

      context.setLoopIteration(loop.id, iteration);
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

      final entryGate = loop.entryGate?.trim();
      if (entryGate != null && entryGate.isNotEmpty && !_gateEvaluator.evaluate(entryGate, context)) {
        gatePassed = true;
        WorkflowExecutor._log.info("Loop '${loop.id}' skipped: entry gate failed before iteration $iteration");
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
            await _failRun(run, finalizerMsg);
            return true;
          }
        }
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
          return true;
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
            await _failRun(run, msg);
            return true;
          }
        }

        final refreshedRun = await _repository.getById(run.id) ?? run;
        run = refreshedRun;
        onRunUpdated(run);
        run = await _checkWorkflowBudgetWarning(run, definition);
        onRunUpdated(run);
        if (_workflowBudgetExceeded(run, definition)) {
          final msg = "Workflow budget exceeded during loop '${loop.id}'";
          WorkflowExecutor._log.info("Workflow '${run.id}': $msg");
          await _failRun(run, msg);
          return true;
        }

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

        final result = await _executeStep(
          run,
          definition,
          step,
          context,
          stepIndex: stepIndex,
          loopId: loop.id,
          loopIteration: iteration,
          promoteAfterSuccess: _isLastBranchTouchingStepInScope(
            definition,
            step,
            loop.steps
                .skip(loopStepIndex + 1)
                .map((id) => definition.steps.firstWhere((candidate) => candidate.id == id)),
          ),
        );
        if (result == null) return true;

        if (!result.success) {
          final failMsg = "Loop '${loop.id}' step '${step.name}' failed in iteration $iteration";
          WorkflowExecutor._log.info("Workflow '${run.id}': $failMsg");

          if (step.onError == 'continue') {
            _mergeStepResultIntoContext(context, result, fallbackStatus: 'failed');
            run = run.copyWith(totalTokens: run.totalTokens + result.tokenCount, updatedAt: DateTime.now());
            final nextLoopStepId = loopStepIndex + 1 < loop.steps.length ? loop.steps[loopStepIndex + 1] : null;
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
              return true;
            }
            continue;
          }

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
              await _failRun(run, finalizerMsg);
              return true;
            }
          }
          if (result.awaitingApproval) {
            run = await _transitionStepAwaitingApproval(
              run,
              step,
              context,
              stepIndex: stepIndex,
              reason: result.outcomeReason ?? failMsg,
            );
            return true;
          }
          await _failRun(run, failMsg);
          return true;
        }

        _mergeStepResultIntoContext(context, result, fallbackStatus: result.task?.status.name ?? 'completed');
        run = run.copyWith(totalTokens: run.totalTokens + result.tokenCount, updatedAt: DateTime.now());
        final nextLoopStepId = loopStepIndex + 1 < loop.steps.length ? loop.steps[loopStepIndex + 1] : null;
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
          return true;
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
            await _failRun(run, finalizerMsg);
            return true;
          }
        }
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

      await _persistContext(run.id, context);
      run = run.copyWith(contextJson: context.toJson(), updatedAt: DateTime.now());
      await _repository.update(run);
      onRunUpdated(run);
    }

    if (!gatePassed) {
      run = run.copyWith(
        executionCursor: null,
        contextJson: {
          for (final e in run.contextJson.entries)
            if (!e.key.startsWith('_loop.current')) e.key: e.value,
        },
        updatedAt: DateTime.now(),
      );
      await _repository.update(run);
      onRunUpdated(run);

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
          await _failRun(run, finalizerMsg);
          return true;
        }
      }

      final msg =
          "Loop '${loop.id}' reached max iterations (${loop.maxIterations}). "
          'Exit condition not met: ${loop.exitGate}';
      WorkflowExecutor._log.info("Workflow '${run.id}': $msg");
      await _failRun(run, msg);
      return true;
    }

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

    return false;
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
        for (final e in run.contextJson.entries)
          if (e.key.startsWith('_') && !e.key.startsWith('_map.current')) e.key: e.value,
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
    required void Function(WorkflowRun) onRunUpdated,
  }) async {
    final finallyStepId = loop.finally_!;
    final finallyStep = definition.steps.firstWhere((s) => s.id == finallyStepId);
    final stepIndex = definition.steps.indexOf(finallyStep);

    WorkflowExecutor._log.info("Workflow '${run.id}': executing finalizer '${finallyStep.id}' for loop '${loop.id}'");
    final result = await _executeStep(run, definition, finallyStep, context, stepIndex: stepIndex);
    if (result == null) {
      return (run, null);
    }

    if (!result.success) {
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
