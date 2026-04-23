part of 'workflow_executor.dart';

Future<StepOutcome> foreachRun(ForeachNode node, StepExecutionContext ctx) async =>
    _stepOutcomeFromHandoff(node, ctx, await dispatchStep(node, ctx));

Future<StepOutcome> mapRun(MapNode node, StepExecutionContext ctx) async =>
    _stepOutcomeFromHandoff(node, ctx, await dispatchStep(node, ctx));

Future<StepOutcome> parallelGroupRun(ParallelGroupNode node, StepExecutionContext ctx) async =>
    _stepOutcomeFromHandoff(node, ctx, await dispatchStep(node, ctx));

Future<StepOutcome> loopRun(LoopNode node, StepExecutionContext ctx) async =>
    _stepOutcomeFromHandoff(node, ctx, await dispatchStep(node, ctx));
