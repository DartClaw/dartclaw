part of 'workflow_executor.dart';

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
    required ResolvedStepConfig resolved,
    required MapStepContext mapCtx,
    required WorkflowContext context,
    required bool promotionAware,
    required String? integrationBranch,
    required String promotionStrategy,
    required Set<String> promotedIds,
  }) async {
    final taskId = _uuid.v4();

    // Subscribe before create to avoid race condition. Listener is synchronous
    // and filters the transient retry-in-progress signal so the SQLite read
    // can never race a teardown — same pattern as step_dispatcher's Phase 0
    // fix (S64).
    final completer = Completer<Task>();
    final sub = _eventBus.on<TaskStatusChangedEvent>().where((e) => e.taskId == taskId).listen((event) {
      if (event.newStatus == TaskStatus.failed && event.trigger == 'retry-in-progress') {
        // Transient failed state before a task-level retry re-queues. The
        // matching queued(trigger:'retry') event will follow synchronously;
        // no DB read or delay needed — just ignore this transition.
        return;
      }
      if (event.newStatus == TaskStatus.queued || event.newStatus == TaskStatus.running) {
        // Task re-queued for retry or still active — not terminal.
        return;
      }
      if (event.newStatus.terminal && !completer.isCompleted) {
        _taskService.get(taskId).then((t) {
          if (t != null && !completer.isCompleted) completer.complete(t);
        });
      }
    });

    try {
      final mapTaskConfig = {
        ...taskConfig,
        '_mapStepId': step.id,
        '_mapIterationIndex': iterIndex,
        '_mapIterationTotal': mapCtx.collection.length,
      };
      await _createWorkflowTaskTriple(
        taskId: taskId,
        run: run,
        step: step,
        stepIndex: stepIndex,
        title: iterTitle,
        description: iterPrompt,
        type: TaskType.coding,
        provider: resolved.provider,
        projectId: projectId,
        maxTokens: resolved.maxTokens,
        maxRetries: resolved.maxRetries ?? 0,
        taskConfig: mapTaskConfig,
      );
    } catch (e, st) {
      await sub.cancel();
      WorkflowExecutor._log.severe(
        "Workflow '${run.id}': map step '${step.id}' iteration $iterIndex "
        'failed to create task: $e',
        e,
        st,
      );
      mapCtx.recordFailure(iterIndex, 'Failed to create task: $e', null);
      mapCtx.inFlightCount--;
      _eventBus.fire(
        MapIterationCompletedEvent(
          runId: run.id,
          stepId: step.id,
          iterationIndex: iterIndex,
          totalIterations: mapCtx.collection.length,
          itemId: mapCtx.itemId(iterIndex),
          taskId: taskId,
          success: false,
          tokenCount: 0,
          timestamp: DateTime.now(),
        ),
      );
      await _persistMapProgress(run, step, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
      return;
    }

    late Task finalTask;
    try {
      finalTask = await _waitForTaskCompletion(taskId, step, completer, sub, runId: run.id);
    } on TimeoutException {
      WorkflowExecutor._log.warning(
        "Workflow '${run.id}': map step '${step.id}' iteration $iterIndex "
        'timed out after ${step.timeoutSeconds}s',
      );
      mapCtx.recordFailure(iterIndex, 'Timed out after ${step.timeoutSeconds}s', taskId);
      mapCtx.inFlightCount--;
      _eventBus.fire(
        MapIterationCompletedEvent(
          runId: run.id,
          stepId: step.id,
          iterationIndex: iterIndex,
          totalIterations: mapCtx.collection.length,
          itemId: mapCtx.itemId(iterIndex),
          taskId: taskId,
          success: false,
          tokenCount: 0,
          timestamp: DateTime.now(),
        ),
      );
      await _persistMapProgress(run, step, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
      return;
    } catch (e, st) {
      WorkflowExecutor._log.severe(
        "Workflow '${run.id}': map step '${step.id}' iteration $iterIndex "
        'wait failed: $e',
        e,
        st,
      );
      mapCtx.recordFailure(iterIndex, 'Unexpected error: $e', taskId);
      mapCtx.inFlightCount--;
      _eventBus.fire(
        MapIterationCompletedEvent(
          runId: run.id,
          stepId: step.id,
          iterationIndex: iterIndex,
          totalIterations: mapCtx.collection.length,
          itemId: mapCtx.itemId(iterIndex),
          taskId: taskId,
          success: false,
          tokenCount: 0,
          timestamp: DateTime.now(),
        ),
      );
      await _persistMapProgress(run, step, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
      return;
    }

    final taskFailed = finalTask.status == TaskStatus.failed || finalTask.status == TaskStatus.cancelled;

    int tokenCount = 0;
    if (!taskFailed) {
      tokenCount = await _readStepTokenCount(finalTask);
      Map<String, dynamic> outputs = {};
      void persistIterationOutputs() {
        for (final entry in outputs.entries) {
          context['${step.id}[$iterIndex].${entry.key}'] = entry.value;
        }
        context['${step.id}[$iterIndex].tokenCount'] = tokenCount;
      }

      void emitIterationFailure() {
        _eventBus.fire(
          MapIterationCompletedEvent(
            runId: run.id,
            stepId: step.id,
            iterationIndex: iterIndex,
            totalIterations: mapCtx.collection.length,
            itemId: mapCtx.itemId(iterIndex),
            taskId: taskId,
            success: false,
            tokenCount: tokenCount,
            timestamp: DateTime.now(),
          ),
        );
      }

      StepValidationFailure? extractionFailure;
      try {
        outputs = await _contextExtractor.extract(step, finalTask, effectiveOutputs: _effectiveOutputsFor(step));
      } on MissingArtifactFailure catch (e, st) {
        extractionFailure = StepValidationFailure(reason: e.toString(), missingArtifacts: e.missingPaths);
        WorkflowExecutor._log.warning(
          "Workflow '${run.id}': context extraction failed for map step '${step.id}' "
          'iteration $iterIndex: $e',
          e,
          st,
        );
      } on StateError catch (e, st) {
        extractionFailure = StepValidationFailure(reason: e.message);
        WorkflowExecutor._log.warning(
          "Workflow '${run.id}': context extraction failed for map step '${step.id}' "
          'iteration $iterIndex: $e',
          e,
          st,
        );
      } catch (e, st) {
        WorkflowExecutor._log.warning(
          "Workflow '${run.id}': context extraction failed for map step '${step.id}' "
          'iteration $iterIndex: $e',
          e,
          st,
        );
      }
      if (extractionFailure != null) {
        persistIterationOutputs();
        mapCtx.recordFailure(iterIndex, extractionFailure.reason, taskId);
        await _persistMapProgress(run, step, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
        mapCtx.inFlightCount--;
        emitIterationFailure();
        return;
      }

      // Build result value.
      dynamic resultValue;
      if (finalTask.configJson['_workflowNeedsWorktree'] == true || finalTask.worktreeJson != null) {
        resultValue = await _buildCodingResult(finalTask, outputs);
      } else if (outputs.length == 1) {
        resultValue = outputs.values.first;
      } else {
        resultValue = outputs;
      }

      if (promotionAware) {
        final storyBranch = (finalTask.worktreeJson?['branch'] as String?)?.trim();
        final promote = _turnAdapter?.promoteWorkflowBranch;
        final branch = storyBranch;
        final promotionProjectId = projectId?.trim();
        final storyId = mapCtx.itemId(iterIndex);
        if (promote == null) {
          persistIterationOutputs();
          mapCtx.recordFailure(iterIndex, 'promotion failed: host promotion callback is not configured', taskId);
          await _persistMapProgress(run, step, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
          mapCtx.inFlightCount--;
          emitIterationFailure();
          return;
        }
        if (promotionProjectId == null || promotionProjectId.isEmpty) {
          persistIterationOutputs();
          mapCtx.recordFailure(iterIndex, 'promotion failed: map iteration has no project binding', taskId);
          await _persistMapProgress(run, step, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
          mapCtx.inFlightCount--;
          emitIterationFailure();
          return;
        }
        if (branch == null || branch.isEmpty) {
          persistIterationOutputs();
          mapCtx.recordFailure(iterIndex, 'promotion failed: task worktree branch is unavailable', taskId);
          await _persistMapProgress(run, step, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
          mapCtx.inFlightCount--;
          emitIterationFailure();
          return;
        }
        if (integrationBranch == null || integrationBranch.isEmpty) {
          persistIterationOutputs();
          mapCtx.recordFailure(iterIndex, 'promotion failed: integration branch is not initialized', taskId);
          await _persistMapProgress(run, step, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
          mapCtx.inFlightCount--;
          emitIterationFailure();
          return;
        }

        final promotionResult = await promote(
          runId: run.id,
          projectId: promotionProjectId,
          branch: branch,
          integrationBranch: integrationBranch,
          strategy: promotionStrategy,
          storyId: storyId,
        );
        switch (promotionResult) {
          case WorkflowGitPromotionSuccess(:final commitSha):
            if (storyId != null && storyId.isNotEmpty) {
              promotedIds.add(storyId);
            }
            context['${step.id}[$iterIndex].promotion'] = 'success';
            context['${step.id}[$iterIndex].promotion_sha'] = commitSha;
          case WorkflowGitPromotionConflict(:final conflictingFiles, :final details):
            final conflictMessage =
                'promotion-conflict: ${conflictingFiles.isEmpty ? 'merge conflict' : conflictingFiles.join(', ')}';
            context['${step.id}[$iterIndex].promotion'] = 'conflict';
            context['${step.id}[$iterIndex].promotion_details'] = details;
            persistIterationOutputs();
            mapCtx.recordFailure(iterIndex, conflictMessage, taskId);
            await _persistMapProgress(run, step, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
            mapCtx.inFlightCount--;
            emitIterationFailure();
            return;
          case WorkflowGitPromotionError(:final message):
            context['${step.id}[$iterIndex].promotion'] = 'failed';
            persistIterationOutputs();
            mapCtx.recordFailure(iterIndex, 'promotion failed: $message', taskId);
            await _persistMapProgress(run, step, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
            mapCtx.inFlightCount--;
            emitIterationFailure();
            return;
          case WorkflowGitPromotionSerializeRemaining():
            // This dispatcher does not participate in serialize-remaining; treat as error.
            mapCtx.recordFailure(iterIndex, 'promotion failed: unexpected serialize-remaining sentinel', taskId);
            await _persistMapProgress(run, step, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
            mapCtx.inFlightCount--;
            emitIterationFailure();
            return;
        }
      }

      // Persist per-iteration outputs (extraction results, token counts, status).
      persistIterationOutputs();
      mapCtx.recordResult(iterIndex, resultValue);
    } else {
      final reason = finalTask.configJson['failReason'] as String?;
      final msg = reason ?? finalTask.status.name;
      mapCtx.recordFailure(iterIndex, msg, taskId);
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
        taskId: taskId,
        success: !taskFailed,
        tokenCount: tokenCount,
        timestamp: DateTime.now(),
      ),
    );
  }
}
