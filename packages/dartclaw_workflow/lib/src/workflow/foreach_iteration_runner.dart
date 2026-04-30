part of 'workflow_executor.dart';

/// Outcome of one merge-resolve attempt body, used to dispatch the outer
/// retry loop without having to translate `return`/`continue` inside the
/// closure passed to [WorkflowTurnAdapter.runResolverAttemptUnderLock].
sealed class _ResolverAttemptDecision {
  const _ResolverAttemptDecision();
}

/// Exit the resolver loop and return [value] to the caller of
/// `_resolveMergePromotionConflict`.
final class _ResolverExit extends _ResolverAttemptDecision {
  final WorkflowGitPromotionResult? value;
  const _ResolverExit(this.value);
}

/// Advance to the next attempt in the resolver loop.
final class _ResolverContinue extends _ResolverAttemptDecision {
  const _ResolverContinue();
}

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
    final depGraph = DependencyGraph(collection);
    if (depGraph.isDependencyAware) {
      try {
        depGraph.validate();
      } on ArgumentError catch (e) {
        return MapStepResult(
          results: const [],
          totalTokens: 0,
          success: false,
          error: "Foreach step '${controllerStep.id}': ${e.message}",
        );
      }
    }
    final mapCtx = MapStepContext(collection: collection, maxParallel: maxParallel, maxItems: controllerStep.maxItems);
    final completedIds = <String>{};
    _restoreForeachProgress(mapCtx, completedIds, resumeCursor, collectionLength: collection.length);
    await _persistForeachProgress(run, controllerStep, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
    final inFlight = <int, Future<void>>{};
    // Maps in-flight iteration index → task id for drain cancellation (S61).
    final iterTaskIds = <int, String>{};
    final settledIndices = mapCtx.completedIndices;
    final pending = Queue<int>.from(
      List.generate(collection.length, (i) => i).where((i) => !settledIndices.contains(i)),
    );
    var totalTokens = 0;
    // Drain-failure message is set by the drain path; when non-null, abort loop.
    String? drainFailureMessage;
    int? pendingSerializeRemainingIteration() {
      final serializeIter = context['_merge_resolve.${controllerStep.id}.serializing_iter_index'];
      if (serializeIter is! int ||
          context['_merge_resolve.${controllerStep.id}.serialize_remaining_phase'] == 'drained') {
        return null;
      }
      return serializeIter;
    }

    Future<void> enactSerializeRemaining(int serializeIter) async {
      final drainResult = await _drainAndRequeue(
        run: run,
        controllerStep: controllerStep,
        context: context,
        mapCtx: mapCtx,
        pending: pending,
        inFlight: inFlight,
        iterTaskIds: iterTaskIds,
        failingIterIndex: serializeIter,
        stepIndex: stepIndex,
        promotedIds: promotedIds,
      );
      if (drainResult != null) {
        drainFailureMessage = drainResult;
      }
    }

    while (pending.isNotEmpty || inFlight.isNotEmpty || pendingSerializeRemainingIteration() != null) {
      if (drainFailureMessage != null) break;
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
      final isSerialMode = context['_merge_resolve.${controllerStep.id}.serialize_remaining_phase'] != null;
      final poolAvailable = _turnAdapter?.availableRunnerCount?.call();
      final concurrencyCap = isSerialMode ? 1 : mapCtx.effectiveConcurrency(poolAvailable);
      while (inFlight.length < concurrencyCap && pending.isNotEmpty) {
        int? nextIndex;
        if (depGraph.hasDependencies) {
          final ready = depGraph.getReady(promotionAware ? promotedIds : completedIds);
          for (final pendingIndex in pending) {
            if (ready.contains(pendingIndex)) {
              nextIndex = pendingIndex;
              break;
            }
          }
        } else {
          nextIndex = pending.first;
        }
        if (nextIndex == null) break;
        pending.remove(nextIndex);

        final iterIndex = nextIndex;
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
        final projectBindingStep = childSteps.firstWhere(
          (step) => _stepTouchesProjectBranch(definition, step),
          orElse: () => controllerStep,
        );
        final projectResolved = identical(projectBindingStep, controllerStep)
            ? controllerResolved
            : resolveStepConfig(projectBindingStep, definition.stepDefaults, roleDefaults: _roleDefaults);
        final effectiveProjectId = _resolveProjectIdWithMap(
          definition,
          projectBindingStep,
          context,
          mapContext,
          resolved: projectResolved,
        );
        mapCtx.inFlightCount++;
        inFlight[iterIndex] =
            (() async {
              try {
                await _dispatchForeachIteration(
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
                  iterTaskIds: iterTaskIds,
                );
              } catch (e, st) {
                WorkflowExecutor._log.severe(
                  "Workflow '${run.id}': foreach step '${controllerStep.id}' iteration $iterIndex failed unexpectedly: $e",
                  e,
                  st,
                );
                if (!mapCtx.completedIndices.contains(iterIndex)) {
                  mapCtx.recordFailure(iterIndex, 'Unexpected iteration error: $e', iterTaskIds[iterIndex]);
                  await _persistForeachProgress(
                    run,
                    controllerStep,
                    context,
                    mapCtx,
                    stepIndex: stepIndex,
                    promotedIds: promotedIds,
                  );
                  _eventBus.fire(
                    MapIterationCompletedEvent(
                      runId: run.id,
                      stepId: controllerStep.id,
                      iterationIndex: iterIndex,
                      totalIterations: mapCtx.collection.length,
                      itemId: mapCtx.itemId(iterIndex),
                      taskId: iterTaskIds[iterIndex] ?? '',
                      success: false,
                      tokenCount: 0,
                      timestamp: DateTime.now(),
                    ),
                  );
                }
                // Unexpected exceptions out of `_dispatchForeachIteration` (vs.
                // ordinary task failures recorded inside it) signal a controller-
                // level invariant breach — repository corruption, late-init
                // misuse, or similar. Treat the same as budget exhaustion so the
                // remaining pending iterations are cancelled rather than silently
                // re-dispatched against possibly-corrupt state.
                mapCtx.budgetExhausted = true;
              }
            })().whenComplete(() {
              inFlight.remove(iterIndex);
              mapCtx.inFlightCount = inFlight.length;
              iterTaskIds.remove(iterIndex);
              final itemId = mapCtx.itemId(iterIndex);
              if (itemId != null) completedIds.add(itemId);
            });
      }
      final serializeIter = pendingSerializeRemainingIteration();
      if (serializeIter != null) {
        await enactSerializeRemaining(serializeIter);
        continue;
      }
      if (inFlight.isEmpty && pending.isNotEmpty) {
        if (promotionAware && depGraph.hasDependencies && mapCtx.failedIndices.isNotEmpty) {
          WorkflowExecutor._log.warning(
            "Workflow '${run.id}': foreach step '${controllerStep.id}' — "
            '${pending.length} items remain blocked on unresolved promoted dependencies; leaving them pending for resume.',
          );
          break;
        }

        final cancellationMessage = depGraph.hasDependencies
            ? 'Cancelled: dependency deadlock'
            : 'Cancelled: dispatch stall';
        WorkflowExecutor._log.warning(
          "Workflow '${run.id}': foreach step '${controllerStep.id}' — "
          '${pending.length} items stalled; cancelling.',
        );
        while (pending.isNotEmpty) {
          mapCtx.recordCancelled(pending.removeFirst(), cancellationMessage);
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

      // S61: if serialize-remaining fired during this tick, perform drain + re-queue.
      final completedSerializeIter = pendingSerializeRemainingIteration();
      if (completedSerializeIter != null) {
        await enactSerializeRemaining(completedSerializeIter);
        continue;
      }

      final refreshedRun = await _repository.getById(run.id) ?? run;
      run = refreshedRun;
      if (_workflowBudgetExceeded(run, definition)) {
        mapCtx.budgetExhausted = true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    if (drainFailureMessage != null) {
      return MapStepResult(results: const [], totalTokens: 0, success: false, error: drainFailureMessage);
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
      for (final index in mapCtx.failedIndices) {
        final slot = mapCtx.results[index];
        final message = slot is Map ? slot['message'] : slot;
        WorkflowExecutor._log.warning("Foreach step '${controllerStep.id}' iteration [$index] failed: $message");
      }
      final hasPromotionConflict = mapCtx.failedIndices.any((index) {
        final slot = mapCtx.results[index];
        return slot is Map && (slot['message'] as String?)?.startsWith('promotion-conflict') == true;
      });
      return MapStepResult(
        results: List<dynamic>.from(mapCtx.results),
        totalTokens: totalTokens,
        success: false,
        error: hasPromotionConflict
            ? "promotion-conflict: foreach step '${controllerStep.id}' has unresolved promotion conflicts"
            : "Foreach step '${controllerStep.id}': ${mapCtx.failedIndices.length} iteration(s) failed",
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
    required Map<int, String> iterTaskIds,
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
      if (childIndex == 0) {
        firstTaskId = result.task?.id;
        if (firstTaskId != null) iterTaskIds[iterIndex] = firstTaskId;
      }
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
          final mergeResolveConfig = definition.gitStrategy?.mergeResolve;
          if (mergeResolveConfig != null && mergeResolveConfig.enabled) {
            final resolveResult = await _resolveMergePromotionConflict(
              run: run,
              definition: definition,
              controllerStep: controllerStep,
              stepIndex: stepIndex,
              iterIndex: iterIndex,
              context: context,
              mapCtx: mapCtx,
              mapContext: mapContext,
              promotedIds: promotedIds,
              storyBranch: storyBranch,
              integrationBranch: integrationBranch,
              promotionStrategy: promotionStrategy,
              storyId: storyId,
              firstTaskId: firstTaskId,
              iterTokens: iterTokens,
              initialConflictingFiles: conflictingFiles,
              initialConflictDetails: details,
              projectId: projectId,
              config: mergeResolveConfig,
            );
            if (resolveResult == null) {
              mapCtx.recordFailure(iterIndex, 'merge-resolve failed', firstTaskId);
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
            // Resolved successfully — treat as promotion success and continue.
            switch (resolveResult) {
              case WorkflowGitPromotionSuccess(:final commitSha):
                if (storyId != null && storyId.isNotEmpty) promotedIds.add(storyId);
                context['${controllerStep.id}[$iterIndex].promotion'] = 'success';
                context['${controllerStep.id}[$iterIndex].promotion_sha'] = commitSha;
              case WorkflowGitPromotionSerializeRemaining():
                // Outer loop detects serializing_iter_index and drains siblings.
                // Intentionally leaves this iteration's progress as pending so it
                // re-enters the queue at head after drain (BPC-12).
                mapCtx.inFlightCount--;
                return;
              case WorkflowGitPromotionConflict():
              case WorkflowGitPromotionError():
                // Escalation returned conflict/error: fall through to immediate-failure path.
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
            }
          } else {
            // BPC-31: enabled: false or absent — byte-identical to pre-feature behavior.
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
          }
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
        case WorkflowGitPromotionSerializeRemaining():
          // Direct promote() never returns this sentinel; only _resolveMergePromotionConflict does.
          // Intentionally leaves this iteration's progress as pending so the outer loop
          // re-queues it at head after drain (BPC-12).
          mapCtx.inFlightCount--;
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
    Set<String> completedIds,
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
      final itemId = mapCtx.itemId(index);
      if (itemId != null) {
        completedIds.add(itemId);
      }
    }
  }

  /// Drives the bounded retry loop for a merge-resolve conflict.
  ///
  /// Returns `null` when failure is already fully handled (cleanup error, cancellation).
  /// Returns [WorkflowGitPromotionSuccess] on success.
  /// Returns [WorkflowGitPromotionConflict] when escalation-fail exhaustion occurred.
  Future<WorkflowGitPromotionResult?> _resolveMergePromotionConflict({
    required WorkflowRun run,
    required WorkflowDefinition definition,
    required WorkflowStep controllerStep,
    required int stepIndex,
    required int iterIndex,
    required WorkflowContext context,
    required MapStepContext mapCtx,
    required MapContext mapContext,
    required Set<String> promotedIds,
    required String storyBranch,
    required String integrationBranch,
    required String promotionStrategy,
    required String? storyId,
    required String? firstTaskId,
    required int iterTokens,
    required List<String> initialConflictingFiles,
    required String initialConflictDetails,
    required String projectId,
    required MergeResolveConfig config,
  }) async {
    final statePrefix = '_merge_resolve.${controllerStep.id}.$iterIndex';
    final promote = _turnAdapter?.promoteWorkflowBranch;

    // Read or initialize persisted state.
    var attemptCounter = (context['$statePrefix.attempt_counter'] as int?) ?? 0;
    final persistedPreAttemptSha = context['$statePrefix.pre_attempt_sha'] as String?;

    // Crash-recovery: detect in-flight attempt (persisted sha + counter but no artifact yet).
    if (persistedPreAttemptSha != null && attemptCounter > 0) {
      final crashAttemptNumber = attemptCounter;
      final existingArtifacts = firstTaskId != null
          ? await (_taskRepository?.listArtifactsByTask(firstTaskId) ?? Future.value(const <TaskArtifact>[]))
          : const <TaskArtifact>[];
      final artifactName = 'merge_resolve_iter_${iterIndex}_attempt_$crashAttemptNumber.json';
      final alreadyPersisted = existingArtifacts.any((a) => a.name == artifactName);
      if (!alreadyPersisted && firstTaskId != null) {
        // BPC-20 exact string: "interrupted by server restart"
        final crashArtifact = MergeResolveAttemptArtifact(
          iterationIndex: iterIndex,
          storyId: storyId ?? '',
          attemptNumber: crashAttemptNumber,
          outcome: 'failed',
          conflictedFiles: initialConflictingFiles,
          resolutionSummary: '',
          errorMessage: 'interrupted by server restart',
          agentSessionId: '',
          tokensUsed: 0,
        );
        await _persistAttemptArtifact(
          artifact: crashArtifact,
          taskId: firstTaskId,
          preAttemptSha: persistedPreAttemptSha,
          projectId: projectId,
          storyBranch: storyBranch,
          run: run,
          controllerStep: controllerStep,
          context: context,
          mapCtx: mapCtx,
          stepIndex: stepIndex,
          promotedIds: promotedIds,
          statePrefix: statePrefix,
        );
        // Run post-crash cleanup so next attempt starts clean.
        final cleanupError = await _turnAdapter?.cleanupWorktreeForRetry?.call(
          projectId: projectId,
          branch: storyBranch,
          preAttemptSha: persistedPreAttemptSha,
        );
        if (cleanupError != null) {
          await _handleCleanupFailure(
            errorMsg: cleanupError,
            taskId: firstTaskId,
            iterIndex: iterIndex,
            attemptNumber: crashAttemptNumber,
            run: run,
            controllerStep: controllerStep,
            context: context,
            mapCtx: mapCtx,
            stepIndex: stepIndex,
            promotedIds: promotedIds,
          );
          return null;
        }
      }
    }

    // Retry-then-promote loop. Each iteration runs under a single critical
    // section spanning capture+clean → skill execution → promote retry, so no
    // concurrent sibling promotion can mutate the integration branch
    // mid-resolution (PRD Lifecycle & Recovery / S60). The wrapper falls back
    // to direct invocation when the host turn-adapter does not provide it
    // (test wirings; behavior is byte-identical when no concurrent siblings).
    final lockWrapper = _turnAdapter?.runResolverAttemptUnderLock;
    Future<_ResolverAttemptDecision> runAttempt(Future<_ResolverAttemptDecision> Function() body) {
      if (lockWrapper == null) return body();
      return lockWrapper<_ResolverAttemptDecision>(projectId: projectId, body: body);
    }

    MergeResolveAttemptArtifact? lastAttempt;
    while (attemptCounter < config.maxAttempts) {
      final decision = await runAttempt(() async {
        // TI08+TI09: atomically capture SHA + dirty-check + cleanup under one lock.
        String preAttemptSha = context['$statePrefix.pre_attempt_sha'] as String? ?? '';
        final captureAndClean = _turnAdapter?.captureAndCleanWorktreeForRetry;
        if (captureAndClean != null) {
          final ccResult = await captureAndClean(
            projectId: projectId,
            branch: storyBranch,
            preAttemptSha: preAttemptSha.isNotEmpty ? preAttemptSha : null,
          );
          if (preAttemptSha.isEmpty && ccResult.sha != null) {
            preAttemptSha = ccResult.sha!;
            context['$statePrefix.pre_attempt_sha'] = preAttemptSha;
            await _persistForeachProgress(
              run,
              controllerStep,
              context,
              mapCtx,
              stepIndex: stepIndex,
              promotedIds: promotedIds,
            );
          }
          if (ccResult.cleanupError != null) {
            final attemptNumber = attemptCounter + 1;
            if (firstTaskId != null) {
              await _persistAttemptArtifact(
                artifact: MergeResolveAttemptArtifact(
                  iterationIndex: iterIndex,
                  storyId: storyId ?? '',
                  attemptNumber: attemptNumber,
                  outcome: 'failed',
                  conflictedFiles: initialConflictingFiles,
                  resolutionSummary: '',
                  errorMessage: ccResult.cleanupError,
                  agentSessionId: '',
                  tokensUsed: 0,
                ),
                taskId: firstTaskId,
                preAttemptSha: preAttemptSha,
                projectId: projectId,
                storyBranch: storyBranch,
                run: run,
                controllerStep: controllerStep,
                context: context,
                mapCtx: mapCtx,
                stepIndex: stepIndex,
                promotedIds: promotedIds,
                statePrefix: statePrefix,
              );
              await _handleCleanupFailure(
                errorMsg: ccResult.cleanupError!,
                taskId: firstTaskId,
                iterIndex: iterIndex,
                attemptNumber: attemptNumber,
                run: run,
                controllerStep: controllerStep,
                context: context,
                mapCtx: mapCtx,
                stepIndex: stepIndex,
                promotedIds: promotedIds,
              );
            }
            return _ResolverExit(null);
          }
        } else {
          // Fallback: separate calls when combined callback is not wired.
          if (preAttemptSha.isEmpty) {
            final sha = await _capturePreAttemptSha(projectId: projectId, branch: storyBranch);
            if (sha == null) {
              WorkflowExecutor._log.warning("Workflow '${run.id}': could not capture pre_attempt_sha for $storyBranch");
            }
            preAttemptSha = sha ?? '';
            context['$statePrefix.pre_attempt_sha'] = preAttemptSha;
            await _persistForeachProgress(
              run,
              controllerStep,
              context,
              mapCtx,
              stepIndex: stepIndex,
              promotedIds: promotedIds,
            );
          }
        }

        // TI05: build env-var map.
        final envMap = _buildMergeResolveEnv(config, integrationBranch, storyBranch);

        // TI07: spawn the skill step.
        final attemptNumber = attemptCounter + 1;
        final skillStepId = '_merge_resolve_${controllerStep.id}_${iterIndex}_$attemptNumber';
        final skillStep = WorkflowStep(
          id: skillStepId,
          name: 'merge-resolve (attempt $attemptNumber)',
          skill: 'dartclaw-merge-resolve',
          emitsOwnOutcome: true,
          outputs: const {
            'merge_resolve.outcome': OutputConfig(format: OutputFormat.text),
            'merge_resolve.conflicted_files': OutputConfig(format: OutputFormat.lines),
            'merge_resolve.resolution_summary': OutputConfig(format: OutputFormat.text),
            'merge_resolve.error_message': OutputConfig(format: OutputFormat.text),
          },
          maxTokens: config.tokenCeiling,
        );

        final skillStepIndex = definition.steps.length; // synthetic; not in definition.steps
        final attemptStartedAt = DateTime.now();
        final resolveResult = await _executeStep(
          run,
          definition,
          skillStep,
          context,
          stepIndex: skillStepIndex,
          mapCtx: mapContext,
          extraTaskConfig: {'_workflowMergeResolveEnv': envMap},
        );
        final attemptElapsedMs = DateTime.now().difference(attemptStartedAt).inMilliseconds;

        // Advance counter immediately after invocation.
        attemptCounter++;
        context['$statePrefix.attempt_counter'] = attemptCounter;

        // TI11: assemble artifact fields from skill outputs.
        // Cancellation gets the canonical 'cancelled' outcome regardless of
        // whether the skill emitted output (cancelled tasks skip output extraction).
        final taskWasCancelled = resolveResult?.task?.status == TaskStatus.cancelled;
        final extractedOutcome = (resolveResult?.outputs['merge_resolve.outcome'] as String?)?.trim();
        final outcome = taskWasCancelled ? 'cancelled' : (extractedOutcome ?? 'failed');
        final rawConflictedFiles = resolveResult?.outputs['merge_resolve.conflicted_files'];
        final conflictedFiles = switch (rawConflictedFiles) {
          List<dynamic> list => list.cast<String>(),
          _ => initialConflictingFiles,
        };
        final resolutionSummary = (resolveResult?.outputs['merge_resolve.resolution_summary'] as String?) ?? '';
        final skillErrorMessage = resolveResult == null
            ? 'skill task failed to start'
            : switch (resolveResult.task?.status) {
                TaskStatus.cancelled => 'cancelled',
                TaskStatus.failed =>
                  (resolveResult.outputs['merge_resolve.error_message'] as String?)?.trim() ?? 'failed',
                _ => (resolveResult.outputs['merge_resolve.error_message'] as String?)?.trim(),
              };
        final agentSessionId = resolveResult?.task?.sessionId ?? '';
        final tokensUsed = resolveResult?.tokenCount ?? 0;

        final artifact = MergeResolveAttemptArtifact(
          iterationIndex: iterIndex,
          storyId: storyId ?? '',
          attemptNumber: attemptNumber,
          outcome: outcome,
          conflictedFiles: conflictedFiles,
          resolutionSummary: resolutionSummary,
          errorMessage: outcome == 'resolved' ? null : (skillErrorMessage ?? 'failed'),
          agentSessionId: agentSessionId,
          tokensUsed: tokensUsed,
          startedAt: attemptStartedAt,
          elapsedMs: attemptElapsedMs,
        );
        lastAttempt = artifact;

        // TI12: persist artifact (idempotent on resume).
        if (firstTaskId != null) {
          await _persistAttemptArtifact(
            artifact: artifact,
            taskId: firstTaskId,
            preAttemptSha: preAttemptSha,
            projectId: projectId,
            storyBranch: storyBranch,
            run: run,
            controllerStep: controllerStep,
            context: context,
            mapCtx: mapCtx,
            stepIndex: stepIndex,
            promotedIds: promotedIds,
            statePrefix: statePrefix,
          );
        }

        // Cancellation: propagate without further attempts.
        if (resolveResult?.task?.status == TaskStatus.cancelled || outcome == 'cancelled') {
          if (preAttemptSha.isNotEmpty) {
            final cancelCleanupError = await _turnAdapter?.cleanupWorktreeForRetry?.call(
              projectId: projectId,
              branch: storyBranch,
              preAttemptSha: preAttemptSha,
            );
            if (cancelCleanupError != null && firstTaskId != null) {
              await _handleCleanupFailure(
                errorMsg: cancelCleanupError,
                taskId: firstTaskId,
                iterIndex: iterIndex,
                attemptNumber: attemptNumber,
                run: run,
                controllerStep: controllerStep,
                context: context,
                mapCtx: mapCtx,
                stepIndex: stepIndex,
                promotedIds: promotedIds,
              );
            }
          }
          return _ResolverExit(null);
        }

        // TI15: on resolved, retry promotion.
        if (outcome == 'resolved') {
          if (promote != null) {
            final retryResult = await promote(
              runId: run.id,
              projectId: projectId,
              branch: storyBranch,
              integrationBranch: integrationBranch,
              strategy: promotionStrategy,
              storyId: storyId,
            );
            if (retryResult is WorkflowGitPromotionSuccess) {
              // Clear persisted merge-resolve state for this iteration.
              context.remove('$statePrefix.pre_attempt_sha');
              context.remove('$statePrefix.attempt_counter');
              await _persistForeachProgress(
                run,
                controllerStep,
                context,
                mapCtx,
                stepIndex: stepIndex,
                promotedIds: promotedIds,
              );
              return _ResolverExit(retryResult);
            }
            if (retryResult is WorkflowGitPromotionConflict) {
              // Re-conflict: advance to next attempt.
              context.remove('$statePrefix.pre_attempt_sha');
              await _persistForeachProgress(
                run,
                controllerStep,
                context,
                mapCtx,
                stepIndex: stepIndex,
                promotedIds: promotedIds,
              );
              return const _ResolverContinue();
            }
          }
          // Promotion returned error or no promote callback — fall through to failure cleanup.
        }

        // TI13: post-attempt cleanup on non-resolved outcome.
        if (preAttemptSha.isNotEmpty) {
          final cleanupError = await _turnAdapter?.cleanupWorktreeForRetry?.call(
            projectId: projectId,
            branch: storyBranch,
            preAttemptSha: preAttemptSha,
          );
          if (cleanupError != null) {
            // Overwrite artifact's error_message and treat as hard failure.
            if (firstTaskId != null) {
              await _handleCleanupFailure(
                errorMsg: cleanupError,
                taskId: firstTaskId,
                iterIndex: iterIndex,
                attemptNumber: attemptNumber,
                run: run,
                controllerStep: controllerStep,
                context: context,
                mapCtx: mapCtx,
                stepIndex: stepIndex,
                promotedIds: promotedIds,
              );
            }
            return _ResolverExit(null);
          }
        }

        // Clear pre_attempt_sha so next attempt captures fresh.
        context.remove('$statePrefix.pre_attempt_sha');
        await _persistForeachProgress(
          run,
          controllerStep,
          context,
          mapCtx,
          stepIndex: stepIndex,
          promotedIds: promotedIds,
        );
        return const _ResolverContinue();
      });
      switch (decision) {
        case _ResolverExit(:final value):
          return value;
        case _ResolverContinue():
          continue;
      }
    }

    // TI16: attempts exhausted — escalate.
    return _handleMergeResolveEscalation(
      mode: config.escalation ?? MergeResolveEscalation.serializeRemaining,
      conflictingFiles: initialConflictingFiles,
      conflictDetails: initialConflictDetails,
      lastAttempt: lastAttempt,
      run: run,
      controllerStep: controllerStep,
      context: context,
      mapCtx: mapCtx,
      stepIndex: stepIndex,
      promotedIds: promotedIds,
      iterIndex: iterIndex,
      attemptCounter: attemptCounter,
    );
  }

  /// Captures the HEAD SHA of [branch] for [projectId] via the TurnAdapter.
  Future<String?> _capturePreAttemptSha({required String projectId, required String branch}) =>
      _turnAdapter?.captureWorkflowBranchSha?.call(projectId: projectId, branch: branch) ?? Future.value(null);

  /// Builds the MERGE_RESOLVE_* env vars from config.
  Map<String, String> _buildMergeResolveEnv(MergeResolveConfig cfg, String integrationBranch, String storyBranch) {
    return <String, String>{
      'MERGE_RESOLVE_INTEGRATION_BRANCH': integrationBranch,
      'MERGE_RESOLVE_STORY_BRANCH': storyBranch,
      'MERGE_RESOLVE_TOKEN_CEILING': cfg.tokenCeiling.toString(),
    };
  }

  /// Persists a [MergeResolveAttemptArtifact] via [_taskRepository] (idempotent).
  Future<void> _persistAttemptArtifact({
    required MergeResolveAttemptArtifact artifact,
    required String taskId,
    required String preAttemptSha,
    required String projectId,
    required String storyBranch,
    required WorkflowRun run,
    required WorkflowStep controllerStep,
    required WorkflowContext context,
    required MapStepContext mapCtx,
    required int stepIndex,
    required Set<String> promotedIds,
    required String statePrefix,
  }) async {
    final repo = _taskRepository;
    if (repo == null) return;
    final name = 'merge_resolve_iter_${artifact.iterationIndex}_attempt_${artifact.attemptNumber}.json';
    final existing = await repo.listArtifactsByTask(taskId);
    if (existing.any((a) => a.name == name)) return; // idempotent
    final artifactJson = artifact.toJsonString();
    // Write artifact JSON to a stable path under the workflow run artifact dir.
    final artifactPath = p.join(_dataDir, 'runs', run.id, 'artifacts', name);
    final artifactFile = File(artifactPath);
    await artifactFile.parent.create(recursive: true);
    await artifactFile.writeAsString(artifactJson);
    await repo.insertArtifact(
      TaskArtifact(
        id: _uuid.v4(),
        taskId: taskId,
        name: name,
        kind: ArtifactKind.data,
        path: artifactPath,
        createdAt: DateTime.now(),
      ),
    );
    await _persistForeachProgress(run, controllerStep, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
  }

  /// Handles a cleanup-triple failure: updates artifact error_message, fails iteration, returns null.
  Future<void> _handleCleanupFailure({
    required String errorMsg,
    required String taskId,
    required int iterIndex,
    required int attemptNumber,
    required WorkflowRun run,
    required WorkflowStep controllerStep,
    required WorkflowContext context,
    required MapStepContext mapCtx,
    required int stepIndex,
    required Set<String> promotedIds,
  }) async {
    WorkflowExecutor._log.severe(
      "Workflow '${run.id}': merge-resolve cleanup failed (attempt $attemptNumber): $errorMsg",
    );
    // Attempt to update the existing artifact's error_message by reinserting with cleanup error.
    final repo = _taskRepository;
    if (repo != null) {
      final name = 'merge_resolve_iter_${iterIndex}_attempt_$attemptNumber.json';
      final existing = await repo.listArtifactsByTask(taskId);
      final existing_ = existing.where((a) => a.name == name).firstOrNull;
      if (existing_ != null) {
        // Read existing artifact, update error_message.
        final artifactFile = File(existing_.path);
        if (await artifactFile.exists()) {
          try {
            final old = MergeResolveAttemptArtifact.fromJson(
              jsonDecode(await artifactFile.readAsString()) as Map<String, dynamic>,
            );
            final updated = old.copyWith(errorMessage: errorMsg);
            await artifactFile.writeAsString(updated.toJsonString());
          } catch (_) {
            // Best-effort; don't let this mask the real cleanup error.
          }
        }
      }
    }
    await _persistForeachProgress(run, controllerStep, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
  }

  /// Dispatch method for max-attempts exhaustion (Decision 8, S61).
  ///
  /// `fail` → returns WorkflowGitPromotionConflict immediately.
  /// `serializeRemaining` → sets serialize_remaining_phase='enacting', stores attempt
  /// number for _drainAndRequeue, persists state, returns sentinel. Event fires in
  /// _drainAndRequeue once drainedIterationCount is known.
  Future<WorkflowGitPromotionResult> _handleMergeResolveEscalation({
    required MergeResolveEscalation mode,
    required List<String> conflictingFiles,
    required String conflictDetails,
    required MergeResolveAttemptArtifact? lastAttempt,
    required WorkflowRun run,
    required WorkflowStep controllerStep,
    required WorkflowContext context,
    required MapStepContext mapCtx,
    required int stepIndex,
    required Set<String> promotedIds,
    required int iterIndex,
    required int attemptCounter,
  }) async {
    switch (mode) {
      case MergeResolveEscalation.fail:
        final files = lastAttempt?.conflictedFiles.isNotEmpty == true ? lastAttempt!.conflictedFiles : conflictingFiles;
        return WorkflowGitPromotionConflict(conflictingFiles: files, details: conflictDetails);
      case MergeResolveEscalation.serializeRemaining:
        final phaseKey = '_merge_resolve.${controllerStep.id}.serialize_remaining_phase';
        // BPC-11: idempotent — if already serial, return sentinel without re-firing event.
        if (context[phaseKey] != null) {
          return const WorkflowGitPromotionSerializeRemaining();
        }
        // Mark 'enacting' BEFORE issuing any cancel signals (crash safety — phase persisted
        // before drain so a crash during drain resumes in 'enacting', not 'drained').
        context[phaseKey] = 'enacting';
        context['_merge_resolve.${controllerStep.id}.serializing_iter_index'] = iterIndex;
        // Store attempt number so _drainAndRequeue can include it in the event (accurate
        // drainedIterationCount is only known after siblings are collected, so event fires there).
        context['_merge_resolve.${controllerStep.id}.failed_attempt_number'] = attemptCounter;
        await _persistForeachProgress(
          run,
          controllerStep,
          context,
          mapCtx,
          stepIndex: stepIndex,
          promotedIds: promotedIds,
        );
        // Clear parallel-mode pre_attempt_sha for this iteration (BPC-13).
        context.remove('_merge_resolve.${controllerStep.id}.$iterIndex.pre_attempt_sha');
        return const WorkflowGitPromotionSerializeRemaining();
    }
  }

  /// Cancels in-flight sibling iterations, awaits settlement, rebuilds [pending]
  /// with [failingIterIndex] at head followed by drained siblings (BPC-12).
  ///
  /// Returns null on success. Returns an error message when a sibling is stuck
  /// (BPC-32) — caller must abort the foreach with that message.
  Future<String?> _drainAndRequeue({
    required WorkflowRun run,
    required WorkflowStep controllerStep,
    required WorkflowContext context,
    required MapStepContext mapCtx,
    required Queue<int> pending,
    required Map<int, Future<void>> inFlight,
    required Map<int, String> iterTaskIds,
    required int failingIterIndex,
    required int stepIndex,
    required Set<String> promotedIds,
  }) async {
    final phaseKey = '_merge_resolve.${controllerStep.id}.serialize_remaining_phase';
    // Two-level idempotency: drain is per-step (each foreach has its own pending
    // queue, so the drain key is scoped to controllerStep.id); event emission
    // below is per-run (runEmittedKey, single emission across all foreach steps).
    if (context[phaseKey] == 'drained') return null;

    // Collect siblings FIRST so drainedIterationCount is accurate when the event fires.
    final siblingIndices = inFlight.keys.toList(growable: false);
    final drainedCount = siblingIndices.length;

    // Fire exactly one event per run (PRD US06 / FR4): the event marks the
    // run-level transition into serialize-remaining mode. If a workflow has
    // multiple foreach steps that each escalate, only the first emits the
    // event; subsequent steps still drain and re-queue but do not re-emit.
    const runEmittedKey = '_merge_resolve.serialize_remaining_event_emitted';
    if (context[runEmittedKey] != true) {
      final attemptCounter = (context['_merge_resolve.${controllerStep.id}.failed_attempt_number'] as int?) ?? 0;
      _eventBus.fire(
        WorkflowSerializationEnactedEvent(
          runId: run.id,
          foreachStepId: controllerStep.id,
          failingIterationIndex: failingIterIndex,
          failedAttemptNumber: attemptCounter,
          drainedIterationCount: drainedCount,
          timestamp: DateTime.now(),
        ),
      );
      context[runEmittedKey] = true;
    }

    // Cancel all in-flight siblings (all in-flight, since the failing iter already exited).
    for (final idx in siblingIndices) {
      final taskId = iterTaskIds[idx];
      if (taskId != null) {
        try {
          await _taskService.transition(taskId, TaskStatus.cancelled, trigger: 'serialize-remaining drain');
        } catch (e) {
          WorkflowExecutor._log.warning("Workflow '${run.id}': drain cancel failed for task $taskId: $e");
        }
      }
    }

    // Await all siblings in parallel with a single 30s cap (BPC-23: p95≤30s, BPC-32: stuck-task).
    // Parallel wait ensures N siblings don't multiply the timeout to N×30s.
    const drainTimeout = Duration(seconds: 30);
    final drainFutures = <({int idx, Future<void> future})>[
      for (final idx in siblingIndices)
        if (inFlight[idx] != null) (idx: idx, future: inFlight[idx]!.catchError((_) {})),
    ];
    if (drainFutures.isNotEmpty) {
      try {
        await Future.wait(drainFutures.map((e) => e.future)).timeout(drainTimeout);
      } on TimeoutException {
        // Identify the first sibling whose future hasn't completed.
        final stuckIdx = drainFutures.firstWhere((e) => inFlight.containsKey(e.idx)).idx;
        final stuckTaskId = iterTaskIds[stuckIdx] ?? 'unknown';
        return 'serialize-remaining drain failed: task $stuckTaskId did not honor cancellation within timeout';
      }
    }

    // Discard parallel-mode pre_attempt_sha for all re-queued iterations (BPC-13).
    context.remove('_merge_resolve.${controllerStep.id}.$failingIterIndex.pre_attempt_sha');
    for (final idx in siblingIndices) {
      context.remove('_merge_resolve.${controllerStep.id}.$idx.pre_attempt_sha');
    }

    // Rebuild pending: failing iter at head (BPC-12), drained siblings after, remaining pending preserved.
    final oldPending = pending.toList();
    pending.clear();
    pending.add(failingIterIndex);
    for (final idx in siblingIndices) {
      if (!mapCtx.completedIndices.contains(idx)) {
        pending.add(idx);
      }
    }
    for (final idx in oldPending) {
      if (idx != failingIterIndex && !siblingIndices.contains(idx)) {
        pending.add(idx);
      }
    }

    // Atomically advance phase to 'drained' — single persist eliminates the crash window
    // where is_serial_mode=true but drain_done=false caused a re-drain on resume (MEDIUM fix).
    context[phaseKey] = 'drained';
    WorkflowExecutor._log.info(
      "Workflow '${run.id}': serialize-remaining enacted for step '${controllerStep.id}'; "
      'drained $drainedCount sibling(s), failing iter $failingIterIndex placed at head.',
    );
    await _persistForeachProgress(run, controllerStep, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
    return null;
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
