part of 'workflow_executor.dart';

/// Uniform runner signature for parallel-group nodes.
Future<StepOutcome> parallelGroupRun(ParallelGroupNode node, StepExecutionContext ctx) async {
  throw UnsupportedError('parallelGroupRun is coordinated by WorkflowExecutor for result merging and persistence.');
}

/// Runs parallel workflow groups and shared step-result merge helpers.
extension WorkflowExecutorParallelGroupRunner on WorkflowExecutor {
  Future<List<StepOutcome>> _executeParallelGroup(
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
        fallbackStatus: result.success ? (result.task?.status.name ?? 'unknown') : 'failed',
      );
    }
  }

  WorkflowRun _updateParallelBudget(WorkflowRun run, List<StepOutcome> results) {
    final total = results.fold(0, (sum, r) => sum + r.tokenCount);
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
    TaskStatus.failed || TaskStatus.cancelled || TaskStatus.rejected => 'failed',
    _ => null,
  };

  Future<(String?, String?)> _resolveStepOutcome(WorkflowStep step, Task task) async {
    final parsed = await _contextExtractor.extractStepOutcome(task);
    final forcedOutcome = _fallbackOutcomeFromTaskStatus(task.status);
    if (forcedOutcome == 'failed') {
      if (parsed != null && parsed.outcome != 'failed') {
        WorkflowExecutor._log.warning(
          "Workflow step '${step.id}' reported outcome '${parsed.outcome}' but task ${task.id} "
          'finished with terminal status ${task.status.name}; overriding to failed',
        );
      }
      final failReason =
          (task.configJson['failReason'] as String?) ?? (task.configJson['errorSummary'] as String?) ?? parsed?.reason;
      return ('failed', failReason ?? task.status.name);
    }
    if (parsed != null) {
      return (parsed.outcome, parsed.reason);
    }

    final fallbackOutcome = forcedOutcome;
    if (fallbackOutcome == null) {
      return (null, null);
    }

    await _incrementOutcomeFallbackCounter();
    WorkflowExecutor._log.warning(
      "Workflow outcome fallback for step '${step.id}' "
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
        for (final e in run.contextJson.entries)
          if (e.key.startsWith('_')) e.key: e.value,
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
