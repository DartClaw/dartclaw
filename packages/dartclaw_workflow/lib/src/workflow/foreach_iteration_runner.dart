part of 'workflow_executor.dart';

extension WorkflowExecutorForeachIterationRunner on WorkflowExecutor {
  Future<MapStepResult?> _executeForeachStep(
    WorkflowRun run,
    WorkflowDefinition definition,
    WorkflowStep controllerStep,
    List<String> childStepIds,
    WorkflowContext context, {
    required String? activeWorkspaceRoot,
    required Map<String, WorkflowStep> stepById,
    required int stepIndex,
    WorkflowExecutionCursor? resumeCursor,
    bool Function()? isCancelled,
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
    final maxItems = controllerStep.maxItems;
    if (maxItems != null && collection.length > maxItems) {
      return MapStepResult(
        results: const [],
        totalTokens: 0,
        success: false,
        error:
            "Foreach step '${controllerStep.id}': collection has ${collection.length} items "
            'which exceeds maxItems ($maxItems). '
            'Consider decomposing into smaller batches.',
      );
    }
    if (collection.isEmpty) {
      WorkflowExecutor._log.warning(
        "Workflow '${run.id}': foreach step '${controllerStep.id}' has empty collection – "
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
    final mapCtx = MapStepContext(collection: collection, maxParallel: maxParallel, maxItems: maxItems);
    final completedIds = <String>{};
    _restoreForeachProgress(mapCtx, completedIds, resumeCursor, collectionLength: collection.length);
    if (resumeCursor?.completedSubStepIdsByIndex.isNotEmpty == true) {
      context['_foreach.${controllerStep.id}.completedSubStepIdsByIndex'] = resumeCursor!.completedSubStepIdsByIndex
          .map((key, value) => MapEntry('$key', value));
    }
    await _persistForeachProgress(run, controllerStep, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
    final inFlight = <int, Future<void>>{};
    // Maps in-flight iteration index → task id for drain cancellation.
    final iterTaskIds = <int, String>{};
    final settledIndices = mapCtx.completedIndices;
    final pending = Queue<int>.from(
      List.generate(collection.length, (i) => i).where((i) => !settledIndices.contains(i)),
    );
    var inFlightWake = Completer<void>();
    void wakeInFlightLoop() {
      if (!inFlightWake.isCompleted) {
        inFlightWake.complete();
      }
    }

    Future<void> waitForInFlightWake() async {
      if (inFlight.isEmpty) return;
      await inFlightWake.future;
      inFlightWake = Completer<void>();
    }

    var totalTokens = 0;
    // Drain-failure message is set by the drain path; when non-null, abort loop.
    String? drainFailureMessage;
    // Controller-level failure message (budget exhaustion, unexpected exceptions).
    String? controllerFailureMessage;
    void emitCancelledIterationEvents(Iterable<int> indices) {
      for (final index in indices) {
        _eventBus.fire(
          MapIterationCompletedEvent(
            runId: run.id,
            stepId: controllerStep.id,
            iterationIndex: index,
            totalIterations: mapCtx.collection.length,
            itemId: mapCtx.itemId(index),
            taskId: '',
            success: false,
            tokenCount: 0,
            timestamp: DateTime.now(),
          ),
        );
      }
    }

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
        controllerFailureMessage ??= "foreach-controller-failure: foreach step '${controllerStep.id}' budget exhausted";
        final cancelledByBudget = <int>[];
        while (pending.isNotEmpty) {
          final cancelledIndex = pending.removeFirst();
          mapCtx.recordCancelled(cancelledIndex, 'Cancelled: budget exhausted');
          cancelledByBudget.add(cancelledIndex);
        }
        await _persistForeachProgress(
          run,
          controllerStep,
          context,
          mapCtx,
          stepIndex: stepIndex,
          promotedIds: promotedIds,
        );
        emitCancelledIterationEvents(cancelledByBudget);
        break;
      }
      final isSerialMode = context['_merge_resolve.${controllerStep.id}.serialize_remaining_phase'] != null;
      final poolAvailable = _turnAdapter?.availableRunnerCount?.call();
      final concurrencyCap = isSerialMode ? 1 : mapCtx.effectiveConcurrency(poolAvailable);
      while (inFlight.length < concurrencyCap && pending.isNotEmpty) {
        // Skip if cancelled.
        if (mapCtx.budgetExhausted) break;
        if (isCancelled?.call() ?? false) break;
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
        final iterationFuture = (() async {
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
              activeWorkspaceRoot: activeWorkspaceRoot,
              isCancelled: isCancelled,
            );
          } catch (e, st) {
            WorkflowExecutor._log.severe(
              "Workflow '${run.id}': foreach step '${controllerStep.id}' iteration $iterIndex failed unexpectedly: $e",
              e,
              st,
            );
            if (!mapCtx.completedIndices.contains(iterIndex)) {
              controllerFailureMessage =
                  "foreach-controller-failure: foreach step '${controllerStep.id}' iteration $iterIndex failed unexpectedly: $e";
              await recordIterationFailureAndDecrement(
                _eventBus,
                mapCtx: mapCtx,
                iterIndex: iterIndex,
                failureMessage: 'Unexpected iteration error: $e',
                taskId: iterTaskIds[iterIndex],
                run: run,
                step: controllerStep,
                iterTokens: 0,
                persistProgress: () => _persistForeachProgress(
                  run,
                  controllerStep,
                  context,
                  mapCtx,
                  stepIndex: stepIndex,
                  promotedIds: promotedIds,
                ),
              );
            }
            // Unexpected exceptions signal a controller-level invariant breach.
            // Abort remaining iterations rather than silently re-dispatching.
            mapCtx.budgetExhausted = true;
          }
        })().catchError((_) {});
        inFlight[iterIndex] = iterationFuture.whenComplete(() {
          inFlight.remove(iterIndex);
          mapCtx.inFlightCount = inFlight.length;
          iterTaskIds.remove(iterIndex);
          final itemId = mapCtx.itemId(iterIndex);
          if (itemId != null) completedIds.add(itemId);
          wakeInFlightLoop();
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
            "Workflow '${run.id}': foreach step '${controllerStep.id}' – "
            '${pending.length} items remain blocked on unresolved promoted dependencies; leaving them pending for resume.',
          );
          if (controllerStep.onFailure == OnFailurePolicy.continueWorkflow) {
            final cancelledByDep = <int>[];
            while (pending.isNotEmpty) {
              final cancelledIndex = pending.removeFirst();
              mapCtx.recordCancelled(cancelledIndex, 'Cancelled: dependency failed');
              cancelledByDep.add(cancelledIndex);
            }
            await _persistForeachProgress(
              run,
              controllerStep,
              context,
              mapCtx,
              stepIndex: stepIndex,
              promotedIds: promotedIds,
            );
            emitCancelledIterationEvents(cancelledByDep);
          }
          break;
        }

        final cancellationMessage = depGraph.hasDependencies
            ? 'Cancelled: dependency deadlock'
            : 'Cancelled: dispatch stall';
        WorkflowExecutor._log.warning(
          "Workflow '${run.id}': foreach step '${controllerStep.id}' – "
          '${pending.length} items stalled; cancelling.',
        );
        final cancelledByStall = <int>[];
        while (pending.isNotEmpty) {
          final cancelledIndex = pending.removeFirst();
          mapCtx.recordCancelled(cancelledIndex, cancellationMessage);
          cancelledByStall.add(cancelledIndex);
        }
        await _persistForeachProgress(
          run,
          controllerStep,
          context,
          mapCtx,
          stepIndex: stepIndex,
          promotedIds: promotedIds,
        );
        emitCancelledIterationEvents(cancelledByStall);
        break;
      }
      if (inFlight.isEmpty) break;
      await waitForInFlightWake();

      // If serialize-remaining fired during this tick, perform drain + re-queue.
      final completedSerializeIter = pendingSerializeRemainingIteration();
      if (completedSerializeIter != null) {
        await enactSerializeRemaining(completedSerializeIter);
        continue;
      }

      final refreshedRun = await _repository.getById(run.id) ?? run;
      run = refreshedRun;
      if (run.status == WorkflowRunStatus.awaitingApproval ||
          run.status == WorkflowRunStatus.paused ||
          run.status == WorkflowRunStatus.cancelled) {
        return null;
      }
      if (_workflowBudgetExceeded(run, definition)) {
        mapCtx.budgetExhausted = true;
        controllerFailureMessage ??= "foreach-controller-failure: foreach step '${controllerStep.id}' budget exhausted";
      }
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
    if (controllerFailureMessage != null) {
      return MapStepResult(
        results: List<dynamic>.from(mapCtx.results),
        totalTokens: totalTokens,
        success: false,
        error: controllerFailureMessage,
      );
    }
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
      final hasPromotionFailure = mapCtx.failedIndices.any((index) {
        final slot = mapCtx.results[index];
        final message = slot is Map ? slot['message'] as String? : null;
        return message?.startsWith('promotion failed:') == true;
      });
      return MapStepResult(
        results: List<dynamic>.from(mapCtx.results),
        totalTokens: totalTokens,
        success: false,
        error:
            controllerFailureMessage ??
            (hasPromotionConflict
                ? "promotion-conflict: foreach step '${controllerStep.id}' has unresolved promotion conflicts"
                : hasPromotionFailure
                ? "promotion-failure: foreach step '${controllerStep.id}' has unpromoted item failures"
                : "Foreach step '${controllerStep.id}': ${mapCtx.failedIndices.length} iteration(s) failed"),
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
    required String? activeWorkspaceRoot,
    bool Function()? isCancelled,
  }) async {
    // Check for cancellation before doing any work for this iteration.
    if (isCancelled?.call() ?? false) return;
    if (mapCtx.budgetExhausted) return;

    final iterData = Map<String, dynamic>.from(context.data);
    iterData['map'] = {'item': mapContext.item, 'index': mapContext.index, 'length': mapContext.length};
    // Flat aliases preserve existing template references while gates use the nested map.
    iterData['map.item'] = mapContext.item;
    iterData['map.index'] = mapContext.index;
    iterData['map.length'] = mapContext.length;
    final iterContext = WorkflowContext(
      data: iterData,
      variables: context.variables,
      systemVariables: context.systemVariables,
    );
    int iterTokens = 0;
    Map<String, dynamic> iterResult = {};
    String? firstTaskId;
    final completedSubStepIds = _completedForeachSubStepIds(context, controllerStep.id, iterIndex);

    Future<void> persistProgress() =>
        _persistForeachProgress(run, controllerStep, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);

    Future<void> failAndReturn(String message, String? taskId) {
      _clearCompletedForeachSubStepIds(context, controllerStep.id, iterIndex);
      return recordIterationFailureAndDecrement(
        _eventBus,
        mapCtx: mapCtx,
        iterIndex: iterIndex,
        failureMessage: message,
        taskId: taskId,
        run: run,
        step: controllerStep,
        iterTokens: iterTokens,
        persistProgress: persistProgress,
      );
    }

    for (var childIndex = 0; childIndex < childSteps.length; childIndex++) {
      final childStep = childSteps[childIndex];
      if (completedSubStepIds.contains(childStep.id)) {
        _restoreCompletedForeachSubStep(context, iterContext, childStep.id, iterIndex);
        iterResult[childStep.id] = _restoredForeachSubStepOutputs(context, childStep, iterIndex);
        continue;
      }
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
        activeWorkspaceRoot: activeWorkspaceRoot,
        stepIndex: childStepIndex,
        mapCtx: mapContext,
        enclosingMaxParallel: controllerMaxParallel,
      );
      if (result == null) {
        await failAndReturn("Foreach child step '${childStep.id}' failed to create task", null);
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
        _persistForeachSubStepSessionKeys(context, iterContext, childStep.id, iterIndex);
        context['${childStep.id}[$iterIndex].status'] = iterContext['${childStep.id}.status'];
        if (result.outcome != null) {
          context['step.${childStep.id}[$iterIndex].outcome'] = result.outcome!;
        }
        if (result.outcomeReason != null && result.outcomeReason!.isNotEmpty) {
          context['step.${childStep.id}[$iterIndex].outcome.reason'] = result.outcomeReason!;
        }
        if (result.awaitingApproval &&
            controllerStep.onFailure != OnFailurePolicy.continueWorkflow &&
            !_hasPriorForeachFailures(mapCtx, iterIndex)) {
          iterResult[childStep.id] = Map<String, dynamic>.from(result.outputs);
          completedSubStepIds.add(childStep.id);
          _writeCompletedForeachSubStepIds(context, controllerStep.id, iterIndex, completedSubStepIds);
          await persistProgress();
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
              displayScope: _mapItemDisplayScope(mapContext),
            ),
          );
          final refreshedRun = await _repository.getById(run.id) ?? run;
          run = refreshedRun;
          await _transitionStepAwaitingApproval(
            run,
            childStep,
            context,
            stepIndex: childStepIndex,
            reason: result.outcomeReason ?? "Foreach child step '${childStep.id}' requires input",
          );
          return;
        }
        await failAndReturn("Foreach child step '${childStep.id}' failed", result.task?.id);
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
            displayScope: _mapItemDisplayScope(mapContext),
          ),
        );
        return;
      }
      _mergeStepResultIntoContext(iterContext, result, fallbackStatus: result.task?.status.name ?? 'completed');
      for (final entry in result.outputs.entries) {
        context['${childStep.id}[$iterIndex].${entry.key}'] = entry.value;
      }
      _persistForeachSubStepSessionKeys(context, iterContext, childStep.id, iterIndex);
      context['${childStep.id}[$iterIndex].status'] = iterContext['${childStep.id}.status'];
      context['${childStep.id}[$iterIndex].tokenCount'] = tokenCount;
      if (result.outcome != null) {
        context['step.${childStep.id}[$iterIndex].outcome'] = result.outcome!;
      }
      if (result.outcomeReason != null && result.outcomeReason!.isNotEmpty) {
        context['step.${childStep.id}[$iterIndex].outcome.reason'] = result.outcomeReason!;
      }
      iterResult[childStep.id] = Map<String, dynamic>.from(result.outputs);
      completedSubStepIds.add(childStep.id);
      _writeCompletedForeachSubStepIds(context, controllerStep.id, iterIndex, completedSubStepIds);
      await persistProgress();
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
          displayScope: _mapItemDisplayScope(mapContext),
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
        await failAndReturn('promotion failed: host promotion callback is not configured', firstTaskId);
        return;
      }
      if (projectId == null || projectId.isEmpty) {
        await failAndReturn('promotion failed: foreach iteration has no project binding', firstTaskId);
        return;
      }
      if (storyBranch == null || storyBranch.isEmpty) {
        await failAndReturn('promotion failed: task worktree branch is unavailable', firstTaskId);
        return;
      }
      if (integrationBranch == null || integrationBranch.isEmpty) {
        await failAndReturn('promotion failed: integration branch is not initialized', firstTaskId);
        return;
      }
      final promotionResult = await callPromote(
        promote: promote,
        runId: run.id,
        projectId: projectId,
        branch: storyBranch,
        integrationBranch: integrationBranch,
        strategy: promotionStrategy,
        storyId: storyId,
        conflictingFiles: const [],
        conflictDetails: '',
        mergeResolveEnabled: definition.gitStrategy?.mergeResolve.enabled == true,
      );
      switch (promotionResult) {
        case PromotionSuccess(:final commitSha):
          if (storyId != null && storyId.isNotEmpty) promotedIds.add(storyId);
          context['${controllerStep.id}[$iterIndex].promotion'] = 'success';
          context['${controllerStep.id}[$iterIndex].promotion_sha'] = commitSha;
        case PromotionConflict(:final conflictingFiles, :final details):
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
              controllerMaxParallel: controllerMaxParallel,
              activeWorkspaceRoot: activeWorkspaceRoot,
            );
            if (resolveResult == null) {
              await failAndReturn('merge-resolve failed', firstTaskId);
              return;
            }
            switch (resolveResult) {
              case WorkflowGitPromotionSuccess(:final commitSha):
                if (storyId != null && storyId.isNotEmpty) promotedIds.add(storyId);
                context['${controllerStep.id}[$iterIndex].promotion'] = 'success';
                context['${controllerStep.id}[$iterIndex].promotion_sha'] = commitSha;
              case WorkflowGitPromotionSerializeRemaining():
                // Outer loop detects serializing_iter_index and drains siblings.
                _clearCompletedForeachSubStepIds(context, controllerStep.id, iterIndex);
                mapCtx.inFlightCount--;
                return;
              case WorkflowGitPromotionConflict():
              case WorkflowGitPromotionError():
                final conflictMsg =
                    'promotion-conflict: ${conflictingFiles.isEmpty ? 'merge conflict' : conflictingFiles.join(', ')}';
                context['${controllerStep.id}[$iterIndex].promotion'] = 'conflict';
                context['${controllerStep.id}[$iterIndex].promotion_details'] = details;
                await failAndReturn(conflictMsg, firstTaskId);
                return;
            }
          } else {
            // merge-resolve disabled – byte-identical to pre-feature behavior.
            context['${controllerStep.id}[$iterIndex].promotion'] = 'conflict';
            context['${controllerStep.id}[$iterIndex].promotion_details'] = details;
            await failAndReturn(
              'promotion-conflict: ${conflictingFiles.isEmpty ? 'merge conflict' : conflictingFiles.join(', ')}',
              firstTaskId,
            );
            return;
          }
        case PromotionError(:final failureMessage):
          context['${controllerStep.id}[$iterIndex].promotion'] = 'failed';
          await failAndReturn(failureMessage, firstTaskId);
          return;
        case PromotionSerializeRemaining():
          // Direct promote() never returns this sentinel; only merge-resolve does.
          _clearCompletedForeachSubStepIds(context, controllerStep.id, iterIndex);
          mapCtx.inFlightCount--;
          return;
        case PromotionNotConfigured():
        case PromotionNoProjectBinding():
        case PromotionNoBranch():
        case PromotionNoIntegrationBranch():
          // These are handled above via explicit guard checks before callPromote.
          break;
      }
    }
    mapCtx.recordResult(iterIndex, iterResult);
    await persistProgress();
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
      completedSubStepIdsByIndex: _completedForeachSubStepsByIndex(context, step.id),
    );
    final updatedRun = refreshedRun.copyWith(
      executionCursor: cursor,
      contextJson: {
        ...privateContextEntries(refreshedRun.contextJson, exclude: '_foreach.current'),
        ...context.toJson(),
        '_foreach.current.stepId': step.id,
        '_foreach.current.total': mapCtx.collection.length,
        '_foreach.current.completedIndices': cursor.completedIndices,
        '_foreach.current.failedIndices': cursor.failedIndices,
        '_foreach.current.cancelledIndices': cursor.cancelledIndices,
        '_foreach.${step.id}.completedSubStepIdsByIndex': cursor.completedSubStepIdsByIndex.map(
          (key, value) => MapEntry('$key', value),
        ),
        '_map.${step.id}.promotedIds': context['_map.${step.id}.promotedIds'],
      },
      updatedAt: DateTime.now(),
    );
    await _persistContext(run.id, context);
    await _repository.update(updatedRun);
  }
}

bool _hasPriorForeachFailures(MapStepContext mapCtx, int currentIndex) =>
    mapCtx.failedIndices.any((index) => index != currentIndex);

Set<String> _completedForeachSubStepIds(WorkflowContext context, String stepId, int iterIndex) {
  final byIndex = _completedForeachSubStepsByIndex(context, stepId);
  return byIndex[iterIndex]?.toSet() ?? <String>{};
}

Map<int, List<String>> _completedForeachSubStepsByIndex(WorkflowContext context, String stepId) {
  final raw = context['_foreach.$stepId.completedSubStepIdsByIndex'];
  if (raw is! Map) return const {};
  return {
    for (final entry in raw.entries)
      int.parse('${entry.key}'):
          (entry.value as List?)?.whereType<String>().toList(growable: false) ?? const <String>[],
  };
}

void _writeCompletedForeachSubStepIds(WorkflowContext context, String stepId, int iterIndex, Set<String> completed) {
  final byIndex = _completedForeachSubStepsByIndex(context, stepId);
  context['_foreach.$stepId.completedSubStepIdsByIndex'] = {
    for (final entry in byIndex.entries) '${entry.key}': entry.value,
    '$iterIndex': (completed.toList()..sort()),
  };
}

void _clearCompletedForeachSubStepIds(WorkflowContext context, String stepId, int iterIndex) {
  final byIndex = Map<int, List<String>>.from(_completedForeachSubStepsByIndex(context, stepId))..remove(iterIndex);
  context['_foreach.$stepId.completedSubStepIdsByIndex'] = {
    for (final entry in byIndex.entries) '${entry.key}': entry.value,
  };
}

void _restoreCompletedForeachSubStep(
  WorkflowContext source,
  WorkflowContext target,
  String childStepId,
  int iterIndex,
) {
  final prefix = '$childStepId[$iterIndex].';
  for (final entry in source.data.entries) {
    if (!entry.key.startsWith(prefix)) continue;
    final restoredKey = entry.key.substring(prefix.length);
    if (_isForeachSubStepContextMetadataKey(restoredKey)) {
      target['$childStepId.$restoredKey'] = entry.value;
    } else if (restoredKey.startsWith('$childStepId.')) {
      target[restoredKey] = entry.value;
    } else {
      target[restoredKey] = entry.value;
    }
  }
  final status = source['$childStepId[$iterIndex].status'];
  if (status != null) {
    target['$childStepId.status'] = status;
  }
}

Map<String, dynamic> _restoredForeachSubStepOutputs(WorkflowContext source, WorkflowStep childStep, int iterIndex) {
  final prefix = '${childStep.id}[$iterIndex].';
  return {
    for (final entry in source.data.entries)
      if (entry.key.startsWith(prefix) && !_isForeachSubStepMetadataKey(entry.key.substring(prefix.length)))
        entry.key.substring(prefix.length): entry.value,
  };
}

bool _isForeachSubStepMetadataKey(String key) =>
    key == 'status' ||
    key == 'tokenCount' ||
    key == 'sessionId' ||
    key == 'providerSessionId' ||
    key.endsWith('.providerSessionId');

bool _isForeachSubStepContextMetadataKey(String key) =>
    key == 'status' || key == 'tokenCount' || key == 'sessionId' || key == 'providerSessionId';

void _persistForeachSubStepSessionKeys(
  WorkflowContext target,
  WorkflowContext source,
  String childStepId,
  int iterIndex,
) {
  for (final key in const ['sessionId', 'providerSessionId']) {
    final value = source['$childStepId.$key'];
    if (value is String && value.isNotEmpty) {
      target['$childStepId[$iterIndex].$key'] = value;
    }
  }
}
