import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        AgentExecution,
        OutputConfig,
        OutputFormat,
        Task,
        TaskStatus,
        TaskStatusChangedEvent,
        TaskType,
        WorkflowDefinition,
        WorkflowRun,
        WorkflowStep,
        WorkflowStepExecution;

import 'map_context.dart';
import 'output_resolver.dart';
import 'schema_presets.dart';
import 'skill_prompt_builder.dart';
import 'step_config_policy.dart' as step_config_policy;
import 'step_config_resolver.dart';
import 'workflow_context.dart';
import 'workflow_runner_types.dart';
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
  required int maxRetries,
  required Map<String, dynamic> taskConfig,
}) async {
  final taskRepository = ctx.taskRepository;
  final agentExecutionRepository = ctx.agentExecutionRepository;
  final workflowStepExecutionRepository = ctx.workflowStepExecutionRepository;
  final executionTransactor = ctx.executionTransactor;
  if (taskRepository == null ||
      agentExecutionRepository == null ||
      workflowStepExecutionRepository == null ||
      executionTransactor == null) {
    throw StateError(
      'Workflow task spawn requires AgentExecution + WorkflowStepExecution persistence. '
      'Wire taskRepository, agentExecutionRepository, workflowStepExecutionRepository, and '
      'executionTransactor into WorkflowExecutor before executing workflows.',
    );
  }

  final timestamp = DateTime.now();
  final agentExecutionId = ctx.uuid.v4();
  final agentExecution = AgentExecution(
    id: agentExecutionId,
    provider: trimmedString(provider),
    model: trimmedString(taskConfig['model']),
    workspaceDir: workflowWorkspaceDir,
    budgetTokens: maxTokens,
  );
  final workflowStepExecution = buildWorkflowStepExecutionFromConfig(
    taskId: taskId,
    agentExecutionId: agentExecutionId,
    runId: run.id,
    stepIndex: stepIndex,
    step: step,
    taskConfig: taskConfig,
  );
  final sanitizedTaskConfig = stripWorkflowStepConfig(taskConfig);
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
    maxRetries: maxRetries > 0 ? maxRetries : 0,
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
}) {
  final config = <String, dynamic>{};
  if (resolved.model != null) config['model'] = resolved.model;
  if (resolved.effort != null) config['effort'] = resolved.effort;
  if (resolved.maxTokens != null) config['tokenBudget'] = resolved.maxTokens;
  if (resolved.allowedTools != null) config['allowedTools'] = resolved.allowedTools;
  if (resolved.maxCostUsd != null) config['maxCostUsd'] = resolved.maxCostUsd;
  final isReadOnlyStep = step_config_policy.stepIsReadOnly(step, resolved);
  if (isReadOnlyStep) {
    config['readOnly'] = true;
  }
  if (step_config_policy.stepNeedsWorktree(definition, step, resolved, resolvedWorktreeMode: resolvedWorktreeMode)) {
    config['_workflowNeedsWorktree'] = true;
  }
  final branch = context.variables['BRANCH']?.trim();
  if (branch != null && branch.isNotEmpty) {
    config['_baseRef'] = branch;
  }
  final integrationBranch = (context['_workflow.git.integration_branch'] as String?)?.trim();
  if (integrationBranch != null && integrationBranch.isNotEmpty && definition.gitStrategy?.bootstrap == true) {
    config['_baseRef'] = integrationBranch;
  }
  final strategy = definition.gitStrategy;
  if (strategy != null) {
    config['_workflowGit'] = {
      'runId': run.id,
      'worktree': resolvedWorktreeMode,
      'bootstrap': strategy.bootstrap,
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
  required WorkflowTemplateEngine templateEngine,
  required SkillPromptBuilder skillPromptBuilder,
}) {
  final prompts = step.prompts;
  if (prompts == null || prompts.length < 2) return const [];

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
            emitStepOutcomeProtocol: !step.emitsOwnOutcome,
          )
        : resolvedPrompt;
    followUps.add(built);
  }
  return followUps;
}

/// Builds the strict structured-output envelope schema for a step.
Map<String, dynamic>? buildStructuredOutputEnvelopeSchema(
  WorkflowStep step,
  Map<String, OutputConfig>? effectiveOutputs,
) {
  if (effectiveOutputs == null || effectiveOutputs.isEmpty) return null;

  final properties = <String, dynamic>{};
  final required = <String>[];

  for (final entry in effectiveOutputs.entries) {
    final config = entry.value;
    if (outputResolverFor(entry.key, config) is! NarrativeOutput) continue;
    final schema = switch (config.format) {
      OutputFormat.text || OutputFormat.path => const {'type': 'string'},
      OutputFormat.lines => const {
        'type': 'array',
        'items': {'type': 'string'},
      },
      OutputFormat.json => config.inlineSchema ?? schemaPresets[config.presetName]?.schema,
    };
    if (schema == null) continue;
    properties[entry.key] = schema;
    required.add(entry.key);
  }

  if (properties.isEmpty) return null;
  return {'type': 'object', 'additionalProperties': false, 'required': required, 'properties': properties};
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
    stepType: step.type,
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
