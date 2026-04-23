import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowTaskConfig;
import 'package:logging/logging.dart';

import '../turn_manager.dart';
import 'task_budget_policy.dart';
import 'task_event_recorder.dart';
import 'task_service.dart';
import 'workflow_cli_runner.dart';
import 'workflow_turn_extractor.dart';

part 'workflow_one_shot_runner_helpers.dart';

/// Executes workflow-owned tasks through the one-shot CLI runner.
final class WorkflowOneShotRunner {
  static const _legacySessionCostFreshInputKey =
      'new_'
      'input_tokens';

  WorkflowOneShotRunner({
    required WorkflowCliRunner? runner,
    required WorkflowStepExecutionRepository? workflowStepExecutionRepository,
    required MessageService messages,
    required KvService? kv,
    required TaskBudgetPolicy budgetPolicy,
    required TaskService tasks,
    TaskEventRecorder? eventRecorder,
    Logger? log,
  }) : _runner = runner,
       _workflowStepExecutionRepository = workflowStepExecutionRepository,
       _messages = messages,
       _kv = kv,
       _budgetPolicy = budgetPolicy,
       _tasks = tasks,
       _eventRecorder = eventRecorder,
       _log = log ?? Logger('WorkflowOneShotRunner');

  final WorkflowCliRunner? _runner;
  final WorkflowStepExecutionRepository? _workflowStepExecutionRepository;
  final MessageService _messages;
  final KvService? _kv;
  final TaskBudgetPolicy _budgetPolicy;
  final TaskService _tasks;
  final TaskEventRecorder? _eventRecorder;
  final Logger _log;

  Future<TurnOutcome> execute(
    Task task, {
    required String sessionId,
    required String pendingMessage,
    required String provider,
    required String profileId,
    required String? workingDirectory,
    required String? modelOverride,
    required String? effortOverride,
    required String? sandboxOverride,
  }) async {
    final runner = _runner;
    if (runner == null) {
      throw StateError('Workflow one-shot execution requested but no runner is configured');
    }

    final cwd = workingDirectory ?? Directory.current.path;
    final repo = _workflowStepExecutionRepository;
    final workflowStepExecution = task.workflowStepExecution;
    final followUps = workflowStepExecution?.followUpPrompts ?? const <String>[];
    final structuredSchema = workflowStepExecution?.structuredSchema;
    String? providerSessionId = workflowStepExecution?.providerSessionId;
    final workflowStepId = workflowStepExecution?.stepId;
    final appendSystemPrompt = switch (task.configJson['appendSystemPrompt']) {
      final String value when value.trim().isNotEmpty => value,
      _ => null,
    };
    final startedAt = DateTime.now();
    var inputTokens = 0;
    var outputTokens = 0;
    var cacheReadTokens = 0;
    var cacheWriteTokens = 0;
    final sessionUsageBaseline = switch (provider) {
      'codex' when providerSessionId != null && providerSessionId.isNotEmpty => await _readSessionUsageSnapshot(
        sessionId,
      ),
      _ => const _SessionUsageSnapshot(),
    };
    var previousCumulativeProviderSessionId = providerSessionId;
    var previousCumulativeInputTokens = sessionUsageBaseline.inputTokens + sessionUsageBaseline.cacheReadTokens;
    var previousCumulativeNewInputTokens = sessionUsageBaseline.inputTokens;
    var previousCumulativeOutputTokens = sessionUsageBaseline.outputTokens;
    var previousCumulativeCacheReadTokens = sessionUsageBaseline.cacheReadTokens;
    var previousCumulativeCacheWriteTokens = sessionUsageBaseline.cacheWriteTokens;

    int usageDelta(int current, int previous) => current >= previous ? current - previous : current;

    ({int inputTokens, int newInputTokens, int outputTokens, int cacheReadTokens, int cacheWriteTokens})
    normalizeWorkflowCliUsage(WorkflowCliTurnResult turnResult) {
      if (provider != 'codex') {
        return (
          inputTokens: turnResult.inputTokens,
          newInputTokens: turnResult.newInputTokens,
          outputTokens: turnResult.outputTokens,
          cacheReadTokens: turnResult.cacheReadTokens,
          cacheWriteTokens: turnResult.cacheWriteTokens,
        );
      }

      final currentProviderSessionId = switch (turnResult.providerSessionId.trim()) {
        final String value when value.isNotEmpty => value,
        _ => previousCumulativeProviderSessionId,
      };
      if (previousCumulativeProviderSessionId != null &&
          currentProviderSessionId != null &&
          currentProviderSessionId != previousCumulativeProviderSessionId) {
        previousCumulativeInputTokens = 0;
        previousCumulativeNewInputTokens = 0;
        previousCumulativeOutputTokens = 0;
        previousCumulativeCacheReadTokens = 0;
        previousCumulativeCacheWriteTokens = 0;
      }

      final normalized = (
        inputTokens: usageDelta(turnResult.inputTokens, previousCumulativeInputTokens),
        newInputTokens: usageDelta(turnResult.newInputTokens, previousCumulativeNewInputTokens),
        outputTokens: usageDelta(turnResult.outputTokens, previousCumulativeOutputTokens),
        cacheReadTokens: usageDelta(turnResult.cacheReadTokens, previousCumulativeCacheReadTokens),
        cacheWriteTokens: usageDelta(turnResult.cacheWriteTokens, previousCumulativeCacheWriteTokens),
      );
      previousCumulativeProviderSessionId = currentProviderSessionId;
      previousCumulativeInputTokens = turnResult.inputTokens;
      previousCumulativeNewInputTokens = turnResult.newInputTokens;
      previousCumulativeOutputTokens = turnResult.outputTokens;
      previousCumulativeCacheReadTokens = turnResult.cacheReadTokens;
      previousCumulativeCacheWriteTokens = turnResult.cacheWriteTokens;
      return normalized;
    }

    final prompts = <String>[pendingMessage, ...followUps];
    for (final prompt in prompts) {
      final (budgetVerdict, budgetWarningMessage) = await _budgetPolicy.checkBudget(task, sessionId);
      if (budgetVerdict == BudgetVerdict.exceeded) {
        return TurnOutcome(
          turnId: 'workflow-oneshot-budget',
          sessionId: sessionId,
          status: TurnStatus.failed,
          errorMessage: 'Workflow one-shot task exceeded its token budget',
          completedAt: DateTime.now(),
        );
      }
      if (budgetWarningMessage != null) {
        await _messages.insertMessage(sessionId: sessionId, role: 'system', content: budgetWarningMessage);
      }

      await _messages.insertMessage(sessionId: sessionId, role: 'user', content: prompt);
      final turnResult = await runner.executeTurn(
        provider: provider,
        prompt: prompt,
        workingDirectory: cwd,
        profileId: profileId,
        taskId: task.id,
        sessionId: sessionId,
        providerSessionId: providerSessionId,
        model: modelOverride,
        effort: effortOverride,
        appendSystemPrompt: appendSystemPrompt,
        sandboxOverride: sandboxOverride,
      );
      final usage = normalizeWorkflowCliUsage(turnResult);
      providerSessionId = turnResult.providerSessionId.isEmpty ? providerSessionId : turnResult.providerSessionId;
      inputTokens += usage.inputTokens;
      outputTokens += usage.outputTokens;
      cacheReadTokens += usage.cacheReadTokens;
      cacheWriteTokens += usage.cacheWriteTokens;
      await _trackWorkflowSessionUsage(
        sessionId,
        provider: provider,
        usage: usage,
        totalCostUsd: turnResult.totalCostUsd,
      );
      final assistantText = turnResult.structuredOutput != null
          ? jsonEncode(turnResult.structuredOutput)
          : turnResult.responseText;
      await _messages.insertMessage(sessionId: sessionId, role: 'assistant', content: assistantText);
    }

    Map<String, dynamic>? structuredPayload;
    if (structuredSchema != null) {
      structuredPayload = await _tryExtractInlineStructuredPayload(sessionId, structuredSchema);
      if (structuredPayload != null) {
        final outputKey = WorkflowTurnExtractor.structuredOutputKey(structuredSchema);
        if (workflowStepId != null && outputKey != null) {
          _eventRecorder?.recordStructuredOutputInlineUsed(task.id, stepId: workflowStepId, outputKey: outputKey);
        }
      } else {
        final extractionPrompt =
            'Based on your work above, produce the structured output. '
            'Output ONLY the JSON object. Do NOT use any tools.';
        await _messages.insertMessage(sessionId: sessionId, role: 'user', content: extractionPrompt);
        final turnResult = await runner.executeTurn(
          provider: provider,
          prompt: extractionPrompt,
          workingDirectory: cwd,
          profileId: profileId,
          taskId: task.id,
          sessionId: sessionId,
          providerSessionId: providerSessionId,
          model: modelOverride,
          effort: effortOverride,
          maxTurns: provider == 'claude' ? 5 : null,
          jsonSchema: structuredSchema,
          appendSystemPrompt: null,
          sandboxOverride: sandboxOverride,
        );
        final usage = normalizeWorkflowCliUsage(turnResult);
        providerSessionId = turnResult.providerSessionId.isEmpty ? providerSessionId : turnResult.providerSessionId;
        inputTokens += usage.inputTokens;
        outputTokens += usage.outputTokens;
        cacheReadTokens += usage.cacheReadTokens;
        cacheWriteTokens += usage.cacheWriteTokens;
        await _trackWorkflowSessionUsage(
          sessionId,
          provider: provider,
          usage: usage,
          totalCostUsd: turnResult.totalCostUsd,
        );
        structuredPayload = turnResult.structuredOutput;
        await _messages.insertMessage(
          sessionId: sessionId,
          role: 'assistant',
          content: structuredPayload != null ? jsonEncode(structuredPayload) : turnResult.responseText,
        );
      }
    }

    if (repo == null) {
      throw StateError(
        'Workflow one-shot execution requires a WorkflowStepExecutionRepository. '
        'Wire workflowStepExecutionRepository into TaskExecutor before running workflow steps.',
      );
    }
    if (providerSessionId != null && providerSessionId.isNotEmpty) {
      await WorkflowTaskConfig.writeProviderSessionId(task, repo, providerSessionId);
    }
    await WorkflowTaskConfig.writeTokenBreakdown(
      task,
      repo,
      inputTokensNew: cacheReadTokens > inputTokens ? 0 : inputTokens - cacheReadTokens,
      cacheReadTokens: cacheReadTokens,
      outputTokens: outputTokens,
    );
    await _writeWorkflowTokenBreakdownToTaskConfig(
      task,
      inputTokens: inputTokens,
      cacheReadTokens: cacheReadTokens,
      outputTokens: outputTokens,
    );
    if (structuredPayload != null) {
      await WorkflowTaskConfig.writeStructuredOutputPayload(task, repo, structuredPayload);
    }

    return TurnOutcome(
      turnId: 'workflow-oneshot-${task.id}',
      sessionId: sessionId,
      status: TurnStatus.completed,
      responseText: structuredPayload != null ? jsonEncode(structuredPayload) : null,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cacheReadTokens: cacheReadTokens,
      cacheWriteTokens: cacheWriteTokens,
      turnDuration: DateTime.now().difference(startedAt),
      completedAt: DateTime.now(),
    );
  }
}
