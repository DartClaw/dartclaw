part of 'workflow_executor.dart';
extension WorkflowExecutorForeachIterationRunner on WorkflowExecutor {
  Future<MapStepResult?> _executeForeachStep(
    WorkflowRun run,
    WorkflowDefinition definition,
    WorkflowStep controllerStep,
    List<String> childStepIds,
    WorkflowContext context, {
    required Map<String, WorkflowStep> stepById,
    required int stepIndex,
    WorkflowExecutionCursor? resumeCursor,
  }) async {
    final rawCollection = context[controllerStep.mapOver!];
    if (rawCollection == null) {
      return MapStepResult(
        results: const [],
        totalTokens: 0,
        success: false,
        error: "Foreach step '${controllerStep.id}': context key '${controllerStep.mapOver}' is null or missing",
      );
    }
    final resolvedCollection = switch (rawCollection) {
      final List<dynamic> list => list,
      final Map<String, dynamic> map when map.length == 1 && map.values.first is List => () {
        WorkflowExecutor._log.info(
          'Foreach step \'${controllerStep.id}\': auto-unwrapped Map key \'${map.keys.first}\' '
          'to List (${(map.values.first as List).length} items)',
        );
        return map.values.first as List<dynamic>;
      }(),
      final Map<Object?, Object?> map when map.length == 1 && map.values.first is List => () {
        final normalized = map.map((key, value) => MapEntry(key.toString(), value));
        WorkflowExecutor._log.info(
          'Foreach step \'${controllerStep.id}\': auto-unwrapped Map key \'${normalized.keys.first}\' '
          'to List (${(normalized.values.first as List).length} items)',
        );
        return normalized.values.first as List<dynamic>;
      }(),
      _ => null,
    };
    if (resolvedCollection == null) {
      return MapStepResult(
        results: const [],
        totalTokens: 0,
        success: false,
        error:
            "Foreach step '${controllerStep.id}': context key '${controllerStep.mapOver}' is not a List "
            '(got ${rawCollection.runtimeType})',
      );
    }
    final collection = resolvedCollection;
    if (collection.length > controllerStep.maxItems) {
      return MapStepResult(
        results: const [],
        totalTokens: 0,
        success: false,
        error:
            "Foreach step '${controllerStep.id}': collection has ${collection.length} items "
            'which exceeds maxItems (${controllerStep.maxItems}). '
            'Consider decomposing into smaller batches.',
      );
    }
    if (collection.isEmpty) {
      WorkflowExecutor._log.warning(
        "Workflow '${run.id}': foreach step '${controllerStep.id}' has empty collection — "
        'succeeding with empty result array',
      );
      return const MapStepResult(results: [], totalTokens: 0, success: true);
    }
    final int? maxParallel;
    try {
      maxParallel = _resolveMaxParallel(controllerStep.maxParallel, context, controllerStep.id);
    } on ArgumentError catch (e) {
      return MapStepResult(results: const [], totalTokens: 0, success: false, error: e.message.toString());
    }
    final childSteps = childStepIds.map((id) => stepById[id]).nonNulls.toList(growable: false);
    if (childSteps.length != childStepIds.length) {
      return MapStepResult(
        results: const [],
        totalTokens: 0,
        success: false,
        error: "Foreach step '${controllerStep.id}': one or more child steps are missing from the definition",
      );
    }
    final strategy = definition.gitStrategy;
    final resolvedWorktreeMode = strategy?.effectiveWorktreeMode(maxParallel: maxParallel, isMap: true) ?? 'inline';
    final promotionStrategy = _effectivePromotion(strategy, resolvedWorktreeMode: resolvedWorktreeMode);
    final promotionAware = _isPromotionAwareScope(
      strategy,
      resolvedWorktreeMode: resolvedWorktreeMode,
      hasCodingSteps: childSteps.any((step) => _stepTouchesProjectBranch(definition, step)),
    );
    final integrationBranch = (context['_workflow.git.integration_branch'] as String?)?.trim();
    final promotedIds =
        (context['_map.${controllerStep.id}.promotedIds'] as List?)?.whereType<String>().toSet() ?? <String>{};
    final mapCtx = MapStepContext(collection: collection, maxParallel: maxParallel, maxItems: controllerStep.maxItems);
    _restoreForeachProgress(mapCtx, resumeCursor, collectionLength: collection.length);
    await _persistForeachProgress(run, controllerStep, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
    final inFlight = <int, Future<void>>{};
    final settledIndices = mapCtx.completedIndices;
    final pending = Queue<int>.from(
      List.generate(collection.length, (i) => i).where((i) => !settledIndices.contains(i)),
    );
    var totalTokens = 0;
    while (pending.isNotEmpty || inFlight.isNotEmpty) {
      if (mapCtx.budgetExhausted) {
        while (pending.isNotEmpty) {
          mapCtx.recordCancelled(pending.removeFirst(), 'Cancelled: budget exhausted');
        }
        await _persistForeachProgress(
          run,
          controllerStep,
          context,
          mapCtx,
          stepIndex: stepIndex,
          promotedIds: promotedIds,
        );
        break;
      }
      final poolAvailable = _turnAdapter?.availableRunnerCount?.call();
      final concurrencyCap = mapCtx.effectiveConcurrency(poolAvailable);
      while (inFlight.length < concurrencyCap && pending.isNotEmpty) {
        final iterIndex = pending.removeFirst();
        final mapContext = MapContext(
          item: (collection[iterIndex] as Object?) ?? '',
          index: iterIndex,
          length: collection.length,
          alias: controllerStep.mapAlias,
        );
        final controllerResolved = resolveStepConfig(
          controllerStep,
          definition.stepDefaults,
          roleDefaults: _roleDefaults,
        );
        final effectiveProjectId = _resolveProjectIdWithMap(
          definition,
          controllerStep,
          context,
          mapContext,
          resolved: controllerResolved,
        );
        mapCtx.inFlightCount++;
        inFlight[iterIndex] =
            _dispatchForeachIteration(
              run: run,
              definition: definition,
              controllerStep: controllerStep,
              childSteps: childSteps,
              stepIndex: stepIndex,
              iterIndex: iterIndex,
              mapContext: mapContext,
              mapCtx: mapCtx,
              context: context,
              promotionAware: promotionAware,
              integrationBranch: integrationBranch,
              promotionStrategy: promotionStrategy,
              promotedIds: promotedIds,
              projectId: effectiveProjectId,
              controllerMaxParallel: maxParallel,
            ).then((_) {
              inFlight.remove(iterIndex);
            });
      }
      if (inFlight.isEmpty && pending.isNotEmpty) {
        WorkflowExecutor._log.warning(
          "Workflow '${run.id}': foreach step '${controllerStep.id}' — "
          '${pending.length} items stalled; cancelling.',
        );
        while (pending.isNotEmpty) {
          mapCtx.recordCancelled(pending.removeFirst(), 'Cancelled: dispatch stall');
        }
        await _persistForeachProgress(
          run,
          controllerStep,
          context,
          mapCtx,
          stepIndex: stepIndex,
          promotedIds: promotedIds,
        );
        break;
      }
      if (inFlight.isEmpty) break;
      await Future.any(inFlight.values);
      final refreshedRun = await _repository.getById(run.id) ?? run;
      run = refreshedRun;
      if (_workflowBudgetExceeded(run, definition)) {
        mapCtx.budgetExhausted = true;
      }
      await Future<void>.delayed(Duration.zero);
    }
    if (inFlight.isNotEmpty) {
      await Future.wait(inFlight.values, eagerError: false);
    }
    for (var i = 0; i < collection.length; i++) {
      for (final childStep in childSteps) {
        final t = context['${childStep.id}[$i].tokenCount'];
        if (t is int) totalTokens += t;
      }
    }
    _eventBus.fire(
      MapStepCompletedEvent(
        runId: run.id,
        stepId: controllerStep.id,
        stepName: controllerStep.name,
        totalIterations: collection.length,
        successCount: mapCtx.successCount,
        failureCount: mapCtx.failedIndices.length,
        cancelledCount: mapCtx.cancelledCount,
        totalTokens: totalTokens,
        timestamp: DateTime.now(),
      ),
    );
    if (mapCtx.hasFailures) {
      return MapStepResult(
        results: List<dynamic>.from(mapCtx.results),
        totalTokens: totalTokens,
        success: false,
        error: "Foreach step '${controllerStep.id}': ${mapCtx.failedIndices.length} iteration(s) failed",
      );
    }
    return MapStepResult(results: List<dynamic>.from(mapCtx.results), totalTokens: totalTokens, success: true);
  }
  Future<void> _dispatchForeachIteration({
    required WorkflowRun run,
    required WorkflowDefinition definition,
    required WorkflowStep controllerStep,
    required List<WorkflowStep> childSteps,
    required int stepIndex,
    required int iterIndex,
    required MapContext mapContext,
    required MapStepContext mapCtx,
    required WorkflowContext context,
    required bool promotionAware,
    required String? integrationBranch,
    required String promotionStrategy,
    required Set<String> promotedIds,
    required String? projectId,
    required int? controllerMaxParallel,
  }) async {
    final iterData = Map<String, dynamic>.from(context.data);
    iterData['map.item'] = mapContext.item;
    iterData['map.index'] = mapContext.index;
    iterData['map.length'] = mapContext.length;
    final iterContext = WorkflowContext(data: iterData, variables: context.variables);
    int iterTokens = 0;
    Map<String, dynamic> iterResult = {};
    String? firstTaskId;
    for (var childIndex = 0; childIndex < childSteps.length; childIndex++) {
      final childStep = childSteps[childIndex];
      final childStepIndex = definition.steps.indexOf(childStep);
      final skippedRun = await _skipDueToEntryGate(run, childStep, childStepIndex, iterContext);
      if (skippedRun != null) {
        run = skippedRun;
        continue;
      }
      final result = await _executeStep(
        run,
        definition,
        childStep,
        iterContext,
        stepIndex: childStepIndex,
        mapCtx: mapContext,
        enclosingMaxParallel: controllerMaxParallel,
      );
      if (result == null) {
        mapCtx.recordFailure(iterIndex, "Foreach child step '${childStep.id}' failed to create task", null);
        await _persistForeachProgress(
          run,
          controllerStep,
          context,
          mapCtx,
          stepIndex: stepIndex,
          promotedIds: promotedIds,
        );
        mapCtx.inFlightCount--;
        _eventBus.fire(
          MapIterationCompletedEvent(
            runId: run.id,
            stepId: controllerStep.id,
            iterationIndex: iterIndex,
            totalIterations: mapCtx.collection.length,
            itemId: mapCtx.itemId(iterIndex),
            taskId: firstTaskId ?? '',
            success: false,
            tokenCount: iterTokens,
            timestamp: DateTime.now(),
          ),
        );
        return;
      }
      if (childIndex == 0) firstTaskId = result.task?.id;
      final tokenCount = result.tokenCount;
      iterTokens += tokenCount;
      context['${childStep.id}[$iterIndex].tokenCount'] = tokenCount;
      if (!result.success) {
        _mergeStepResultIntoContext(iterContext, result, fallbackStatus: 'failed');
        for (final entry in result.outputs.entries) {
          context['${childStep.id}[$iterIndex].${entry.key}'] = entry.value;
        }
        context['${childStep.id}[$iterIndex].status'] = iterContext['${childStep.id}.status'];
        if (result.outcome != null) {
          context['step.${childStep.id}[$iterIndex].outcome'] = result.outcome!;
        }
        if (result.outcomeReason != null && result.outcomeReason!.isNotEmpty) {
          context['step.${childStep.id}[$iterIndex].outcome.reason'] = result.outcomeReason!;
        }
        mapCtx.recordFailure(iterIndex, "Foreach child step '${childStep.id}' failed", result.task?.id);
        await _persistForeachProgress(
          run,
          controllerStep,
          context,
          mapCtx,
          stepIndex: stepIndex,
          promotedIds: promotedIds,
        );
        mapCtx.inFlightCount--;
        _eventBus.fire(
          WorkflowStepCompletedEvent(
            runId: run.id,
            stepId: childStep.id,
            stepName: childStep.name,
            stepIndex: childStepIndex,
            totalSteps: definition.steps.length,
            taskId: result.task?.id ?? '',
            success: false,
            tokenCount: tokenCount,
            timestamp: DateTime.now(),
          ),
        );
        if (result.awaitingApproval) {
          await _transitionStepAwaitingApproval(
            run,
            childStep,
            context,
            stepIndex: childStepIndex,
            reason: result.outcomeReason ?? "Foreach child step '${childStep.id}' requires input",
          );
        }
        _eventBus.fire(
          MapIterationCompletedEvent(
            runId: run.id,
            stepId: controllerStep.id,
            iterationIndex: iterIndex,
            totalIterations: mapCtx.collection.length,
            itemId: mapCtx.itemId(iterIndex),
            taskId: firstTaskId ?? '',
            success: false,
            tokenCount: iterTokens,
            timestamp: DateTime.now(),
          ),
        );
        return;
      }
      _mergeStepResultIntoContext(iterContext, result, fallbackStatus: result.task?.status.name ?? 'completed');
      for (final entry in result.outputs.entries) {
        context['${childStep.id}[$iterIndex].${entry.key}'] = entry.value;
      }
      context['${childStep.id}[$iterIndex].status'] = iterContext['${childStep.id}.status'];
      context['${childStep.id}[$iterIndex].tokenCount'] = tokenCount;
      if (result.outcome != null) {
        context['step.${childStep.id}[$iterIndex].outcome'] = result.outcome!;
      }
      if (result.outcomeReason != null && result.outcomeReason!.isNotEmpty) {
        context['step.${childStep.id}[$iterIndex].outcome.reason'] = result.outcomeReason!;
      }
      iterResult[childStep.id] = Map<String, dynamic>.from(result.outputs);
      _eventBus.fire(
        WorkflowStepCompletedEvent(
          runId: run.id,
          stepId: childStep.id,
          stepName: childStep.name,
          stepIndex: childStepIndex,
          totalSteps: definition.steps.length,
          taskId: result.task?.id ?? '',
          success: true,
          tokenCount: tokenCount,
          timestamp: DateTime.now(),
        ),
      );
    }
    if (promotionAware) {
      final branchStep = childSteps.firstWhere(
        (step) => ((iterContext['${step.id}.branch'] as String?)?.trim().isNotEmpty ?? false),
        orElse: () => childSteps.first,
      );
      final storyBranch = (iterContext['${branchStep.id}.branch'] as String?)?.trim();
      final promote = _turnAdapter?.promoteWorkflowBranch;
      final storyId = mapCtx.itemId(iterIndex);
      if (promote == null) {
        mapCtx.recordFailure(iterIndex, 'promotion failed: host promotion callback is not configured', firstTaskId);
        await _persistForeachProgress(
          run,
          controllerStep,
          context,
          mapCtx,
          stepIndex: stepIndex,
          promotedIds: promotedIds,
        );
        mapCtx.inFlightCount--;
        _eventBus.fire(
          MapIterationCompletedEvent(
            runId: run.id,
            stepId: controllerStep.id,
            iterationIndex: iterIndex,
            totalIterations: mapCtx.collection.length,
            itemId: storyId,
            taskId: firstTaskId ?? '',
            success: false,
            tokenCount: iterTokens,
            timestamp: DateTime.now(),
          ),
        );
        return;
      }
      if (projectId == null || projectId.isEmpty) {
        mapCtx.recordFailure(iterIndex, 'promotion failed: foreach iteration has no project binding', firstTaskId);
        await _persistForeachProgress(
          run,
          controllerStep,
          context,
          mapCtx,
          stepIndex: stepIndex,
          promotedIds: promotedIds,
        );
        mapCtx.inFlightCount--;
        _eventBus.fire(
          MapIterationCompletedEvent(
            runId: run.id,
            stepId: controllerStep.id,
            iterationIndex: iterIndex,
            totalIterations: mapCtx.collection.length,
            itemId: storyId,
            taskId: firstTaskId ?? '',
            success: false,
            tokenCount: iterTokens,
            timestamp: DateTime.now(),
          ),
        );
        return;
      }
      if (storyBranch == null || storyBranch.isEmpty) {
        mapCtx.recordFailure(iterIndex, 'promotion failed: task worktree branch is unavailable', firstTaskId);
        await _persistForeachProgress(
          run,
          controllerStep,
          context,
          mapCtx,
          stepIndex: stepIndex,
          promotedIds: promotedIds,
        );
        mapCtx.inFlightCount--;
        _eventBus.fire(
          MapIterationCompletedEvent(
            runId: run.id,
            stepId: controllerStep.id,
            iterationIndex: iterIndex,
            totalIterations: mapCtx.collection.length,
            itemId: storyId,
            taskId: firstTaskId ?? '',
            success: false,
            tokenCount: iterTokens,
            timestamp: DateTime.now(),
          ),
        );
        return;
      }
      if (integrationBranch == null || integrationBranch.isEmpty) {
        mapCtx.recordFailure(iterIndex, 'promotion failed: integration branch is not initialized', firstTaskId);
        await _persistForeachProgress(
          run,
          controllerStep,
          context,
          mapCtx,
          stepIndex: stepIndex,
          promotedIds: promotedIds,
        );
        mapCtx.inFlightCount--;
        _eventBus.fire(
          MapIterationCompletedEvent(
            runId: run.id,
            stepId: controllerStep.id,
            iterationIndex: iterIndex,
            totalIterations: mapCtx.collection.length,
            itemId: storyId,
            taskId: firstTaskId ?? '',
            success: false,
            tokenCount: iterTokens,
            timestamp: DateTime.now(),
          ),
        );
        return;
      }
      final promotionResult = await promote(
        runId: run.id,
        projectId: projectId,
        branch: storyBranch,
        integrationBranch: integrationBranch,
        strategy: promotionStrategy,
        storyId: storyId,
      );
      switch (promotionResult) {
        case WorkflowGitPromotionSuccess(:final commitSha):
          if (storyId != null && storyId.isNotEmpty) promotedIds.add(storyId);
          context['${controllerStep.id}[$iterIndex].promotion'] = 'success';
          context['${controllerStep.id}[$iterIndex].promotion_sha'] = commitSha;
        case WorkflowGitPromotionConflict(:final conflictingFiles, :final details):
          final conflictMsg =
              'promotion-conflict: ${conflictingFiles.isEmpty ? 'merge conflict' : conflictingFiles.join(', ')}';
          context['${controllerStep.id}[$iterIndex].promotion'] = 'conflict';
          context['${controllerStep.id}[$iterIndex].promotion_details'] = details;
          mapCtx.recordFailure(iterIndex, conflictMsg, firstTaskId);
          await _persistForeachProgress(
            run,
            controllerStep,
            context,
            mapCtx,
            stepIndex: stepIndex,
            promotedIds: promotedIds,
          );
          mapCtx.inFlightCount--;
          _eventBus.fire(
            MapIterationCompletedEvent(
              runId: run.id,
              stepId: controllerStep.id,
              iterationIndex: iterIndex,
              totalIterations: mapCtx.collection.length,
              itemId: storyId,
              taskId: firstTaskId ?? '',
              success: false,
              tokenCount: iterTokens,
              timestamp: DateTime.now(),
            ),
          );
          return;
        case WorkflowGitPromotionError(:final message):
          context['${controllerStep.id}[$iterIndex].promotion'] = 'failed';
          mapCtx.recordFailure(iterIndex, 'promotion failed: $message', firstTaskId);
          await _persistForeachProgress(
            run,
            controllerStep,
            context,
            mapCtx,
            stepIndex: stepIndex,
            promotedIds: promotedIds,
          );
          mapCtx.inFlightCount--;
          _eventBus.fire(
            MapIterationCompletedEvent(
              runId: run.id,
              stepId: controllerStep.id,
              iterationIndex: iterIndex,
              totalIterations: mapCtx.collection.length,
              itemId: storyId,
              taskId: firstTaskId ?? '',
              success: false,
              tokenCount: iterTokens,
              timestamp: DateTime.now(),
            ),
          );
          return;
      }
    }
    mapCtx.recordResult(iterIndex, iterResult);
    await _persistForeachProgress(run, controllerStep, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
    mapCtx.inFlightCount--;
    _eventBus.fire(
      MapIterationCompletedEvent(
        runId: run.id,
        stepId: controllerStep.id,
        iterationIndex: iterIndex,
        totalIterations: mapCtx.collection.length,
        itemId: mapCtx.itemId(iterIndex),
        taskId: firstTaskId ?? '',
        success: true,
        tokenCount: iterTokens,
        timestamp: DateTime.now(),
      ),
    );
  }
  void _restoreForeachProgress(
    MapStepContext mapCtx,
    WorkflowExecutionCursor? cursor, {
    required int collectionLength,
  }) {
    if (cursor == null || cursor.nodeType != WorkflowExecutionCursorNodeType.foreach) return;
    final safeResultSlots = cursor.resultSlots.isEmpty
        ? List<dynamic>.filled(collectionLength, null)
        : List<dynamic>.from(cursor.resultSlots);
    if (safeResultSlots.length < collectionLength) {
      safeResultSlots.addAll(List<dynamic>.filled(collectionLength - safeResultSlots.length, null));
    } else if (safeResultSlots.length > collectionLength) {
      safeResultSlots.removeRange(collectionLength, safeResultSlots.length);
    }
    final failed = cursor.failedIndices.toSet();
    final cancelled = cursor.cancelledIndices.toSet();
    for (final index in cursor.completedIndices) {
      if (index < 0 || index >= collectionLength) continue;
      final slotValue = safeResultSlots[index];
      if (cancelled.contains(index)) {
        mapCtx.recordCancelled(index, _restoredMapCancellationMessage(slotValue));
      } else if (failed.contains(index)) {
        final restoredFailure = _restoredMapFailureMessage(slotValue);
        if (restoredFailure.startsWith('promotion-conflict')) {
          continue; // Leave unsettled so resume can re-attempt promotion.
        }
        mapCtx.recordFailure(index, restoredFailure, _restoredMapTaskId(slotValue));
      } else {
        mapCtx.recordResult(index, slotValue);
      }
    }
  }

  Future<void> _persistForeachProgress(
    WorkflowRun run,
    WorkflowStep step,
    WorkflowContext context,
    MapStepContext mapCtx, {
    required int stepIndex,
    Set<String> promotedIds = const <String>{},
  }) async {
    context['_map.${step.id}.promotedIds'] = promotedIds.toList()..sort();
    final refreshedRun = await _repository.getById(run.id) ?? run;
    final cursor = WorkflowExecutionCursor.foreach(
      stepId: step.id,
      stepIndex: stepIndex,
      totalItems: mapCtx.collection.length,
      completedIndices: mapCtx.completedIndices.toList()..sort(),
      failedIndices: mapCtx.failedIndices.toList()..sort(),
      cancelledIndices: mapCtx.cancelledIndices.toList()..sort(),
      resultSlots: List<dynamic>.from(mapCtx.results),
    );
    final updatedRun = refreshedRun.copyWith(
      executionCursor: cursor,
      contextJson: {
        for (final e in refreshedRun.contextJson.entries)
          if (e.key.startsWith('_') && !e.key.startsWith('_foreach.current')) e.key: e.value,
        ...context.toJson(),
        '_foreach.current.stepId': step.id,
        '_foreach.current.total': mapCtx.collection.length,
        '_foreach.current.completedIndices': cursor.completedIndices,
        '_foreach.current.failedIndices': cursor.failedIndices,
        '_foreach.current.cancelledIndices': cursor.cancelledIndices,
        '_map.${step.id}.promotedIds': context['_map.${step.id}.promotedIds'],
      },
      updatedAt: DateTime.now(),
    );
    await _repository.update(updatedRun);
  }
}
