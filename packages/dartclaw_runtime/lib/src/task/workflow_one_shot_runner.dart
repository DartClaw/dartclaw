import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        SchemaValidator,
        WorkflowStepExecutionRepository,
        WorkflowTaskConfig,
        buildFinalizerPrompt,
        executionEnvelopeDeclaredOutputKeys,
        executionEnvelopeMarkerKey,
        executionEnvelopeOutputsKey,
        executionEnvelopeVersion;
import 'package:logging/logging.dart';

import '../governance/budget_engine.dart';
import '../turn_runner.dart';
import 'step_turn_runner.dart';
import 'task_budget_policy.dart';
import 'task_event_recorder.dart';
import 'task_service.dart';

part 'workflow_one_shot_runner_helpers.dart';

/// Executes workflow-owned tasks through the shared guarded turn runner.
final class WorkflowOneShotRunner {
  static ({String? artifactsDir, Map<String, String>? spawnEnvironment}) constructionInputs(Task task) {
    final spawnEnvironment = <String, String>{
      ...?WorkflowTaskConfig.readMergeResolveEnv(task),
      ...?WorkflowTaskConfig.readStepArtifactsEnv(task),
    };
    return (
      artifactsDir: WorkflowTaskConfig.readStepArtifactsDir(task),
      spawnEnvironment: spawnEnvironment.isEmpty ? null : spawnEnvironment,
    );
  }

  static void createArtifactsDirectory(Task task) {
    final artifactsDir = WorkflowTaskConfig.readStepArtifactsDir(task);
    if (artifactsDir != null) Directory(artifactsDir).createSync(recursive: true);
  }

  new({
    required WorkflowStepExecutionRepository? workflowStepExecutionRepository,
    required MessageService messages,
    required TaskBudgetPolicy budgetPolicy,
    required TaskService tasks,
    TaskEventRecorder? eventRecorder,
    EventBus? eventBus,
    Logger? log,
  }) : _workflowStepExecutionRepository = workflowStepExecutionRepository,
       _messages = messages,
       _budgetPolicy = budgetPolicy,
       _tasks = tasks,
       _eventRecorder = eventRecorder,
       _eventBus = eventBus,
       _log = log ?? Logger('WorkflowOneShotRunner');

  final WorkflowStepExecutionRepository? _workflowStepExecutionRepository;
  final MessageService _messages;
  final TaskBudgetPolicy _budgetPolicy;
  final TaskService _tasks;
  final TaskEventRecorder? _eventRecorder;
  final EventBus? _eventBus;
  final Logger _log;

  Future<TurnOutcome> execute(
    Task task, {
    required TurnRunner runner,
    required String sessionId,
    required String pendingMessage,
    required String provider,
    required String? workingDirectory,
    required String? modelOverride,
    required String? effortOverride,
    required List<String>? allowedTools,
    required bool readOnly,
  }) async {
    final repo = _workflowStepExecutionRepository;
    final workflowStepExecution = task.workflowStepExecution;
    final workflowStepId = workflowStepExecution?.stepId;
    final followUps = workflowStepExecution?.followUpPrompts ?? const <String>[];
    final structuredSchema = workflowStepExecution?.structuredSchema;
    String? providerSessionId = workflowStepExecution?.providerSessionId;
    final stepTimeout = switch (task.configJson[WorkflowTaskConfig.workflowTurnTimeoutSeconds]) {
      final int seconds when seconds >= 0 => Duration(seconds: seconds),
      final num seconds when seconds >= 0 => Duration(seconds: seconds.toInt()),
      _ => null,
    };
    final startedAt = DateTime.now();
    var inputTokens = 0;
    var outputTokens = 0;
    var cacheReadTokens = 0;
    var cacheWriteTokens = 0;
    var turnIndex = 0;
    final stepRunner = StepTurnRunner(runner);

    void accumulateUsage(TurnOutcome outcome) {
      providerSessionId = outcome.providerSessionId?.isNotEmpty == true ? outcome.providerSessionId : providerSessionId;
      inputTokens += outcome.inputTokens;
      outputTokens += outcome.outputTokens;
      cacheReadTokens += outcome.cacheReadTokens;
      cacheWriteTokens += outcome.cacheWriteTokens;
      if (outcome.status != TurnStatus.completed) return;
      turnIndex++;
      _eventBus?.fire(
        WorkflowCliTurnProgressEvent(
          taskId: task.id,
          sessionId: sessionId,
          provider: provider,
          turnIndex: turnIndex,
          cumulativeTokens: inputTokens + outputTokens,
          inputTokens: inputTokens,
          outputTokens: outputTokens,
          cacheReadTokens: cacheReadTokens,
          cacheWriteTokens: cacheWriteTokens,
          timestamp: DateTime.now(),
        ),
      );
    }

    TurnOutcome aggregate(TurnOutcome outcome) => TurnOutcome(
      turnId: outcome.turnId,
      sessionId: sessionId,
      status: outcome.status,
      responseText: outcome.responseText,
      errorMessage: outcome.errorMessage,
      limitBreach: outcome.limitBreach,
      structuredOutput: outcome.structuredOutput,
      providerSessionId: outcome.providerSessionId,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cacheReadTokens: cacheReadTokens,
      cacheWriteTokens: cacheWriteTokens,
      turnDuration: DateTime.now().difference(startedAt),
      completedAt: DateTime.now(),
    );

    Future<TurnOutcome> runTurn(
      String prompt, {
      List<String>? turnAllowedTools,
      bool turnReadOnly = false,
      int? maxTurns,
      Map<String, dynamic>? outputSchema,
    }) async {
      await _messages.insertMessage(sessionId: sessionId, role: 'user', content: prompt);
      final messages = await _sessionHistory(sessionId);
      if ((await _tasks.get(task.id))?.status == TaskStatus.cancelled) {
        return TurnOutcome(
          turnId: 'workflow-oneshot-cancelled',
          sessionId: sessionId,
          status: TurnStatus.cancelled,
          completedAt: DateTime.now(),
        );
      }
      final outcome = await stepRunner.runStepTurn(
        sessionId: sessionId,
        messages: messages,
        directory: workingDirectory,
        model: modelOverride,
        effort: effortOverride,
        taskId: task.id,
        allowedTools: turnAllowedTools,
        readOnly: turnReadOnly,
        maxTurns: maxTurns,
        outputSchema: outputSchema,
        providerSessionId: providerSessionId,
        requestProviderSessionResume: structuredSchema != null && providerSessionId == null,
        turnTimeout: stepTimeout,
      );
      accumulateUsage(outcome);
      return outcome;
    }

    for (final prompt in <String>[pendingMessage, ...followUps]) {
      final (budgetOutcome, budgetWarningMessage) = await _budgetPolicy.checkBudget(task, sessionId);
      if (budgetOutcome == BudgetOutcome.exceeded) {
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
      final outcome = await runTurn(prompt, turnAllowedTools: allowedTools, turnReadOnly: readOnly);
      if (outcome.status != TurnStatus.completed) return aggregate(outcome);
    }

    Map<String, dynamic>? structuredPayload;
    String? finalizerFailureReason;
    if (structuredSchema != null) {
      final declaredKeys = executionEnvelopeDeclaredOutputKeys(structuredSchema);
      final eventKey = declaredKeys.isEmpty ? executionEnvelopeOutputsKey : declaredKeys.first;
      if (providerSessionId == null || providerSessionId!.isEmpty) {
        finalizerFailureReason = 'missing_provider_session';
      } else {
        final finalizerPrompt = buildFinalizerPrompt(structuredSchema);
        var outcome = await runTurn(
          finalizerPrompt,
          turnAllowedTools: const <String>[],
          turnReadOnly: true,
          maxTurns: 2,
          outputSchema: structuredSchema,
        );
        if (outcome.status != TurnStatus.completed) return aggregate(outcome);
        structuredPayload = _finalizerEnvelope(outcome);
        if (structuredPayload == null) {
          outcome = await runTurn(
            '$finalizerPrompt\n\nYour previous response did not contain the required JSON envelope. '
            'Output ONLY the JSON object now.',
            turnAllowedTools: const <String>[],
            turnReadOnly: true,
            maxTurns: 2,
            outputSchema: structuredSchema,
          );
          if (outcome.status != TurnStatus.completed) return aggregate(outcome);
          structuredPayload = _finalizerEnvelope(outcome);
        }
      }
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
        structuredPayload = {...structuredPayload, executionEnvelopeMarkerKey: executionEnvelopeVersion};
        if (workflowStepId != null) {
          _eventRecorder?.recordStructuredOutputFinalizerUsed(task.id, stepId: workflowStepId, outputKey: eventKey);
        }
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

  Future<List<Map<String, dynamic>>> _sessionHistory(String sessionId) async =>
      (await _messages.getMessages(sessionId))
          .map(
            (message) => <String, dynamic>{
              'id': message.id,
              'sessionId': message.sessionId,
              'role': message.role,
              'content': message.content,
              'cursor': message.cursor,
              'metadata': message.metadata,
              'createdAt': message.createdAt.toIso8601String(),
            },
          )
          .toList(growable: false);
}

/// The finalizer envelope for [outcome], from the provider when it enforced the
/// schema and otherwise from the reply body.
///
/// The finalizer prompt declares one shape — "Output ONLY the JSON object
/// matching the provided schema" — so reading the body as that object is
/// reading the declared contract, not recovering prose. It runs once, only when
/// the provider returned nothing structured, with no second strategy and no
/// repair: a reply that is not that object yields null and takes the existing
/// single retry, then `missing_envelope`. Whatever is returned still faces
/// `SchemaValidator`.
///
/// Codex needs this. Its harness parses no envelope — the extraction lived in
/// the one-shot provider stack 0.25 deleted, and the guarded harness path never
/// gained it — so `structuredOutput` is always null there.
Map<String, dynamic>? _finalizerEnvelope(TurnOutcome outcome) {
  final provided = outcome.structuredOutput;
  if (provided != null) return provided;
  final body = outcome.responseText?.trim();
  if (body == null || body.isEmpty) return null;
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map || decoded.isEmpty) return null;
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  } on FormatException {
    return null;
  }
}
