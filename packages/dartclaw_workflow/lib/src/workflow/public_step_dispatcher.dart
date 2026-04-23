part of 'workflow_executor.dart';

final class _PublicStepDispatcher {
  _PublicStepDispatcher._(this._executor, this._ctx);

  final WorkflowExecutor _executor;
  final StepExecutionContext _ctx;

  factory _PublicStepDispatcher.fromContext(StepExecutionContext ctx) {
    final dataDir = ctx.dataDir;
    if (dataDir == null || dataDir.isEmpty) {
      throw StateError('dispatchStep requires StepExecutionContext.dataDir. Use a configured StepExecutionContext.');
    }

    return _PublicStepDispatcher._(
      WorkflowExecutor._internal(
        executionContext: ctx,
        promptConfiguration: StepPromptConfiguration(
          templateEngine: ctx.templateEngine,
          skillPromptBuilder: ctx.skillPromptBuilder,
        ),
        dataDir: dataDir,
        roleDefaults: ctx.roleDefaults,
        bashStepPolicy: BashStepPolicy(
          hostEnvironment: ctx.hostEnvironment,
          envAllowlist: ctx.bashStepEnvAllowlist,
          extraStripPatterns: ctx.bashStepExtraStripPatterns,
        ),
        uuid: ctx.uuid,
      ),
      ctx,
    );
  }

  Future<StepHandoff> dispatch(WorkflowNode node) async {
    final (run, definition, context) = _scopedWorkflowState();
    return switch (node) {
      ActionNode(stepId: final stepId) => _dispatchActionNode(
        run,
        definition,
        context,
        definition.steps.firstWhere((candidate) => candidate.id == stepId),
      ),
      MapNode(stepId: final stepId) => _dispatchMapNode(
        run,
        definition,
        context,
        definition.steps.firstWhere((candidate) => candidate.id == stepId),
      ),
      ForeachNode(stepId: final stepId, childStepIds: final childStepIds) => _dispatchForeachNode(
        run,
        definition,
        context,
        definition.steps.firstWhere((candidate) => candidate.id == stepId),
        childStepIds,
      ),
      ParallelGroupNode(stepIds: final stepIds) => _dispatchParallelGroupNode(run, definition, context, stepIds),
      LoopNode(loopId: final loopId) => _dispatchLoopNode(run, definition, context, loopId),
    };
  }

  void dispose() => _executor.dispose();

  (WorkflowRun, WorkflowDefinition, WorkflowContext) _scopedWorkflowState() {
    final definition = _ctx.definition;
    final run = _ctx.run;
    final context = _ctx.workflowContext;
    if (definition == null || run == null || context == null) {
      throw StateError('dispatchStep requires run, definition, and workflowContext on StepExecutionContext.');
    }
    return (run, definition, context);
  }

  Future<StepHandoff> _dispatchActionNode(
    WorkflowRun run,
    WorkflowDefinition definition,
    WorkflowContext context,
    WorkflowStep step,
  ) async {
    final stepIndex = definition.steps.indexOf(step);
    if (stepIndex < 0) {
      throw StateError('dispatchStep could not locate step "${step.id}" in the supplied definition.');
    }

    if (step.type == 'approval') {
      await _executor._executeApprovalStep(run, step, context, stepIndex: stepIndex);
      return StepHandoffRetrying(outputs: const <String, Object?>{}, retryState: StepRetryState.none);
    }

    final outcome = await _executor._executeStep(run, definition, step, context, stepIndex: stepIndex);
    if (outcome == null) {
      throw StateError('dispatchStep aborted before producing a handoff for step "${step.id}".');
    }
    return _handoffFromOutcome(outcome);
  }

  Future<StepHandoff> _dispatchMapNode(
    WorkflowRun run,
    WorkflowDefinition definition,
    WorkflowContext context,
    WorkflowStep step,
  ) async {
    final stepIndex = definition.steps.indexOf(step);
    final result = await _executor._executeMapStep(run, definition, step, context, stepIndex: stepIndex);
    if (result == null) {
      throw StateError('dispatchStep aborted before producing a handoff for map step "${step.id}".');
    }
    return _handoffFromMapResult(step.contextOutputs, step.id, result, 'Map');
  }

  Future<StepHandoff> _dispatchForeachNode(
    WorkflowRun run,
    WorkflowDefinition definition,
    WorkflowContext context,
    WorkflowStep controllerStep,
    List<String> childStepIds,
  ) async {
    final stepIndex = definition.steps.indexOf(controllerStep);
    final stepById = {for (final step in definition.steps) step.id: step};
    final result = await _executor._executeForeachStep(
      run,
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
    WorkflowRun run,
    WorkflowDefinition definition,
    WorkflowContext context,
    List<String> stepIds,
  ) async {
    final group = _stepsForIds(definition, stepIds);
    if (group.isEmpty) {
      throw StateError('dispatchStep requires a non-empty parallel group.');
    }

    final results = await _executor._executeParallelGroup(run, definition, group, context);
    final outputs = _parallelOutputs(results);
    final failedSteps = results.where((result) => !result.success).toList(growable: false);
    final cost = StepTokenBreakdown(totalTokens: results.fold(0, (sum, result) => sum + result.tokenCount));

    if (failedSteps.isEmpty) {
      return StepHandoffSuccess(outputs: outputs, cost: cost, outcome: results.last);
    }

    final firstFailure = failedSteps.first;
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
      outcome: firstFailure,
    );
  }

  Future<StepHandoff> _dispatchLoopNode(
    WorkflowRun run,
    WorkflowDefinition definition,
    WorkflowContext context,
    String loopId,
  ) async {
    final loop = definition.loops.firstWhere((candidate) => candidate.id == loopId);
    var updatedRun = run;
    final initialTokens = run.totalTokens;
    final pausedOrCancelled = await _executor._executeLoop(
      run,
      definition,
      loop,
      context,
      onRunUpdated: (next) => updatedRun = next,
    );
    final outputs = Map<String, Object?>.from(context.toJson());
    final cost = StepTokenBreakdown(totalTokens: updatedRun.totalTokens - initialTokens);
    return pausedOrCancelled
        ? StepHandoffRetrying(outputs: outputs, retryState: StepRetryState.none, cost: cost)
        : StepHandoffSuccess(outputs: outputs, cost: cost);
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

  List<WorkflowStep> _stepsForIds(WorkflowDefinition definition, List<String> stepIds) {
    final stepById = {for (final step in definition.steps) step.id: step};
    return stepIds.map((stepId) => stepById[stepId]).nonNulls.toList(growable: false);
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
