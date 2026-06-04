part of 'workflow_executor.dart';

final class _MapIterationAttempt {
  const _MapIterationAttempt({
    required this.taskId,
    required this.isFailedOutcome,
    required this.message,
    required this.tokenCount,
    required this.outputs,
    required this.resultValue,
    required this.task,
    this.retryable = true,
    this.aborted = false,
  });

  final String? taskId;
  final bool isFailedOutcome;
  final String? message;
  final int tokenCount;
  final Map<String, dynamic> outputs;
  final dynamic resultValue;
  final Task? task;

  /// Whether a failed outcome is eligible for workflow retry. Only post-dispatch
  /// outcome failures (task crash, validation failure, missing artifact) retry;
  /// infra failures (task-creation error, timeout, unexpected wait error) are
  /// terminal, matching the single-step dispatcher and OC02's retry-trigger set.
  final bool retryable;

  /// Set when the run left `running` (pause/cancel) mid-wait. The item stops
  /// without being recorded as a failure, mirroring the single-step abort path.
  final bool aborted;

  bool get succeeded => !isFailedOutcome && message == null && !aborted;
}

/// Runs one direct map iteration.
extension WorkflowExecutorMapIterationDispatcher on WorkflowExecutor {
  /// Executes a single map iteration: creates a task, awaits completion,
  /// extracts outputs, records result in [mapCtx], fires [MapIterationCompletedEvent].
  Future<void> _dispatchIteration({
    required WorkflowRun run,
    required WorkflowDefinition definition,
    required WorkflowStep step,
    required int stepIndex,
    required int iterIndex,
    required String iterPrompt,
    required String iterTitle,
    required Map<String, dynamic> taskConfig,
    required String? projectId,
    required String? provider,
    required ResolvedStepConfig resolved,
    required MapStepContext mapCtx,
    required WorkflowContext context,
    required bool promotionAware,
    required String? integrationBranch,
    required String promotionStrategy,
    required Set<String> promotedIds,
  }) async {
    Future<void> persistProgress() =>
        _persistMapProgress(run, step, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);

    Future<void> failAndReturn(String message, String? taskId, {int iterTokens = 0}) =>
        recordIterationFailureAndDecrement(
          _eventBus,
          mapCtx: mapCtx,
          iterIndex: iterIndex,
          failureMessage: message,
          taskId: taskId,
          run: run,
          step: step,
          iterTokens: iterTokens,
          persistProgress: persistProgress,
        );

    void persistIterationOutputs(Map<String, dynamic> outputs, int tokenCount) {
      for (final entry in outputs.entries) {
        context['${step.id}[$iterIndex].${entry.key}'] = entry.value;
      }
      context['${step.id}[$iterIndex].tokenCount'] = tokenCount;
    }

    var accumulatedTokenCount = 0;
    final finalAttempt = await runWithWorkflowRetry<_MapIterationAttempt>(
      onFailure: step.onFailure,
      maxRetries: resolved.maxRetries ?? 0,
      isFailedOutcome: (attempt) => attempt.isFailedOutcome && attempt.retryable,
      failureReason: (attempt) => attempt.message,
      onRetry: (retryNumber, retryLimit, _) {
        WorkflowExecutor._log.info(
          "Workflow '${run.id}': retrying map step '${step.id}' iteration $iterIndex "
          'after failed outcome ($retryNumber/$retryLimit)',
        );
      },
      dispatchAttempt: (_) async {
        final attempt = await _dispatchIterationAttempt(
          run: run,
          definition: definition,
          step: step,
          stepIndex: stepIndex,
          iterIndex: iterIndex,
          iterPrompt: iterPrompt,
          iterTitle: iterTitle,
          taskConfig: taskConfig,
          projectId: projectId,
          provider: provider,
          resolved: resolved,
          mapCtx: mapCtx,
          context: context,
        );
        accumulatedTokenCount += attempt.tokenCount;
        return attempt;
      },
    );

    if (finalAttempt.aborted) {
      // Run left `running` (pause/cancel) mid-wait: stop the item without
      // recording a failure and flag the step so the runner stops dispatching
      // siblings and returns null (the executor then exits without completing
      // the run). The runner's whenComplete resets inFlightCount.
      mapCtx.aborted = true;
      WorkflowExecutor._log.info(
        "Workflow '${run.id}': map step '${step.id}' iteration $iterIndex wait aborted; run no longer running",
      );
      return;
    }

    if (finalAttempt.succeeded) {
      if (promotionAware) {
        final promotionFailure = await _promoteMapIteration(
          run: run,
          step: step,
          iterIndex: iterIndex,
          mapCtx: mapCtx,
          context: context,
          task: finalAttempt.task!,
          taskId: finalAttempt.taskId!,
          projectId: projectId,
          integrationBranch: integrationBranch,
          promotionStrategy: promotionStrategy,
          promotedIds: promotedIds,
          tokenCount: accumulatedTokenCount,
          failAndReturn: failAndReturn,
          persistIterationOutputs: () => persistIterationOutputs(finalAttempt.outputs, accumulatedTokenCount),
        );
        if (promotionFailure) return;
      }
      persistIterationOutputs(finalAttempt.outputs, accumulatedTokenCount);
      mapCtx.recordResult(iterIndex, finalAttempt.resultValue);
    } else {
      if (finalAttempt.outputs.isNotEmpty) {
        persistIterationOutputs(finalAttempt.outputs, accumulatedTokenCount);
      }
      await failAndReturn(finalAttempt.message ?? 'failed', finalAttempt.taskId, iterTokens: accumulatedTokenCount);
      return;
    }

    await _persistMapProgress(run, step, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);

    mapCtx.inFlightCount--;

    _eventBus.fire(
      MapIterationCompletedEvent(
        runId: run.id,
        stepId: step.id,
        iterationIndex: iterIndex,
        totalIterations: mapCtx.collection.length,
        itemId: mapCtx.itemId(iterIndex),
        taskId: finalAttempt.taskId ?? '',
        success: finalAttempt.succeeded,
        tokenCount: accumulatedTokenCount,
        timestamp: DateTime.now(),
      ),
    );
  }

  Future<_MapIterationAttempt> _dispatchIterationAttempt({
    required WorkflowRun run,
    required WorkflowDefinition definition,
    required WorkflowStep step,
    required int stepIndex,
    required int iterIndex,
    required String iterPrompt,
    required String iterTitle,
    required Map<String, dynamic> taskConfig,
    required String? projectId,
    required String? provider,
    required ResolvedStepConfig resolved,
    required MapStepContext mapCtx,
    required WorkflowContext context,
  }) async {
    final taskId = _uuid.v4();
    final completer = Completer<Task>();
    final sub = _eventBus.on<TaskStatusChangedEvent>().where((e) => e.taskId == taskId).listen((event) {
      if (event.newStatus == TaskStatus.failed && event.trigger == 'retry-in-progress') return;
      if (event.newStatus == TaskStatus.queued || event.newStatus == TaskStatus.running) return;
      if (event.newStatus.terminal && !completer.isCompleted) {
        _taskService.get(taskId).then((task) {
          if (task != null && !completer.isCompleted) completer.complete(task);
        });
      }
    });

    try {
      final displayScope = mapCtx.itemId(iterIndex);
      final mapTaskConfig = {
        ...taskConfig,
        '_mapStepId': step.id,
        '_mapIterationIndex': iterIndex,
        '_mapIterationTotal': mapCtx.collection.length,
      };
      if (displayScope != null) {
        mapTaskConfig['displayScope'] = displayScope;
      }
      await _createWorkflowTaskTriple(
        taskId: taskId,
        run: run,
        step: step,
        stepIndex: stepIndex,
        title: iterTitle,
        description: iterPrompt,
        type: TaskType.coding,
        provider: provider,
        projectId: projectId,
        maxTokens: resolved.maxTokens,
        taskConfig: mapTaskConfig,
      );
    } catch (e, st) {
      await sub.cancel();
      WorkflowExecutor._log.severe(
        "Workflow '${run.id}': map step '${step.id}' iteration $iterIndex failed to create task: $e",
        e,
        st,
      );
      return _MapIterationAttempt(
        taskId: null,
        isFailedOutcome: true,
        retryable: false,
        message: 'Failed to create task: $e',
        tokenCount: 0,
        outputs: const {},
        resultValue: null,
        task: null,
      );
    }

    late Task finalTask;
    try {
      finalTask = await _waitForTaskCompletion(taskId, step, completer, sub, runId: run.id);
    } on TimeoutException {
      WorkflowExecutor._log.warning(
        "Workflow '${run.id}': map step '${step.id}' iteration $iterIndex timed out after ${step.timeoutSeconds}s",
      );
      return _MapIterationAttempt(
        taskId: taskId,
        isFailedOutcome: true,
        retryable: false,
        message: 'Timed out after ${step.timeoutSeconds}s',
        tokenCount: 0,
        outputs: const {},
        resultValue: null,
        task: null,
      );
    } on _WorkflowRunWaitAbort catch (e) {
      WorkflowExecutor._log.info(
        "Workflow '${run.id}': map step '${step.id}' iteration $iterIndex wait aborted: ${e.message}",
      );
      return _MapIterationAttempt(
        taskId: taskId,
        isFailedOutcome: false,
        aborted: true,
        message: null,
        tokenCount: 0,
        outputs: const {},
        resultValue: null,
        task: null,
      );
    } catch (e, st) {
      WorkflowExecutor._log.severe(
        "Workflow '${run.id}': map step '${step.id}' iteration $iterIndex wait failed: $e",
        e,
        st,
      );
      return _MapIterationAttempt(
        taskId: taskId,
        isFailedOutcome: true,
        retryable: false,
        message: 'Unexpected error: $e',
        tokenCount: 0,
        outputs: const {},
        resultValue: null,
        task: null,
      );
    }

    final tokenCount = await _readStepTokenCount(finalTask);
    final taskFailed = finalTask.status == TaskStatus.failed || finalTask.status == TaskStatus.cancelled;
    if (taskFailed) {
      final reason = finalTask.configJson['failReason'] as String?;
      return _MapIterationAttempt(
        taskId: taskId,
        isFailedOutcome: true,
        message: reason ?? finalTask.status.name,
        tokenCount: tokenCount,
        outputs: const {},
        resultValue: null,
        task: finalTask,
      );
    }

    Map<String, dynamic> outputs = {};
    StepValidationFailure? extractionFailure;
    try {
      outputs = await _contextExtractor.extract(step, finalTask, effectiveOutputs: effectiveOutputsFor(step));
    } on MissingArtifactFailure catch (e, st) {
      extractionFailure = StepValidationFailure(reason: e.toString(), missingArtifacts: e.missingPaths);
      WorkflowExecutor._log.warning(
        "Workflow '${run.id}': context extraction failed for map step '${step.id}' iteration $iterIndex: $e",
        e,
        st,
      );
    } on StateError catch (e, st) {
      extractionFailure = StepValidationFailure(reason: e.message);
      WorkflowExecutor._log.warning(
        "Workflow '${run.id}': context extraction failed for map step '${step.id}' iteration $iterIndex: $e",
        e,
        st,
      );
    } catch (e, st) {
      extractionFailure = StepValidationFailure(reason: e.toString());
      WorkflowExecutor._log.warning(
        "Workflow '${run.id}': context extraction failed for map step '${step.id}' iteration $iterIndex: $e",
        e,
        st,
      );
    }
    if (extractionFailure != null) {
      return _MapIterationAttempt(
        taskId: taskId,
        isFailedOutcome: true,
        message: extractionFailure.reason,
        tokenCount: tokenCount,
        outputs: outputs,
        resultValue: null,
        task: finalTask,
      );
    }

    final (outcome, outcomeReason) = await _resolveStepOutcome(step, finalTask, runId: run.id);
    if (outcome == 'failed') {
      final reason = (outcomeReason != null && outcomeReason.isNotEmpty)
          ? outcomeReason
          : (finalTask.configJson['failReason'] as String?) ?? finalTask.status.name;
      return _MapIterationAttempt(
        taskId: taskId,
        isFailedOutcome: true,
        message: reason,
        tokenCount: tokenCount,
        outputs: outputs,
        resultValue: null,
        task: finalTask,
      );
    }

    dynamic resultValue;
    if (finalTask.configJson['_workflowNeedsWorktree'] == true || finalTask.worktreeJson != null) {
      resultValue = await _buildCodingResult(finalTask, outputs);
    } else if (outputs.length == 1) {
      resultValue = outputs.values.first;
    } else {
      resultValue = outputs;
    }

    return _MapIterationAttempt(
      taskId: taskId,
      isFailedOutcome: false,
      message: null,
      tokenCount: tokenCount,
      outputs: outputs,
      resultValue: resultValue,
      task: finalTask,
    );
  }

  Future<bool> _promoteMapIteration({
    required WorkflowRun run,
    required WorkflowStep step,
    required int iterIndex,
    required MapStepContext mapCtx,
    required WorkflowContext context,
    required Task task,
    required String taskId,
    required String? projectId,
    required String? integrationBranch,
    required String promotionStrategy,
    required Set<String> promotedIds,
    required int tokenCount,
    required Future<void> Function(String message, String? taskId, {int iterTokens}) failAndReturn,
    required void Function() persistIterationOutputs,
  }) async {
    final storyBranch = (task.worktreeJson?['branch'] as String?)?.trim();
    final promote = _turnAdapter?.promoteWorkflowBranch;
    final promotionProjectId = projectId?.trim();
    final storyId = mapCtx.itemId(iterIndex);
    if (promote == null) {
      persistIterationOutputs();
      await failAndReturn(
        'promotion failed: host promotion callback is not configured',
        taskId,
        iterTokens: tokenCount,
      );
      return true;
    }
    if (promotionProjectId == null || promotionProjectId.isEmpty) {
      persistIterationOutputs();
      await failAndReturn('promotion failed: map iteration has no project binding', taskId, iterTokens: tokenCount);
      return true;
    }
    if (storyBranch == null || storyBranch.isEmpty) {
      persistIterationOutputs();
      await failAndReturn('promotion failed: task worktree branch is unavailable', taskId, iterTokens: tokenCount);
      return true;
    }
    if (integrationBranch == null || integrationBranch.isEmpty) {
      persistIterationOutputs();
      await failAndReturn('promotion failed: integration branch is not initialized', taskId, iterTokens: tokenCount);
      return true;
    }

    final promotionResult = await callPromote(
      promote: promote,
      runId: run.id,
      projectId: promotionProjectId,
      branch: storyBranch,
      integrationBranch: integrationBranch,
      strategy: promotionStrategy,
      storyId: storyId,
      conflictingFiles: const [],
      conflictDetails: '',
      mergeResolveEnabled: false,
    );
    switch (promotionResult) {
      case PromotionSuccess(:final commitSha):
        if (storyId != null && storyId.isNotEmpty) {
          promotedIds.add(storyId);
        }
        context['${step.id}[$iterIndex].promotion'] = 'success';
        context['${step.id}[$iterIndex].promotion_sha'] = commitSha;
        return false;
      case PromotionConflict(:final conflictingFiles, :final details):
        context['${step.id}[$iterIndex].promotion'] = 'conflict';
        context['${step.id}[$iterIndex].promotion_details'] = details;
        persistIterationOutputs();
        await failAndReturn(
          'promotion-conflict: ${conflictingFiles.isEmpty ? 'merge conflict' : conflictingFiles.join(', ')}',
          taskId,
          iterTokens: tokenCount,
        );
        return true;
      case PromotionError(:final failureMessage):
        context['${step.id}[$iterIndex].promotion'] = 'failed';
        persistIterationOutputs();
        await failAndReturn(failureMessage, taskId, iterTokens: tokenCount);
        return true;
      case PromotionSerializeRemaining():
        await failAndReturn(
          'promotion failed: unexpected serialize-remaining sentinel',
          taskId,
          iterTokens: tokenCount,
        );
        return true;
      case PromotionNotConfigured():
      case PromotionNoProjectBinding():
      case PromotionNoBranch():
      case PromotionNoIntegrationBranch():
        return false;
    }
  }
}
