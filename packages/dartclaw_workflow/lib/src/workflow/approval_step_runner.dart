import 'dart:async' show Timer;

import 'package:dartclaw_core/dartclaw_core.dart'
    show EventBus, WorkflowApprovalRequestedEvent, WorkflowRunStatus, WorkflowRunStatusChangedEvent;
import 'package:dartclaw_models/dartclaw_models.dart' show ActionNode, WorkflowRun, WorkflowStep;

import 'workflow_context.dart';
import 'workflow_runner_types.dart';
import 'workflow_template_engine.dart';

/// Runs a normalized approval action node.
Future<StepOutcome> approvalStepRun(ActionNode node, StepExecutionContext ctx) async {
  final definition = ctx.definition;
  final run = ctx.run;
  final context = ctx.workflowContext;
  if (definition == null || run == null || context == null) {
    throw StateError('approvalStepRun requires run, definition, and workflowContext on StepExecutionContext.');
  }
  final step = definition.steps.firstWhere((candidate) => candidate.id == node.stepId);
  await executeApprovalStep(
    run: run,
    step: step,
    context: context,
    stepIndex: definition.steps.indexOf(step),
    templateEngine: ctx.templateEngine ?? WorkflowTemplateEngine(),
    dependencies: ApprovalStepDependencies(
      eventBus: ctx.eventBus,
      repository: ctx.repository,
      persistContext: (_, _) async {},
      cancelRun: (_, _) async {},
      approvalTimers: <String, Timer>{},
    ),
  );
  return StepOutcome(
    step: step,
    success: false,
    awaitingApproval: true,
    outcome: 'needsInput',
    outcomeReason: 'approval required: ${step.id}',
  );
}

/// Dependencies needed by approval step execution.
final class ApprovalStepDependencies {
  final EventBus eventBus;
  final dynamic repository;
  final Future<void> Function(String runId, WorkflowContext context) persistContext;
  final Future<void> Function(WorkflowRun run, String reason) cancelRun;
  final Map<String, Timer> approvalTimers;

  const ApprovalStepDependencies({
    required this.eventBus,
    required this.repository,
    required this.persistContext,
    required this.cancelRun,
    required this.approvalTimers,
  });
}

/// Executes a `type: approval` step and pauses the run with approval metadata.
Future<void> executeApprovalStep({
  required WorkflowRun run,
  required WorkflowStep step,
  required WorkflowContext context,
  required int stepIndex,
  required WorkflowTemplateEngine templateEngine,
  required ApprovalStepDependencies dependencies,
}) async {
  assert(step.type == 'approval', 'approval runner received non-approval step ${step.id}');
  final message = templateEngine.resolve(step.prompts?.firstOrNull ?? '', context);
  final requestedAt = DateTime.now().toIso8601String();

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
    '_approval.pending.stepId': step.id,
    '_approval.pending.stepIndex': stepIndex,
  };

  if (timeoutSeconds != null) {
    final deadline = DateTime.now().add(Duration(seconds: timeoutSeconds)).toIso8601String();
    context['${step.id}.approval.timeout_deadline'] = deadline;
    approvalMeta['${step.id}.approval.timeout_deadline'] = deadline;
  }

  final awaitingApprovalRun = run.copyWith(
    currentStepIndex: stepIndex + 1,
    status: WorkflowRunStatus.awaitingApproval,
    errorMessage: 'approval required: ${step.id}',
    contextJson: {
      for (final e in run.contextJson.entries)
        if (e.key.startsWith('_')) e.key: e.value,
      ...context.toJson(),
      ...approvalMeta,
    },
    updatedAt: DateTime.now(),
  );
  await dependencies.persistContext(run.id, context);
  await dependencies.repository.update(awaitingApprovalRun);

  dependencies.eventBus.fire(
    WorkflowApprovalRequestedEvent(
      runId: run.id,
      stepId: step.id,
      message: message,
      timeoutSeconds: timeoutSeconds,
      timestamp: DateTime.now(),
    ),
  );
  dependencies.eventBus.fire(
    WorkflowRunStatusChangedEvent(
      runId: run.id,
      definitionName: run.definitionName,
      oldStatus: run.status,
      newStatus: WorkflowRunStatus.awaitingApproval,
      errorMessage: 'approval required: ${step.id}',
      timestamp: DateTime.now(),
    ),
  );

  if (timeoutSeconds != null) {
    final timerKey = '${run.id}:${step.id}';
    dependencies.approvalTimers[timerKey] = Timer(Duration(seconds: timeoutSeconds), () async {
      dependencies.approvalTimers.remove(timerKey);
      final current = await dependencies.repository.getById(run.id) as WorkflowRun?;
      if (current == null || current.status != WorkflowRunStatus.awaitingApproval) return;
      final updatedContext = Map<String, dynamic>.from(current.contextJson)
        ..['${step.id}.status'] = 'cancelled'
        ..['${step.id}.approval.status'] = 'timed_out'
        ..['${step.id}.approval.cancel_reason'] = 'timeout';
      final withReason = current.copyWith(contextJson: updatedContext, updatedAt: DateTime.now());
      await dependencies.repository.update(withReason);
      await dependencies.cancelRun(withReason, 'approval timeout: ${step.id}');
    });
  }
}

/// Cancels outstanding approval timers.
void cancelApprovalTimers(Map<String, Timer> approvalTimers) {
  for (final timer in approvalTimers.values) {
    timer.cancel();
  }
  approvalTimers.clear();
}
