import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show TurnProgressAction;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        WorkflowTaskConfig,
        buildFinalizerPrompt,
        SchemaValidator,
        executionEnvelopeDeclaredOutputKeys,
        executionEnvelopeMarkerKey,
        executionEnvelopeOutputsKey,
        executionEnvelopeVersion,
        isExecutionEnvelopeSchema;
import 'package:logging/logging.dart';

import 'task_budget_policy.dart';
import 'task_event_recorder.dart';
import 'task_service.dart';
import 'workflow_cli_runner.dart';
import 'workflow_turn_extractor.dart';

part 'workflow_one_shot_runner_helpers.dart';

/// Executes workflow-owned tasks through the one-shot CLI runner.
final class WorkflowOneShotRunner {
  static const _legacySessionCostFreshInputKey = 'new_input_tokens';

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
    required List<String>? allowedTools,
    required bool readOnly,
    required String? sandboxOverride,
    required Duration stallTimeout,
    required TurnProgressAction stallAction,
    required Duration? defaultStepTimeout,
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
    final stepName = switch (task.configJson[WorkflowTaskConfig.workflowStepName]) {
      final String value when value.trim().isNotEmpty => value,
      _ => workflowStepId,
    };
    final stepTimeout = switch (task.configJson[WorkflowTaskConfig.workflowTimeoutSeconds]) {
      final int seconds when seconds > 0 => Duration(seconds: seconds),
      final num seconds when seconds > 0 => Duration(seconds: seconds.toInt()),
      _ => defaultStepTimeout,
    };
    final mergeResolveEnv = WorkflowTaskConfig.readMergeResolveEnv(task);
    final stepArtifactsEnv = WorkflowTaskConfig.readStepArtifactsEnv(task);
    // Per-task spawn env: the host-computed step-artifacts dir is merged over
    // any merge-resolve entries (distinct names, no collision) so the agent's
    // shell tool call resolves $DARTCLAW_STEP_ARTIFACTS_DIR from the process env.
    final extraEnvironment = <String, String>{...?mergeResolveEnv, ...?stepArtifactsEnv};
    // The host owns the per-step artifacts dir: create it before the first turn
    // so agents (and the review skill's no-mkdir precheck) can rely on it.
    for (final dir in (stepArtifactsEnv ?? const <String, String>{}).values) {
      if (dir.trim().isEmpty) continue;
      try {
        Directory(dir).createSync(recursive: true);
      } on FileSystemException catch (error) {
        _log.warning("Workflow '${task.id}': failed to create step artifacts dir '$dir': $error");
      }
    }
    final startedAt = DateTime.now();
    var inputTokens = 0;
    var outputTokens = 0;
    var cacheReadTokens = 0;
    var cacheWriteTokens = 0;
    final sessionUsageBaseline = providerSessionId != null && providerSessionId.isNotEmpty
        ? await _readSessionUsageBaseline(sessionId)
        : const WorkflowCliUsageBaseline();

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
        stepName: stepName,
        stallTimeout: stallTimeout,
        stallAction: stallAction,
        stepTimeout: stepTimeout,
        allowedTools: allowedTools,
        readOnly: readOnly,
        appendSystemPrompt: appendSystemPrompt,
        sandboxOverride: sandboxOverride,
        extraEnvironment: extraEnvironment,
        usageBaseline: sessionUsageBaseline,
      );
      if (turnResult.cancelled) {
        return _cancelledOutcome(task.id, sessionId: sessionId, startedAt: startedAt);
      }
      final usage = _workflowCliUsage(turnResult);
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

    // Runs one no-tools structured turn (finalizer or legacy extraction),
    // accumulating usage and appending the assistant reply. Returns null when
    // the turn was cancelled during teardown.
    Future<WorkflowCliTurnResult?> runStructuredTurn(String prompt, {required bool noTools}) async {
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
        stepName: stepName,
        stallTimeout: stallTimeout,
        stallAction: stallAction,
        stepTimeout: stepTimeout,
        // No-tools finalizer: empty Claude allowlist + tight turn cap; Codex
        // read-only sandbox (advisory prompt instruction rides in the schema).
        // The cap must leave room for ONE structured-output schema retry: a
        // single rejected StructuredOutput attempt (e.g. the model passing a
        // JSON-encoded string where the schema wants an object) otherwise
        // surfaces as error_max_turns and fails the whole step.
        allowedTools: noTools ? const <String>[] : allowedTools,
        readOnly: noTools ? true : readOnly,
        maxTurns: provider == 'claude' ? (noTools ? 2 : 5) : null,
        jsonSchema: structuredSchema,
        appendSystemPrompt: null,
        sandboxOverride: sandboxOverride,
        extraEnvironment: extraEnvironment,
        usageBaseline: sessionUsageBaseline,
      );
      if (turnResult.cancelled) return turnResult;
      final usage = _workflowCliUsage(turnResult);
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
      await _messages.insertMessage(
        sessionId: sessionId,
        role: 'assistant',
        content: turnResult.structuredOutput != null
            ? jsonEncode(turnResult.structuredOutput)
            : turnResult.responseText,
      );
      return turnResult;
    }

    Map<String, dynamic>? structuredPayload;
    String? finalizerFailureReason;
    if (structuredSchema != null && isExecutionEnvelopeSchema(structuredSchema)) {
      // Standard agent-step completion: always run the no-tools finalization
      // turn (no inline short-circuit), even when the main turn emitted a legacy
      // <workflow-context> block.
      final declaredKeys = executionEnvelopeDeclaredOutputKeys(structuredSchema);
      final eventKey = declaredKeys.isEmpty ? executionEnvelopeOutputsKey : declaredKeys.first;
      final resumableSession = providerSessionId;
      if (resumableSession == null || resumableSession.isEmpty) {
        // No resumable session — a context-free finalizer would fabricate a
        // schema-valid envelope. Charge the workflow retry path instead.
        finalizerFailureReason = 'missing_provider_session';
      } else {
        final finalizerPrompt = buildFinalizerPrompt(structuredSchema);
        var turnResult = await runStructuredTurn(finalizerPrompt, noTools: true);
        if (turnResult != null && turnResult.cancelled) {
          return _cancelledOutcome(task.id, sessionId: sessionId, startedAt: startedAt);
        }
        structuredPayload = turnResult?.structuredOutput;
        if (structuredPayload == null) {
          // One same-session re-ask before charging the workflow retry budget.
          turnResult = await runStructuredTurn(
            '$finalizerPrompt\n\nYour previous response did not contain the required JSON envelope. '
            'Output ONLY the JSON object now.',
            noTools: true,
          );
          if (turnResult != null && turnResult.cancelled) {
            return _cancelledOutcome(task.id, sessionId: sessionId, startedAt: startedAt);
          }
          structuredPayload = turnResult?.structuredOutput;
        }
      }
      // Host-side envelope validation: a non-null payload that does not conform
      // to the strict envelope schema (absent/empty declared `outputs`, missing
      // `step_outcome`) must not be stamped as authoritative — that would advance
      // a finalizer-required step with fabricated success. Route it through the
      // same validation-failure/retry path as a missing envelope.
      if (structuredPayload != null) {
        final schemaWarnings = const SchemaValidator().validate(structuredPayload, structuredSchema);
        if (schemaWarnings.isNotEmpty) {
          _log.warning(
            "Workflow '${task.id}': finalizer envelope failed schema validation: ${schemaWarnings.take(3).join('; ')}",
          );
          structuredPayload = null;
          finalizerFailureReason = 'malformed_envelope';
        }
      }
      if (structuredPayload == null) {
        finalizerFailureReason ??= 'missing_envelope';
        if (workflowStepId != null) {
          _eventRecorder?.recordStructuredOutputValidationFailed(
            task.id,
            stepId: workflowStepId,
            outputKey: eventKey,
            failureReason: finalizerFailureReason,
          );
        }
      } else {
        // Stamp the envelope marker so consumers discriminate envelope vs legacy
        // flat payloads deterministically (never shape-sniffed).
        structuredPayload = {...structuredPayload, executionEnvelopeMarkerKey: executionEnvelopeVersion};
        if (workflowStepId != null) {
          _eventRecorder?.recordStructuredOutputFinalizerUsed(task.id, stepId: workflowStepId, outputKey: eventKey);
        }
      }
    } else if (structuredSchema != null) {
      // Legacy flat-schema fallback (pre-envelope rows / opt-out steps):
      // inline-first, then a second extraction turn.
      structuredPayload = await _tryExtractInlineStructuredPayload(sessionId, structuredSchema);
      if (structuredPayload != null) {
        final outputKey = WorkflowTurnExtractor.structuredOutputKey(structuredSchema);
        if (workflowStepId != null && outputKey != null) {
          _eventRecorder?.recordStructuredOutputInlineUsed(task.id, stepId: workflowStepId, outputKey: outputKey);
        }
      } else {
        final turnResult = await runStructuredTurn(
          'Based on your work above, produce the structured output. '
          'Output ONLY the JSON object. Do NOT use any tools.',
          noTools: false,
        );
        if (turnResult != null && turnResult.cancelled) {
          return _cancelledOutcome(task.id, sessionId: sessionId, startedAt: startedAt);
        }
        structuredPayload = turnResult?.structuredOutput;
      }
    }

    if (repo == null) {
      throw StateError(
        'Workflow one-shot execution requires a WorkflowStepExecutionRepository. '
        'Wire workflowStepExecutionRepository into TaskExecutor before running workflow steps.',
      );
    }
    final finalProviderSessionId = providerSessionId;
    if (finalProviderSessionId != null && finalProviderSessionId.isNotEmpty) {
      await WorkflowTaskConfig.writeProviderSessionId(task, repo, finalProviderSessionId);
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

    // A required finalizer envelope that never materialized is a workflow
    // validation failure eligible for the existing retry path — the lifecycle
    // accepted→succeeded fallback must not advance the run as successful.
    if (finalizerFailureReason != null) {
      return TurnOutcome(
        turnId: 'workflow-oneshot-${task.id}',
        sessionId: sessionId,
        status: TurnStatus.failed,
        errorMessage: 'Workflow finalization envelope was missing or malformed ($finalizerFailureReason)',
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        cacheReadTokens: cacheReadTokens,
        cacheWriteTokens: cacheWriteTokens,
        turnDuration: DateTime.now().difference(startedAt),
        completedAt: DateTime.now(),
      );
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

  TurnOutcome _cancelledOutcome(String taskId, {required String sessionId, required DateTime startedAt}) {
    final completedAt = DateTime.now();
    return TurnOutcome(
      turnId: 'workflow-oneshot-$taskId',
      sessionId: sessionId,
      status: TurnStatus.cancelled,
      turnDuration: completedAt.difference(startedAt),
      completedAt: completedAt,
    );
  }
}
