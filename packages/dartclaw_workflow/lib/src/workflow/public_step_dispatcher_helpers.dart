part of 'workflow_executor.dart';

Future<StepHandoff> _dispatchActionNode(
  _PublicStepDispatcher dispatcher,
  WorkflowRun run,
  WorkflowDefinition definition,
  WorkflowContext context,
  String stepId,
) async {
  final step = definition.steps.firstWhere((candidate) => candidate.id == stepId);
  final stepIndex = _requireStepIndex(definition, step);
  final preflight = await _runStandardPreflight(
    dispatcher,
    run,
    definition,
    context,
    step,
    stepIndex,
    gateFailurePrefix: 'step',
  );
  if (preflight.handoff case final handoff?) {
    return handoff;
  }

  if (step.type == 'approval') {
    await dispatcher._executor._executeApprovalStep(preflight.run, step, context, stepIndex: stepIndex);
    return _approvalRetryingHandoff(step, context);
  }

  final outcome = await dispatcher._executor._executeStep(
    preflight.run,
    definition,
    step,
    context,
    stepIndex: stepIndex,
  );
  if (outcome == null) {
    throw StateError('dispatchStep aborted before producing a handoff for step "${step.id}".');
  }
  return _handoffFromOutcome(outcome);
}

Future<StepHandoff> _dispatchMapNode(
  _PublicStepDispatcher dispatcher,
  WorkflowRun run,
  WorkflowDefinition definition,
  WorkflowContext context,
  String stepId,
) async {
  final step = definition.steps.firstWhere((candidate) => candidate.id == stepId);
  final stepIndex = _requireStepIndex(definition, step);
  final preflight = await _runStandardPreflight(
    dispatcher,
    run,
    definition,
    context,
    step,
    stepIndex,
    gateFailurePrefix: 'map step',
  );
  if (preflight.handoff case final handoff?) {
    return handoff;
  }

  final result = await dispatcher._executor._executeMapStep(
    preflight.run,
    definition,
    step,
    context,
    stepIndex: stepIndex,
  );
  if (result == null) {
    throw StateError('dispatchStep aborted before producing a handoff for map step "${step.id}".');
  }
  return _handoffFromMapResult(step.contextOutputs, step.id, result, 'Map');
}

Future<StepHandoff> _dispatchForeachNode(
  _PublicStepDispatcher dispatcher,
  WorkflowRun run,
  WorkflowDefinition definition,
  WorkflowContext context,
  String controllerStepId,
  List<String> childStepIds,
) async {
  final controllerStep = definition.steps.firstWhere((candidate) => candidate.id == controllerStepId);
  final stepIndex = _requireStepIndex(definition, controllerStep);
  final preflight = await _runBudgetPreflight(dispatcher, run, definition, context);
  if (preflight.handoff case final handoff?) {
    return handoff;
  }

  final stepById = {for (final step in definition.steps) step.id: step};
  final result = await dispatcher._executor._executeForeachStep(
    preflight.run,
    definition,
    controllerStep,
    childStepIds,
    context,
    stepById: stepById,
    stepIndex: stepIndex,
  );
  if (result == null) {
    throw StateError('dispatchStep aborted before producing a handoff for foreach step "${controllerStep.id}".');
  }
  return _handoffFromMapResult(controllerStep.contextOutputs, controllerStep.id, result, 'Foreach');
}

Future<StepHandoff> _dispatchParallelGroupNode(
  _PublicStepDispatcher dispatcher,
  WorkflowRun run,
  WorkflowDefinition definition,
  WorkflowContext context,
  List<String> stepIds,
) async {
  final fullGroup = _stepsForIds(definition, stepIds);
  if (fullGroup.isEmpty) {
    throw StateError('dispatchStep requires a non-empty parallel group.');
  }

  final filteredGroup = <WorkflowStep>[];
  var currentRun = run;
  for (final groupStep in fullGroup) {
    final stepIndex = _requireStepIndex(definition, groupStep);
    final skippedRun = await dispatcher._executor._skipDueToEntryGate(currentRun, groupStep, stepIndex, context);
    if (skippedRun != null) {
      currentRun = skippedRun;
      continue;
    }
    filteredGroup.add(groupStep);
  }

  if (filteredGroup.isEmpty) {
    return StepHandoffSuccess(outputs: _contextOutputs(context));
  }

  for (final groupStep in filteredGroup) {
    final gate = groupStep.gate;
    if (gate == null) continue;
    if (dispatcher._executor._gateEvaluator.evaluate(gate, context)) continue;
    final reason = "Gate failed for parallel step '${groupStep.name}': $gate";
    await dispatcher._executor._failRun(currentRun, reason);
    return _validationFailureHandoff(reason, context);
  }

  final budgetPreflight = await _runBudgetPreflight(dispatcher, currentRun, definition, context);
  if (budgetPreflight.handoff case final handoff?) {
    return handoff;
  }

  final results = await dispatcher._executor._executeParallelGroup(
    budgetPreflight.run,
    definition,
    filteredGroup,
    context,
  );
  final outputs = {..._contextOutputs(context), ..._parallelOutputs(results)};
  final failedSteps = results.where((result) => !result.success).toList(growable: false);
  final cost = StepTokenBreakdown(totalTokens: results.fold(0, (sum, result) => sum + result.tokenCount));

  if (failedSteps.isEmpty) {
    return StepHandoffSuccess(outputs: outputs, cost: cost, outcome: results.last);
  }

  final awaitingApproval = failedSteps.where((result) => result.awaitingApproval).firstOrNull;
  if (awaitingApproval != null) {
    return StepHandoffRetrying(
      outputs: outputs,
      retryState: StepRetryState.none,
      cost: cost,
      outcome: awaitingApproval,
    );
  }

  return StepHandoffValidationFailed(
    outputs: outputs,
    validationFailure: StepValidationFailure(
      reason: 'Parallel step(s) failed: ${failedSteps.map((result) => result.step.id).join(", ")}',
    ),
    cost: cost,
    outcome: failedSteps.first,
  );
}

Future<StepHandoff> _dispatchLoopNode(
  _PublicStepDispatcher dispatcher,
  WorkflowRun run,
  WorkflowDefinition definition,
  WorkflowContext context,
  String loopId,
) async {
  final loop = definition.loops.firstWhere((candidate) => candidate.id == loopId);
  var updatedRun = run;
  final initialTokens = run.totalTokens;
  final pausedOrCancelled = await dispatcher._executor._executeLoop(
    run,
    definition,
    loop,
    context,
    onRunUpdated: (next) => updatedRun = next,
  );
  final finalRun = await dispatcher._executor._repository.getById(run.id) ?? updatedRun;
  final cost = StepTokenBreakdown(totalTokens: finalRun.totalTokens - initialTokens);
  final outputs = _contextOutputs(context);

  if (!pausedOrCancelled) {
    return StepHandoffSuccess(outputs: outputs, cost: cost);
  }
  if (finalRun.status == WorkflowRunStatus.awaitingApproval) {
    return StepHandoffRetrying(outputs: outputs, retryState: StepRetryState.none, cost: cost);
  }
  if (finalRun.status == WorkflowRunStatus.failed || finalRun.status == WorkflowRunStatus.cancelled) {
    return StepHandoffValidationFailed(
      outputs: outputs,
      validationFailure: StepValidationFailure(
        reason: finalRun.errorMessage ?? 'Loop "$loopId" ended with status ${finalRun.status.name}.',
      ),
      cost: cost,
    );
  }
  return StepHandoffRetrying(outputs: outputs, retryState: StepRetryState.none, cost: cost);
}

Future<_PublicPreflightResult> _runStandardPreflight(
  _PublicStepDispatcher dispatcher,
  WorkflowRun run,
  WorkflowDefinition definition,
  WorkflowContext context,
  WorkflowStep step,
  int stepIndex, {
  required String gateFailurePrefix,
}) async {
  final skippedRun = await dispatcher._executor._skipDueToEntryGate(run, step, stepIndex, context);
  if (skippedRun != null) {
    return (run: skippedRun, handoff: StepHandoffSuccess(outputs: _contextOutputs(context)));
  }

  final gate = step.gate;
  if (gate != null && !dispatcher._executor._gateEvaluator.evaluate(gate, context)) {
    final reason = "Gate failed for $gateFailurePrefix '${step.name}': $gate";
    await dispatcher._executor._failRun(run, reason);
    return (run: run, handoff: _validationFailureHandoff(reason, context));
  }

  return _runBudgetPreflight(dispatcher, run, definition, context);
}

Future<_PublicPreflightResult> _runBudgetPreflight(
  _PublicStepDispatcher dispatcher,
  WorkflowRun run,
  WorkflowDefinition definition,
  WorkflowContext context,
) async {
  final refreshedRun = await dispatcher._executor._repository.getById(run.id) ?? run;
  final warnedRun = await dispatcher._executor._checkWorkflowBudgetWarning(refreshedRun, definition);
  if (!dispatcher._executor._workflowBudgetExceeded(warnedRun, definition)) {
    return (run: warnedRun, handoff: null);
  }

  final reason = 'Workflow budget exceeded: ${warnedRun.totalTokens} / ${definition.maxTokens} tokens';
  await dispatcher._executor._failRun(warnedRun, reason);
  return (run: warnedRun, handoff: _validationFailureHandoff(reason, context));
}

int _requireStepIndex(WorkflowDefinition definition, WorkflowStep step) {
  final stepIndex = definition.steps.indexOf(step);
  if (stepIndex >= 0) {
    return stepIndex;
  }
  throw StateError('dispatchStep could not locate step "${step.id}" in the supplied definition.');
}

List<WorkflowStep> _stepsForIds(WorkflowDefinition definition, List<String> stepIds) {
  final stepById = {for (final step in definition.steps) step.id: step};
  return stepIds.map((stepId) => stepById[stepId]).nonNulls.toList(growable: false);
}

Map<String, Object?> _contextOutputs(WorkflowContext context) => Map<String, Object?>.from(context.data);

StepHandoff _validationFailureHandoff(
  String reason,
  WorkflowContext context, {
  StepTokenBreakdown cost = StepTokenBreakdown.zero,
  StepOutcome? outcome,
}) => StepHandoffValidationFailed(
  outputs: _contextOutputs(context),
  validationFailure: StepValidationFailure(reason: reason),
  cost: cost,
  outcome: outcome,
);

StepHandoff _approvalRetryingHandoff(WorkflowStep step, WorkflowContext context) {
  final outputs = _contextOutputs(context);
  return StepHandoffRetrying(
    outputs: outputs,
    retryState: StepRetryState.none,
    outcome: StepOutcome(
      step: step,
      outputs: Map<String, dynamic>.from(outputs),
      success: false,
      awaitingApproval: true,
      outcome: 'needsInput',
      outcomeReason: 'approval required: ${step.id}',
    ),
  );
}

StepHandoff _handoffFromMapResult(List<String> contextOutputs, String stepId, MapStepResult result, String stepKind) {
  final outputs = <String, Object?>{for (final outputKey in contextOutputs) outputKey: result.results};
  final cost = StepTokenBreakdown(totalTokens: result.totalTokens);
  if (result.success) {
    return StepHandoffSuccess(outputs: outputs, cost: cost);
  }
  return StepHandoffValidationFailed(
    outputs: outputs,
    validationFailure: StepValidationFailure(
      reason: result.error ?? '$stepKind step "$stepId" failed without an error message.',
    ),
    cost: cost,
  );
}

Map<String, Object?> _parallelOutputs(List<StepOutcome> results) {
  final outputs = <String, Object?>{};
  for (final result in results) {
    outputs.addAll(Map<String, Object?>.from(result.outputs));
    final stepId = result.step.id;
    outputs['$stepId.status'] = result.success ? (result.task?.status.name ?? 'unknown') : 'failed';
    outputs['$stepId.tokenCount'] = result.tokenCount;
    if (result.outcome != null) {
      outputs['step.$stepId.outcome'] = result.outcome;
    }
    final reason = result.outcomeReason;
    if (reason != null && reason.isNotEmpty) {
      outputs['step.$stepId.outcome.reason'] = reason;
    }
  }
  return outputs;
}

StepHandoff _handoffFromOutcome(StepOutcome outcome) {
  final outputs = Map<String, Object?>.from(outcome.outputs);
  final cost = StepTokenBreakdown(totalTokens: outcome.tokenCount);
  final validationFailure = outcome.validationFailure;

  if (outcome.awaitingApproval) {
    return StepHandoffRetrying(
      outputs: outputs,
      validationFailure: validationFailure,
      retryState: StepRetryState.none,
      cost: cost,
      outcome: outcome,
    );
  }
  if (validationFailure != null) {
    return StepHandoffValidationFailed(
      outputs: outputs,
      validationFailure: validationFailure,
      cost: cost,
      outcome: outcome,
    );
  }
  return StepHandoffSuccess(outputs: outputs, cost: cost, outcome: outcome);
}

StepOutcome _stepOutcomeFromHandoff(WorkflowNode node, StepExecutionContext ctx, StepHandoff handoff) {
  final definition = ctx.definition;
  if (definition == null) {
    throw StateError('dispatchStep requires StepExecutionContext.definition to convert a handoff into StepOutcome.');
  }

  final outcome = _handoffOutcome(handoff);
  final validationFailure = handoff.validationFailure;
  return StepOutcome(
    step: _representativeStepForNode(definition, node),
    task: outcome?.task,
    outputs: Map<String, dynamic>.from(handoff.outputs),
    tokenCount: handoff.cost.totalTokens,
    success: _handoffSuccess(handoff, outcome),
    error: outcome?.error ?? validationFailure?.reason,
    outcome: outcome?.outcome ?? _handoffFallbackOutcome(handoff),
    outcomeReason: outcome?.outcomeReason ?? validationFailure?.reason,
    awaitingApproval: handoff is StepHandoffRetrying,
    validationFailure: validationFailure,
  );
}

WorkflowStep _representativeStepForNode(WorkflowDefinition definition, WorkflowNode node) => switch (node) {
  ActionNode(stepId: final stepId) ||
  MapNode(stepId: final stepId) ||
  ForeachNode(stepId: final stepId) => definition.steps.firstWhere((candidate) => candidate.id == stepId),
  ParallelGroupNode(stepIds: final stepIds) when stepIds.isNotEmpty => definition.steps.firstWhere(
    (candidate) => candidate.id == stepIds.first,
  ),
  LoopNode(stepIds: final stepIds) when stepIds.isNotEmpty => definition.steps.firstWhere(
    (candidate) => candidate.id == stepIds.first,
  ),
  _ => WorkflowStep(id: node.type, name: node.type),
};

StepOutcome? _handoffOutcome(StepHandoff handoff) => switch (handoff) {
  StepHandoffSuccess(outcome: final outcome?) ||
  StepHandoffValidationFailed(outcome: final outcome?) ||
  StepHandoffRetrying(outcome: final outcome?) => outcome,
  _ => null,
};

bool _handoffSuccess(StepHandoff handoff, StepOutcome? outcome) => switch (handoff) {
  StepHandoffSuccess() => outcome?.success ?? true,
  StepHandoffValidationFailed() || StepHandoffRetrying() => false,
};

String? _handoffFallbackOutcome(StepHandoff handoff) => switch (handoff) {
  StepHandoffValidationFailed() => 'failed',
  StepHandoffRetrying() => 'needsInput',
  StepHandoffSuccess() => null,
};
