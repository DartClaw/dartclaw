import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart'
    show AgentExecution, Task, TaskStatus, TaskStatusChangedEvent, TaskType, WorkflowStepExecution;
import 'workflow_definition.dart' show OutputConfig, WorkflowDefinition, WorkflowStep;
import 'workflow_run.dart' show WorkflowRun;

import 'execution_envelope_schema.dart' show modelDerivedFinalizerKeys;
import 'map_context.dart';
import 'skill_prompt_builder.dart';
import 'step_config_policy.dart' as step_config_policy;
import 'step_config_resolver.dart';
import 'workflow_context.dart';
import 'workflow_run_paths.dart';
import 'workflow_runner_types.dart';
import 'workflow_task_config.dart';
import 'workflow_template_engine.dart';

/// Creates AgentExecution, Task, and WorkflowStepExecution in one transaction.
Future<void> createWorkflowTaskTriple({
  required StepExecutionContext ctx,
  required String workflowWorkspaceDir,
  required String taskId,
  required WorkflowRun run,
  required WorkflowStep step,
  required int stepIndex,
  required String title,
  required String description,
  required TaskType type,
  required String? provider,
  required String? projectId,
  required int? maxTokens,
  required Map<String, dynamic> taskConfig,
}) async {
  assert(
    ctx.taskRepository != null &&
        ctx.agentExecutionRepository != null &&
        ctx.workflowStepExecutionRepository != null &&
        ctx.executionTransactor != null,
    'Workflow task persistence ports must be present',
  );
  final taskRepository = ctx.taskRepository!;
  final agentExecutionRepository = ctx.agentExecutionRepository!;
  final workflowStepExecutionRepository = ctx.workflowStepExecutionRepository!;
  final executionTransactor = ctx.executionTransactor!;

  // Host-computed per-step artifacts dir, exported on every workflow task via
  // the spawn env. Never derived from prompt text — the agent references
  // `$DARTCLAW_STEP_ARTIFACTS_DIR` and the extractor reads the same dir back.
  final dataDir = ctx.dataDir;
  if (dataDir == null || dataDir.trim().isEmpty) {
    throw StateError('Workflow task creation requires StepExecutionContext.dataDir to compute the step artifacts dir');
  }
  final stepArtifactsDir = workflowStepArtifactsDir(
    dataDir: dataDir,
    runId: run.id,
    stepId: step.id,
    mapIterationIndex: intOrNull(taskConfig[WorkflowTaskConfig.mapIterationIndex]),
  );
  final effectiveTaskConfig = {
    ...taskConfig,
    WorkflowTaskConfig.stepArtifactsEnv: {stepArtifactsDirEnvVar: stepArtifactsDir},
  };

  final timestamp = DateTime.now();
  final agentExecutionId = ctx.uuid.v4();
  final agentExecution = AgentExecution(
    id: agentExecutionId,
    provider: trimmedString(provider),
    model: trimmedString(effectiveTaskConfig['model']),
    workspaceDir: workflowWorkspaceDir,
    budgetTokens: maxTokens,
  );
  final workflowStepExecution = buildWorkflowStepExecutionFromConfig(
    taskId: taskId,
    agentExecutionId: agentExecutionId,
    runId: run.id,
    stepIndex: stepIndex,
    step: step,
    taskConfig: effectiveTaskConfig,
  );
  final sanitizedTaskConfig = stripWorkflowStepConfig(effectiveTaskConfig);
  final queuedTask = Task(
    id: taskId,
    title: title,
    description: description,
    type: type,
    status: TaskStatus.queued,
    configJson: sanitizedTaskConfig,
    createdAt: timestamp,
    startedAt: null,
    completedAt: null,
    provider: provider,
    agentExecutionId: agentExecutionId,
    agentExecution: agentExecution,
    projectId: projectId?.trim().isEmpty ?? true ? null : projectId?.trim(),
    maxTokens: maxTokens != null && maxTokens > 0 ? maxTokens : null,
    workflowRunId: run.id,
    stepIndex: stepIndex,
    workflowStepExecution: workflowStepExecution,
    maxRetries: 0,
  );

  await executionTransactor.transaction(() async {
    await agentExecutionRepository.create(agentExecution);
    await taskRepository.insert(queuedTask);
    await workflowStepExecutionRepository.create(workflowStepExecution);
  });

  ctx.eventBus.fire(
    TaskStatusChangedEvent(
      taskId: taskId,
      oldStatus: TaskStatus.draft,
      newStatus: TaskStatus.queued,
      trigger: 'workflow',
      timestamp: timestamp,
    ),
  );
}

/// Builds configJson for a task from a workflow step and resolved config.
Map<String, dynamic> buildStepConfig(
  WorkflowRun run,
  WorkflowDefinition definition,
  WorkflowStep step,
  ResolvedStepConfig resolved,
  WorkflowContext context, {
  required String resolvedWorktreeMode,
  required String effectivePromotion,
  required String workflowWorkspaceDir,
  Map<String, OutputConfig>? effectiveOutputs,
}) {
  final config = <String, dynamic>{};
  if (resolved.model != null) config['model'] = resolved.model;
  if (resolved.effort != null) config['effort'] = resolved.effort;
  if (resolved.maxTokens != null) config['tokenBudget'] = resolved.maxTokens;
  if (resolved.allowedTools != null) config['allowedTools'] = resolved.allowedTools;
  if (resolved.timeoutSeconds != null) config[WorkflowTaskConfig.workflowTimeoutSeconds] = resolved.timeoutSeconds;
  final isReadOnlyStep = step_config_policy.stepIsReadOnly(step, resolved);
  if (isReadOnlyStep) {
    config['readOnly'] = true;
  }
  if (step_config_policy.stepNeedsWorktree(
    definition,
    step,
    resolved,
    resolvedWorktreeMode: resolvedWorktreeMode,
    effectiveOutputs: effectiveOutputs,
  )) {
    config['_workflowNeedsWorktree'] = true;
  }
  final branch = context.variables['BRANCH']?.trim();
  if (branch != null && branch.isNotEmpty) {
    config['_baseRef'] = branch;
  }
  final integrationBranch = (context['_workflow.git.integration_branch'] as String?)?.trim();
  if (integrationBranch != null && integrationBranch.isNotEmpty && definition.gitStrategy?.integrationBranch == true) {
    config['_baseRef'] = integrationBranch;
  }
  final strategy = definition.gitStrategy;
  if (strategy != null) {
    config['_workflowGit'] = {
      'runId': run.id,
      'worktree': resolvedWorktreeMode,
      'integrationBranch': strategy.integrationBranch,
      'promotion': effectivePromotion,
    };
  }
  config['_workflowWorkspaceDir'] = workflowWorkspaceDir;
  config['reviewMode'] = 'auto-accept';
  return config;
}

/// Builds follow-up prompts for workflow one-shot multi-turn execution.
List<String> buildOneShotFollowUpPrompts(
  WorkflowStep step,
  WorkflowContext context,
  Map<String, OutputConfig>? effectiveOutputs, {
  required List<String> outputKeys,
  MapContext? mapCtx,
  String? gatingSeverity,
  bool finalizerHandlesOutputs = false,
  required WorkflowTemplateEngine templateEngine,
  required SkillPromptBuilder skillPromptBuilder,
}) {
  final prompts = step.prompts;
  if (prompts == null || prompts.length < 2) return const [];

  // The bool stays the outcome-protocol signal; the covered-key set (derived
  // from the same needsFinalizer gate) suppresses only the envelope-claimed
  // keys' main-prompt contract, leaving opt-out / `*_source` keys instructed.
  final finalizerCoveredKeys = finalizerHandlesOutputs
      ? modelDerivedFinalizerKeys(step, effectiveOutputs)
      : const <String>[];
  final followUps = <String>[];
  for (var i = 1; i < prompts.length; i++) {
    final isLast = i == prompts.length - 1;
    final resolvedPrompt = templateEngine.resolveWithMap(prompts[i], context, mapCtx);
    final built = isLast
        ? skillPromptBuilder.build(
            skill: null,
            resolvedPrompt: resolvedPrompt,
            outputs: effectiveOutputs,
            outputKeys: outputKeys,
            outputExamples: step.outputExamples,
            emitStepOutcomeProtocol: !finalizerHandlesOutputs && !step.emitsOwnOutcome,
            finalizerCoveredKeys: finalizerCoveredKeys,
            gatingSeverity: gatingSeverity,
          )
        : resolvedPrompt;
    followUps.add(built);
  }
  return followUps;
}

/// Removes workflow-only task config keys before task persistence.
Map<String, dynamic> stripWorkflowStepConfig(Map<String, dynamic> taskConfig) {
  final sanitized = Map<String, dynamic>.from(taskConfig);
  for (final key in const <String>{
    '_workflowGit',
    '_workflowWorkspaceDir',
    '_workflow.externalArtifactMount',
    '_workflowFollowUpPrompts',
    '_workflowStructuredSchema',
    '_workflowProviderSessionId',
    '_workflowStructuredOutputPayload',
    '_workflowStepId',
    '_workflowInputTokensNew',
    '_workflowCacheReadTokens',
    '_workflowOutputTokens',
    '_continueProviderSessionId',
    '_mapIterationIndex',
    '_mapIterationTotal',
    '_mapStepId',
    'model',
  }) {
    sanitized.remove(key);
  }
  return sanitized;
}

WorkflowStepExecution buildWorkflowStepExecutionFromConfig({
  required String taskId,
  required String agentExecutionId,
  required String runId,
  required int stepIndex,
  required WorkflowStep step,
  required Map<String, dynamic> taskConfig,
}) {
  final tokenBreakdown = buildTokenBreakdownJson(taskConfig);
  return WorkflowStepExecution(
    taskId: taskId,
    agentExecutionId: agentExecutionId,
    workflowRunId: runId,
    stepIndex: stepIndex,
    stepId: step.id,
    stepType: step.taskType.toJson(),
    gitJson: encodeJsonString(taskConfig['_workflowGit']),
    providerSessionId: trimmedString(taskConfig['_continueProviderSessionId']),
    structuredSchemaJson: encodeJsonString(taskConfig['_workflowStructuredSchema']),
    structuredOutputJson: encodeJsonString(taskConfig['_workflowStructuredOutputPayload']),
    followUpPromptsJson: encodeJsonString(taskConfig['_workflowFollowUpPrompts']),
    externalArtifactMount: encodeJsonString(taskConfig['_workflow.externalArtifactMount']),
    mapIterationIndex: intOrNull(taskConfig['_mapIterationIndex']),
    mapIterationTotal: intOrNull(taskConfig['_mapIterationTotal']),
    stepTokenBreakdownJson: tokenBreakdown,
  );
}

String? buildTokenBreakdownJson(Map<String, dynamic> taskConfig) {
  final inputTokensNew = intOrNull(taskConfig['_workflowInputTokensNew']);
  final cacheReadTokens = intOrNull(taskConfig['_workflowCacheReadTokens']);
  final outputTokens = intOrNull(taskConfig['_workflowOutputTokens']);
  if (inputTokensNew == null && cacheReadTokens == null && outputTokens == null) {
    return null;
  }
  return jsonEncode({
    ...?switch (inputTokensNew) {
      final value? => {'inputTokensNew': value},
      null => null,
    },
    ...?switch (cacheReadTokens) {
      final value? => {'cacheReadTokens': value},
      null => null,
    },
    ...?switch (outputTokens) {
      final value? => {'outputTokens': value},
      null => null,
    },
  });
}

String? encodeJsonString(Object? value) => value == null ? null : jsonEncode(value);

String? trimmedString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int? intOrNull(Object? value) {
  return switch (value) {
    final int intValue => intValue,
    final num numValue => numValue.toInt(),
    _ => null,
  };
}
