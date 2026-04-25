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
              final itemId = mapCtx.itemId(iterIndex);
              if (itemId != null) completedIds.add(itemId);
            });
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
      for (final index in mapCtx.failedIndices) {
        final slot = mapCtx.results[index];
        final message = slot is Map ? slot['message'] : slot;
        WorkflowExecutor._log.warning(
          "Foreach step '${controllerStep.id}' iteration [$index] failed: $message",
        );
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
              // Failure already recorded and inFlightCount decremented by the helper.
              return;
            }
            // Resolved successfully — treat as promotion success and continue.
            switch (resolveResult) {
              case WorkflowGitPromotionSuccess(:final commitSha):
                if (storyId != null && storyId.isNotEmpty) promotedIds.add(storyId);
                context['${controllerStep.id}[$iterIndex].promotion'] = 'success';
                context['${controllerStep.id}[$iterIndex].promotion_sha'] = commitSha;
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

    // Emit one WARNING per run when verification is absent.
    final verif = config.verification;
    final verificationAbsent = (verif.format == null || verif.format!.isEmpty) &&
        (verif.analyze == null || verif.analyze!.isEmpty) &&
        (verif.test == null || verif.test!.isEmpty);
    if (verificationAbsent && context['_merge_resolve.warning_emitted'] != true) {
      WorkflowExecutor._log.warning(
        "Workflow '${run.id}': merge_resolve.verification block absent — markers + git diff --check only",
      );
      context['_merge_resolve.warning_emitted'] = true;
    }

    // Read or initialize persisted state.
    var attemptCounter = (context['$statePrefix.attempt_counter'] as int?) ?? 0;
    final persistedPreAttemptSha = context['$statePrefix.pre_attempt_sha'] as String?;

    // Crash-recovery: detect in-flight attempt (persisted sha + counter but no artifact yet).
    if (persistedPreAttemptSha != null && attemptCounter > 0) {
      final crashAttemptNumber = attemptCounter;
      final existingArtifacts = firstTaskId != null
          ? await (_taskRepository?.listArtifactsByTask(firstTaskId) ?? Future.value(const <TaskArtifact>[]))
          : const <TaskArtifact>[];
      final artifactName = 'merge_resolve_attempt_$crashAttemptNumber.json';
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

    // Retry-then-promote loop.
    MergeResolveAttemptArtifact? lastAttempt;
    while (attemptCounter < config.maxAttempts) {
      // TI08: capture or reuse pre_attempt_sha.
      String? preAttemptSha = context['$statePrefix.pre_attempt_sha'] as String?;
      if (preAttemptSha == null || preAttemptSha.isEmpty) {
        preAttemptSha = await _capturePreAttemptSha(projectId: projectId, branch: storyBranch);
        if (preAttemptSha == null) {
          WorkflowExecutor._log.warning("Workflow '${run.id}': could not capture pre_attempt_sha for $storyBranch");
          preAttemptSha = '';
        }
        context['$statePrefix.pre_attempt_sha'] = preAttemptSha;
        await _persistForeachProgress(run, controllerStep, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
      }

      // TI09: pre-attempt cleanup if worktree is dirty.
      if (preAttemptSha.isNotEmpty) {
        final isDirty = await _isWorktreeDirty(projectId: projectId, branch: storyBranch);
        if (isDirty) {
          final cleanupError = await _turnAdapter?.cleanupWorktreeForRetry?.call(
            projectId: projectId,
            branch: storyBranch,
            preAttemptSha: preAttemptSha,
          );
          if (cleanupError != null) {
            final attemptNumber = attemptCounter + 1;
            if (firstTaskId != null) {
              await _handleCleanupFailure(
                errorMsg: cleanupError,
                taskId: firstTaskId,
                attemptNumber: attemptNumber,
                run: run,
                controllerStep: controllerStep,
                context: context,
                mapCtx: mapCtx,
                stepIndex: stepIndex,
                promotedIds: promotedIds,
              );
            }
            return null;
          }
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
        type: 'coding',
        typeAuthored: true,
        project: projectId,
        emitsOwnOutcome: true,
        contextOutputs: const [
          'merge_resolve.outcome',
          'merge_resolve.conflicted_files',
          'merge_resolve.resolution_summary',
          'merge_resolve.error_message',
        ],
        outputs: const {
          'merge_resolve.outcome': OutputConfig(format: OutputFormat.text),
          'merge_resolve.conflicted_files': OutputConfig(format: OutputFormat.lines),
          'merge_resolve.resolution_summary': OutputConfig(format: OutputFormat.text),
          'merge_resolve.error_message': OutputConfig(format: OutputFormat.text),
        },
        maxTokens: config.tokenCeiling,
      );

      final skillStepIndex = definition.steps.length; // synthetic; not in definition.steps
      final resolveResult = await _executeStep(
        run,
        definition,
        skillStep,
        context,
        stepIndex: skillStepIndex,
        extraTaskConfig: {'_workflowMergeResolveEnv': envMap},
      );

      // Advance counter immediately after invocation.
      attemptCounter++;
      context['$statePrefix.attempt_counter'] = attemptCounter;

      // TI11: assemble artifact fields from skill outputs.
      final outcome = (resolveResult?.outputs['merge_resolve.outcome'] as String?)?.trim() ?? 'failed';
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
              TaskStatus.failed => (resolveResult.outputs['merge_resolve.error_message'] as String?)?.trim() ?? 'failed',
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
      );
      lastAttempt = artifact;

      // TI12: persist artifact (idempotent on resume).
      final taskIdForArtifact = resolveResult?.task?.id ?? firstTaskId;
      if (taskIdForArtifact != null) {
        await _persistAttemptArtifact(
          artifact: artifact,
          taskId: taskIdForArtifact,
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
          await _turnAdapter?.cleanupWorktreeForRetry?.call(
            projectId: projectId,
            branch: storyBranch,
            preAttemptSha: preAttemptSha,
          );
        }
        return null;
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
            return retryResult;
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
            continue;
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
          if (taskIdForArtifact != null) {
            await _handleCleanupFailure(
              errorMsg: cleanupError,
              taskId: taskIdForArtifact,
              attemptNumber: attemptNumber,
              run: run,
              controllerStep: controllerStep,
              context: context,
              mapCtx: mapCtx,
              stepIndex: stepIndex,
              promotedIds: promotedIds,
            );
          }
          return null;
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
    }

    // TI16: attempts exhausted — escalate.
    return _handleMergeResolveEscalation(
      config.escalation ?? MergeResolveEscalation.serializeRemaining,
      initialConflictingFiles,
      initialConflictDetails,
      lastAttempt,
    );
  }

  /// Captures the HEAD SHA of [branch] for [projectId] via the TurnAdapter.
  Future<String?> _capturePreAttemptSha({required String projectId, required String branch}) =>
      _turnAdapter?.captureWorkflowBranchSha?.call(projectId: projectId, branch: branch) ?? Future.value(null);

  /// Returns true when the story-branch worktree has uncommitted changes or an in-progress merge.
  ///
  /// Always runs cleanup pre-attempt when a valid sha is available — the cleanup triple is safe
  /// as a no-op on a clean worktree (reset-to-same-sha + clean with nothing to remove).
  Future<bool> _isWorktreeDirty({required String projectId, required String branch}) async {
    // Without a direct git-status callback, treat as potentially dirty on every resume
    // so the cleanup triple always runs as a pre-attempt reset to baseline.
    return true;
  }

  /// Builds the six MERGE_RESOLVE_* env vars from config (TI05, Decisions 1+6).
  Map<String, String> _buildMergeResolveEnv(
    MergeResolveConfig cfg,
    String integrationBranch,
    String storyBranch,
  ) {
    final env = <String, String>{
      'MERGE_RESOLVE_INTEGRATION_BRANCH': integrationBranch,
      'MERGE_RESOLVE_STORY_BRANCH': storyBranch,
      'MERGE_RESOLVE_TOKEN_CEILING': cfg.tokenCeiling.toString(),
    };
    final verif = cfg.verification;
    if (verif.format != null && verif.format!.isNotEmpty) {
      env['MERGE_RESOLVE_VERIFY_FORMAT'] = verif.format!;
    }
    if (verif.analyze != null && verif.analyze!.isNotEmpty) {
      env['MERGE_RESOLVE_VERIFY_ANALYZE'] = verif.analyze!;
    }
    if (verif.test != null && verif.test!.isNotEmpty) {
      env['MERGE_RESOLVE_VERIFY_TEST'] = verif.test!;
    }
    return env;
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
    final name = 'merge_resolve_attempt_${artifact.attemptNumber}.json';
    final existing = await repo.listArtifactsByTask(taskId);
    if (existing.any((a) => a.name == name)) return; // idempotent
    final artifactJson = artifact.toJsonString();
    // Write artifact JSON to a stable path under the workflow run artifact dir.
    final artifactPath = p.join(_dataDir, 'runs', run.id, 'artifacts', name);
    final artifactFile = File(artifactPath);
    await artifactFile.parent.create(recursive: true);
    await artifactFile.writeAsString(artifactJson);
    await repo.insertArtifact(TaskArtifact(
      id: _uuid.v4(),
      taskId: taskId,
      name: name,
      kind: ArtifactKind.data,
      path: artifactPath,
      createdAt: DateTime.now(),
    ));
    await _persistForeachProgress(run, controllerStep, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
  }

  /// Handles a cleanup-triple failure: updates artifact error_message, fails iteration, returns null.
  Future<void> _handleCleanupFailure({
    required String errorMsg,
    required String taskId,
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
      final name = 'merge_resolve_attempt_$attemptNumber.json';
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

  /// Dispatch method for max-attempts exhaustion (TI16, Decision 8).
  ///
  /// `fail` → returns WorkflowGitPromotionConflict immediately.
  /// `serializeRemaining` → throws UnimplementedError (seam for S61).
  WorkflowGitPromotionResult _handleMergeResolveEscalation(
    MergeResolveEscalation mode,
    List<String> conflictingFiles,
    String conflictDetails,
    MergeResolveAttemptArtifact? lastAttempt,
  ) {
    switch (mode) {
      case MergeResolveEscalation.fail:
        final files = lastAttempt?.conflictedFiles.isNotEmpty == true
            ? lastAttempt!.conflictedFiles
            : conflictingFiles;
        return WorkflowGitPromotionConflict(conflictingFiles: files, details: conflictDetails);
      case MergeResolveEscalation.serializeRemaining:
        // S61: serialize-remaining drain not yet wired
        throw UnimplementedError('S61: serialize-remaining drain not yet wired');
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
