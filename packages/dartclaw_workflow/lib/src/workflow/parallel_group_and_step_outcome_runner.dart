part of 'workflow_executor.dart';

/// Runs parallel workflow groups and shared step-outcome merge helpers.
extension WorkflowExecutorParallelAndOutcomeRunner on WorkflowExecutor {
  Future<List<StepOutcome>> _executeParallelGroup(
    WorkflowRun run,
    WorkflowDefinition definition,
    List<WorkflowStep> group,
    WorkflowContext context, {
    required String? activeWorkspaceRoot,
    bool Function()? isCancelled,
  }) async {
    if (isCancelled?.call() ?? false) return [];
    final futures = group.map((step) async {
      try {
        final stepIndex = definition.steps.indexOf(step);
        final result = await _executeStep(
          run,
          definition,
          step,
          context,
          activeWorkspaceRoot: activeWorkspaceRoot,
          stepIndex: stepIndex,
        );
        if (result == null) {
          return StepOutcome(
            step: step,
            outputs: const {},
            tokenCount: 0,
            success: false,
            error: 'step did not complete',
          );
        }
        return result;
      } catch (e, st) {
        WorkflowExecutor._log.severe("Parallel step '${step.name}' failed: $e", e, st);
        return StepOutcome(step: step, outputs: {}, tokenCount: 0, success: false, error: e.toString());
      }
    }).toList();

    return Future.wait(futures);
  }

  void _mergeParallelResults(List<StepOutcome> results, WorkflowContext context) {
    for (final result in results) {
      _mergeStepResultIntoContext(
        context,
        result,
        fallbackStatus: result.success
            ? (result.task?.status.name ?? 'unknown')
            : (result.outcome == 'cancelled' ? 'cancelled' : 'failed'),
      );
    }
  }

  WorkflowRun _updateParallelBudget(WorkflowRun run, List<StepOutcome> results) {
    // Interrupted members' partial attempts stay uncharged: the pause path
    // re-runs them on resume, so charging here would double-count – consistent
    // with the plain-step, loop, and map interruption seams.
    final total = results.fold(0, (sum, r) => sum + (r.outcome == 'cancelled' ? 0 : r.tokenCount));
    return run.copyWith(totalTokens: run.totalTokens + total, updatedAt: DateTime.now());
  }

  void _mergeStepResultIntoContext(WorkflowContext context, StepOutcome result, {String? fallbackStatus}) {
    context.merge(result.outputs);
    final stepId = result.step.id;
    if (!result.outputs.containsKey('$stepId.status') && fallbackStatus != null) {
      context['$stepId.status'] = fallbackStatus;
    }
    if (!result.outputs.containsKey('$stepId.tokenCount')) {
      context['$stepId.tokenCount'] = result.tokenCount;
    }
    if (result.outcome != null) {
      context['step.$stepId.outcome'] = result.outcome!;
    }
    if (result.outcomeReason != null && result.outcomeReason!.isNotEmpty) {
      context['step.$stepId.outcome.reason'] = result.outcomeReason!;
    }
    final stepSessionId = result.task?.sessionId;
    if (stepSessionId != null) {
      context['$stepId.sessionId'] = stepSessionId;
    }
  }

  String? _fallbackOutcomeFromTaskStatus(TaskStatus? status) => switch (status) {
    TaskStatus.accepted => 'succeeded',
    TaskStatus.failed || TaskStatus.rejected => 'failed',
    // Run-teardown interruption is a first-class outcome, never a failure:
    // every controller maps it to its interrupted/pause seam so the step
    // stays resumable. Agents cannot claim it – the <step-outcome> whitelist
    // (workflow_output_contract.dart) rejects 'cancelled', so this engine-side
    // mapping is its only producer.
    TaskStatus.cancelled => 'cancelled',
    _ => null,
  };

  Future<(String?, String?)> _resolveStepOutcome(WorkflowStep step, Task task, {required String runId}) async {
    final parsed = await _contextExtractor.extractStepOutcome(task);
    final forcedOutcome = _fallbackOutcomeFromTaskStatus(task.status);
    if (forcedOutcome == 'failed' || forcedOutcome == 'cancelled') {
      if (parsed != null && parsed.outcome != forcedOutcome) {
        WorkflowExecutor._log.warning(
          "Workflow step '${step.id}' reported outcome '${parsed.outcome}' but task ${task.id} "
          'finished with terminal status ${task.status.name}; overriding to $forcedOutcome',
        );
      }
      final failReason =
          (task.configJson['failReason'] as String?) ?? (task.configJson['errorSummary'] as String?) ?? parsed?.reason;
      return (forcedOutcome, failReason ?? task.status.name);
    }
    if (parsed != null) {
      return (parsed.outcome, parsed.reason);
    }

    final fallbackOutcome = forcedOutcome;
    if (fallbackOutcome == null) {
      return (null, null);
    }

    await _incrementOutcomeFallbackCounter();
    // ADR-022: warn when a non-emitsOwnOutcome step has no <step-outcome> marker.
    WorkflowExecutor._log.warning(
      'Step outcome marker missing: run=$runId step=${step.id} '
      '(task ${task.id}, task status ${task.status.name})',
    );
    final failReason = task.configJson['failReason'] as String?;
    return (fallbackOutcome, failReason ?? task.status.name);
  }

  Future<void> _incrementOutcomeFallbackCounter() async {
    const key = 'workflow.outcome.fallback';
    final current = await _kvService.get(key);
    final next = (int.tryParse(current ?? '') ?? 0) + 1;
    await _kvService.set(key, next.toString());
  }

  Future<WorkflowRun> _transitionStepAwaitingApproval(
    WorkflowRun run,
    WorkflowStep step,
    WorkflowContext context, {
    required int stepIndex,
    required String reason,
  }) async {
    final requestedAt = DateTime.now().toIso8601String();
    context['${step.id}.approval.status'] = 'pending';
    context['${step.id}.approval.message'] = reason;
    context['${step.id}.approval.requested_at'] = requestedAt;

    final awaitingApprovalRun = run.copyWith(
      status: WorkflowRunStatus.awaitingApproval,
      errorMessage: reason,
      currentStepIndex: stepIndex + 1,
      contextJson: {
        ...privateContextEntries(run.contextJson),
        ...context.toJson(),
        '${step.id}.approval.status': 'pending',
        '${step.id}.approval.message': reason,
        '${step.id}.approval.requested_at': requestedAt,
        '_approval.pending.stepId': step.id,
        '_approval.pending.stepIndex': stepIndex,
      },
      updatedAt: DateTime.now(),
    );
    await _persistContext(run.id, context);
    await _repository.update(awaitingApprovalRun);
    _eventBus.fire(
      WorkflowApprovalRequestedEvent(
        runId: run.id,
        stepId: step.id,
        message: reason,
        timeoutSeconds: step.timeoutSeconds,
        timestamp: DateTime.now(),
      ),
    );
    _eventBus.fire(
      WorkflowRunStatusChangedEvent(
        runId: run.id,
        definitionName: run.definitionName,
        oldStatus: run.status,
        newStatus: WorkflowRunStatus.awaitingApproval,
        errorMessage: reason,
        timestamp: DateTime.now(),
      ),
    );
    return awaitingApprovalRun;
  }
}
