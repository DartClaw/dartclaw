part of 'workflow_executor.dart';

typedef _PublicPreflightResult = ({WorkflowRun run, StepHandoff? handoff});

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
      ActionNode(stepId: final stepId) => _dispatchActionNode(this, run, definition, context, stepId),
      MapNode(stepId: final stepId) => _dispatchMapNode(this, run, definition, context, stepId),
      ForeachNode(stepId: final stepId, childStepIds: final childStepIds) => _dispatchForeachNode(
        this,
        run,
        definition,
        context,
        stepId,
        childStepIds,
      ),
      ParallelGroupNode(stepIds: final stepIds) => _dispatchParallelGroupNode(this, run, definition, context, stepIds),
      LoopNode(loopId: final loopId) => _dispatchLoopNode(this, run, definition, context, loopId),
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
}
