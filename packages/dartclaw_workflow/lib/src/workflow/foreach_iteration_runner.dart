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
    final resolvedCollection = resolveIterationCollection(
      context[controllerStep.mapOver!],
      stepKind: 'Foreach',
      stepId: controllerStep.id,
      mapOverKey: controllerStep.mapOver!,
    );
    if (resolvedCollection.error != null) {
      return MapStepResult(results: const [], totalTokens: 0, success: false, error: resolvedCollection.error);
    }
    final collection = resolvedCollection.collection!;
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
    final resolvedWorktreeMode = step_config_policy.resolveWorktreeMode(
      strategy,
      maxParallel: maxParallel,
      isMap: true,
    );
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
    // An inline worktree shares the operator's live checkout, so iterations
    // must run one at a time regardless of maxParallel — concurrent items would
    // clobber the shared tree. Keyed on the resolved mode (which now treats a
    // null strategy as `auto`, so a parallel foreach resolves to `per-map-item`
    // and keeps its fan-out on isolated worktrees); only a genuine inline scope
    // (authored `worktree: inline` or `--inline`) serializes here, matching the
    // dispatcher's worktree-provisioning gate.
    final effectiveMaxParallel = resolvedWorktreeMode == 'inline' ? 1 : maxParallel;
    final mapCtx = MapStepContext(collection: collection, maxParallel: effectiveMaxParallel, maxItems: maxItems);
    final completedIds = <String>{};
    restoreIterationProgress(
      mapCtx,
      completedIds,
      resumeCursor,
      nodeType: WorkflowExecutionCursorNodeType.foreach,
      collectionLength: collection.length,
      markFailedAndCancelledItemsReady: false,
    );
    if (resumeCursor?.completedSubStepIdsByIndex.isNotEmpty == true) {
      context['_foreach.${controllerStep.id}.completedSubStepIdsByIndex'] = resumeCursor!.completedSubStepIdsByIndex
          .map((key, value) => MapEntry('$key', value));
    }
    await _persistForeachProgress(run, controllerStep, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
    final firstTaskIds = <int, String>{};
    final settledIndices = mapCtx.completedIndices;
    final engine = _IterationDispatchEngine(
      mapCtx: mapCtx,
      depGraph: depGraph,
      pendingIndices: List.generate(collection.length, (i) => i).where((i) => !settledIndices.contains(i)),
      completedIds: completedIds,
      promotedIds: promotedIds,
      promotionAware: promotionAware,
    );

    var totalTokens = 0;
    String? serializeFailureMessage;
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
      final state = _SerializeRemainingState.read(context, stepId: controllerStep.id);
      if (state == null || state.phase == _SerializeRemainingPhase.drained) return null;
      return state.iterIndex;
    }

    Future<void> enactSerializeRemaining(int serializeIter) async {
      final serializeResult = await _enactSerializeRemaining(
        run: run,
        controllerStep: controllerStep,
        context: context,
        mapCtx: mapCtx,
        pending: engine.pending,
        inFlight: engine.inFlight,
        failingIterIndex: serializeIter,
        stepIndex: stepIndex,
        promotedIds: promotedIds,
      );
      if (serializeResult != null) {
        serializeFailureMessage = serializeResult;
      }
    }

    while (engine.hasWork(hasSerializedWork: pendingSerializeRemainingIteration() != null)) {
      if (serializeFailureMessage != null) break;
      final serializeIter = pendingSerializeRemainingIteration();
      if (serializeIter != null) {
        await enactSerializeRemaining(serializeIter);
        continue;
      }
      if (mapCtx.budgetExhausted) {
        controllerFailureMessage ??= "foreach-controller-failure: foreach step '${controllerStep.id}' budget exhausted";
        final cancelledByBudget = engine.cancelPending('Cancelled: budget exhausted');
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
      // An aborted item stops all further dispatch; in-flight siblings settle
      // on their own paths before the run pauses.
      if (mapCtx.aborted) break;
      final isSerialMode = _SerializeRemainingState.read(context, stepId: controllerStep.id) != null;
      final poolAvailable = _turnAdapter?.availableRunnerCount?.call();
      while (engine.canDispatch(poolAvailable: poolAvailable, serialMode: isSerialMode)) {
        // Skip if cancelled.
        if (mapCtx.budgetExhausted) break;
        if (mapCtx.aborted) break;
        if (isCancelled?.call() ?? false) break;
        final nextIndex = engine.takeNextReadyIndex();
        if (nextIndex == null) break;

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
              firstTaskIds: firstTaskIds,
              activeWorkspaceRoot: activeWorkspaceRoot,
              // A serialize-exhausted iteration removes itself from `inFlight`
              // when it returns the sentinel. Re-queue it so the serialize
              // enactment still sees it if a sibling snapshots `inFlight`
              // after this removal — otherwise a distinct exhausted iteration
              // could be dropped from the serial queue.
              requeueSerializeExhausted: (idx) {
                if (!engine.pending.contains(idx)) engine.pending.add(idx);
              },
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
                taskId: firstTaskIds[iterIndex],
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
        engine.track(
          iterIndex,
          iterationFuture,
          onSettled: (iterIndex) {
            final itemId = mapCtx.itemId(iterIndex);
            // Only a genuinely successful prerequisite makes its dependents ready.
            // A failed or blocked item must keep its dependents undispatched so the
            // controller can pause for a human when an open dependent exists. An
            // aborted pass adds no ready ids: interrupted items settle in no index
            // set, so without the guard they would read as succeeded.
            final succeeded =
                !mapCtx.aborted &&
                !mapCtx.failedIndices.contains(iterIndex) &&
                !mapCtx.blockedIndices.contains(iterIndex) &&
                !mapCtx.cancelledIndices.contains(iterIndex);
            if (itemId != null && succeeded) completedIds.add(itemId);
          },
        );
      }
      if (engine.isDispatchStalled) {
        if (depGraph.hasDependencies &&
            (controllerStep.onFailure != OnFailurePolicy.continueWorkflow || mapCtx.hasBlocked)) {
          final hold = _foreachDependencyHold(
            depGraph,
            mapCtx,
            engine.pending,
            includeFailures: controllerStep.onFailure != OnFailurePolicy.continueWorkflow,
          );
          if (hold != null) {
            await _persistForeachProgress(
              run,
              controllerStep,
              context,
              mapCtx,
              stepIndex: stepIndex,
              promotedIds: promotedIds,
            );
            final refreshedRun = await _repository.getById(run.id) ?? run;
            await _transitionStepAwaitingApproval(
              refreshedRun,
              controllerStep,
              context,
              stepIndex: stepIndex,
              reason: hold,
            );
            return null;
          }
        }
        if (promotionAware && depGraph.hasDependencies && (mapCtx.failedIndices.isNotEmpty || mapCtx.hasBlocked)) {
          WorkflowExecutor._log.warning(
            "Workflow '${run.id}': foreach step '${controllerStep.id}' – "
            '${engine.pending.length} items remain blocked on unresolved dependencies; leaving them pending for resume.',
          );
          if (controllerStep.onFailure == OnFailurePolicy.continueWorkflow) {
            final cancelledByDep = engine.cancelPending('Cancelled: dependency failed');
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
          '${engine.pending.length} items stalled; cancelling.',
        );
        final cancelledByStall = engine.cancelPending(cancellationMessage);
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
      if (!engine.hasInFlight) break;
      await engine.waitForWake();

      final refreshedRun = await _repository.getById(run.id) ?? run;
      run = refreshedRun;
      if (run.status == WorkflowRunStatus.awaitingApproval ||
          run.status == WorkflowRunStatus.paused ||
          run.status == WorkflowRunStatus.cancelled) {
        return null;
      }
      // Foreach-scope tokens reach run.totalTokens only at foreach completion,
      // so the mid-foreach check (and the 80% warning) adds them back as an
      // evaluation-only basis from the persisted per-child/loop-checkpoint keys.
      final foreachConsumedTokens = workflow_budget_monitor.foreachScopeConsumedTokens(
        context.data,
        foreachStepId: controllerStep.id,
        childStepIds: childStepIds,
      );
      run = await _checkWorkflowBudgetWarning(run, definition, additionalTokens: foreachConsumedTokens);
      if (_workflowBudgetExceeded(run, definition, additionalTokens: foreachConsumedTokens)) {
        mapCtx.budgetExhausted = true;
        controllerFailureMessage ??= "foreach-controller-failure: foreach step '${controllerStep.id}' budget exhausted";
      }
    }
    if (serializeFailureMessage != null) {
      return MapStepResult(results: const [], totalTokens: 0, success: false, error: serializeFailureMessage);
    }
    if (engine.hasInFlight) {
      final activeSerializeState = _SerializeRemainingState.read(context, stepId: controllerStep.id);
      if (activeSerializeState != null && activeSerializeState.phase == _SerializeRemainingPhase.enacting) {
        final remainingTimeout = _remainingSerializeRemainingSettleTimeout(
          activeSerializeState,
          _serializeRemainingSettleTimeout,
        );
        if (remainingTimeout == Duration.zero) {
          return MapStepResult(
            results: const [],
            totalTokens: 0,
            success: false,
            error:
                "serialize-remaining settle-timeout: foreach step '${controllerStep.id}' still had "
                '${engine.inFlight.length} in-flight iteration(s) after '
                '${_serializeRemainingSettleTimeout.inMilliseconds}ms',
          );
        }
        try {
          await Future.wait(engine.inFlight.values, eagerError: false).timeout(remainingTimeout);
        } on TimeoutException {
          return MapStepResult(
            results: const [],
            totalTokens: 0,
            success: false,
            error:
                "serialize-remaining settle-timeout: foreach step '${controllerStep.id}' still had "
                '${engine.inFlight.length} in-flight iteration(s) after '
                '${_serializeRemainingSettleTimeout.inMilliseconds}ms',
          );
        }
      } else {
        await Future.wait(engine.inFlight.values, eagerError: false);
      }
    }
    if (mapCtx.aborted) {
      WorkflowExecutor._log.info(
        "Workflow '${run.id}': foreach step '${controllerStep.id}' aborted before settling all items",
      );
      await _persistForeachProgress(
        run,
        controllerStep,
        context,
        mapCtx,
        stepIndex: stepIndex,
        promotedIds: promotedIds,
      );
      // Deferred pause: siblings have settled, so no in-flight task wait gets
      // aborted into a spurious failure. No-ops when a teardown or hold
      // already moved the run off `running`.
      await _pauseRun(
        run,
        mapCtx.abortReason ?? "Foreach step '${controllerStep.id}' was interrupted and can be resumed.",
      );
      return null;
    }
    for (var i = 0; i < collection.length; i++) {
      for (final childStep in childSteps) {
        final t = context['${childStep.id}[$i].tokenCount'];
        if (t is int) totalTokens += t;
      }
    }
    // Surface the controller-level token total under the same `<stepId>.tokenCount`
    // key non-foreach steps use, so the settle-time digest reports per-story tokens
    // for the foreach controller row (foreach otherwise only writes per-child keys).
    context['${controllerStep.id}.tokenCount'] = totalTokens;
    _eventBus.fire(
      MapStepCompletedEvent(
        runId: run.id,
        stepId: controllerStep.id,
        stepName: controllerStep.name,
        totalIterations: collection.length,
        successCount: mapCtx.successCount,
        failureCount: mapCtx.failedIndices.length,
        cancelledCount: mapCtx.cancelledCount,
        blockedCount: mapCtx.blockedCount,
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
    final escalatedHold = _foreachEscalatedHold(mapCtx);
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
            (escalatedHold != null
                ? "foreach-hard-failure-with-escalation: Foreach step '${controllerStep.id}': "
                      '${mapCtx.failedIndices.length} iteration(s) failed; escalation-marked blocked item(s) '
                      'also require review'
                : hasPromotionConflict
                ? "promotion-conflict: foreach step '${controllerStep.id}' has unresolved promotion conflicts"
                : hasPromotionFailure
                ? "promotion-failure: foreach step '${controllerStep.id}' has unpromoted item failures"
                : "Foreach step '${controllerStep.id}': ${mapCtx.failedIndices.length} iteration(s) failed"),
      );
    }
    // An escalated remediation exhaustion (`onMaxIterations: escalate`) is an
    // explicit "a human must look" signal, so a blocked item carrying the
    // escalation marker forces an approval hold on the settle path independent
    // of dependency topology – a leaf or single-story plan must not ship its
    // residual in the settle digest only. Unmarked blocked items keep advancing
    // in the branch below. Persist-before-transition mirrors the dependency-hold
    // seam so a crash resumes at the persisted cursor with the item still pending.
    if (escalatedHold != null) {
      await _persistForeachProgress(
        run,
        controllerStep,
        context,
        mapCtx,
        stepIndex: stepIndex,
        promotedIds: promotedIds,
      );
      final refreshedRun = await _repository.getById(run.id) ?? run;
      await _transitionStepAwaitingApproval(
        refreshedRun,
        controllerStep,
        context,
        stepIndex: stepIndex,
        reason: escalatedHold,
      );
      return null;
    }
    if (mapCtx.hasBlocked) {
      // No hard failures, no escalation marker, and no pause: blocked items had
      // no open dependents, so the run advances and the digest reports them.
      // Mark the controller-level outcome blocked (recoverable) – never from
      // inside an iteration. The reason names the blocked items so downstream
      // surfaces (digest, publish notes) can list what shipped unresolved.
      final blockedIds = [
        for (final index in mapCtx.blockedIndices.toList()..sort()) mapCtx.itemId(index) ?? 'item #$index',
      ];
      context['step.${controllerStep.id}.outcome'] = 'blocked';
      context['step.${controllerStep.id}.outcome.reason'] =
          "Foreach step '${controllerStep.id}': ${mapCtx.blockedCount} item(s) blocked (recoverable): "
          '${_sanitizeAgentReportedText(blockedIds.join(', '))}';
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
    required Map<int, String> firstTaskIds,
    required String? activeWorkspaceRoot,
    required void Function(int iterIndex) requeueSerializeExhausted,
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
    void recordFirstTaskId(String taskId) {
      firstTaskIds.putIfAbsent(iterIndex, () => taskId);
      firstTaskId ??= taskId;
    }

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
      // Between children, re-check the budget against the foreach-scope basis so
      // an item stops once earlier children (its own or a sibling iteration's)
      // exhaust the budget, instead of running to its own limit. The first child
      // is covered by the controller's pre-dispatch checks.
      if (childIndex > 0) {
        if (!mapCtx.budgetExhausted &&
            _workflowBudgetExceeded(
              run,
              definition,
              additionalTokens: workflow_budget_monitor.foreachScopeConsumedTokens(
                context.data,
                foreachStepId: controllerStep.id,
                childStepIds: [for (final step in childSteps) step.id],
              ),
            )) {
          mapCtx.budgetExhausted = true;
        }
        if (mapCtx.budgetExhausted) {
          await failAndReturn(
            "Foreach child step '${childStep.id}' not dispatched: workflow budget exceeded",
            firstTaskId,
          );
          return;
        }
      }
      final childStepIndex = definition.steps.indexOf(childStep);
      final skippedRun = await _skipDueToEntryGate(run, childStep, childStepIndex, iterContext);
      if (skippedRun != null) {
        run = skippedRun;
        continue;
      }
      final nestedLoopScope = childStep.taskType == WorkflowTaskType.loop
          ? _NestedLoopScope(
              foreachStepId: controllerStep.id,
              iterIndex: iterIndex,
              childStepIds: [for (final step in childSteps) step.id],
              runContext: context,
              persist: persistProgress,
              isCancelled: isCancelled,
              mapContext: mapContext,
              enclosingMaxParallel: controllerMaxParallel,
              onFirstTaskCreated: recordFirstTaskId,
            )
          : null;
      final result = await _executeStep(
        run,
        definition,
        childStep,
        iterContext,
        activeWorkspaceRoot: activeWorkspaceRoot,
        stepIndex: childStepIndex,
        mapCtx: mapContext,
        enclosingMaxParallel: controllerMaxParallel,
        onFirstTaskCreated: recordFirstTaskId,
        nestedLoopScope: nestedLoopScope,
      );
      if (result == null) {
        final latest = await _repository.getById(run.id);
        final status = latest?.status ?? run.status;
        if (status == WorkflowRunStatus.paused ||
            status == WorkflowRunStatus.awaitingApproval ||
            status == WorkflowRunStatus.cancelled) {
          // The task wait was aborted by a run-level transition (teardown,
          // pause, or a sibling's dependency hold) – not a task-creation
          // failure. Leave the iteration unsettled so resume re-runs it,
          // mirroring the map dispatcher's abort seam.
          mapCtx.aborted = true;
          await persistProgress();
          mapCtx.inFlightCount--;
          return;
        }
        await failAndReturn("Foreach child step '${childStep.id}' failed to create task", null);
        return;
      }
      if (childIndex == 0) {
        firstTaskId = result.task?.id;
      }
      final tokenCount = result.tokenCount;
      iterTokens += tokenCount;
      context['${childStep.id}[$iterIndex].tokenCount'] = tokenCount;
      if (!result.success) {
        _mergeStepResultIntoContext(
          iterContext,
          result,
          fallbackStatus: result.outcome == 'cancelled' ? 'cancelled' : 'failed',
        );
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
        if (result.outcome == 'cancelled') {
          final reason =
              result.outcomeReason ?? "Foreach child step '${childStep.id}' was interrupted and can be resumed.";
          // Outcome 'cancelled' means run-teardown interruption – synthesized
          // by a nested loop or resolved from a direct child's cancelled task.
          // A nested loop's retained checkpoint is the single budget source
          // while interrupted, so dropping the per-child token key keeps
          // workflow_budget_monitor's never-overlap invariant. A non-loop
          // child (no checkpoint) keeps its token key.
          if (childStep.taskType == WorkflowTaskType.loop) {
            context.remove('${childStep.id}[$iterIndex].tokenCount');
          }
          // The run pause is deferred to the controller so in-flight siblings
          // settle on their own paths instead of having their task waits
          // aborted into spurious hard failures.
          mapCtx.aborted = true;
          mapCtx.abortReason ??= reason;
          await persistProgress();
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
              outcome: result.outcome,
              reason: reason,
              tokenCount: tokenCount,
              timestamp: DateTime.now(),
              displayScope: _mapItemDisplayScope(mapContext),
            ),
          );
          return;
        }
        // A `needsInput` child is a recoverable hold (blocked), distinct from a
        // hard failure. Record it so it stays retryable; the controller decides
        // whether an open dependent forces a run-level pause.
        final isBlocked = result.outcome == 'needsInput';
        if (isBlocked) {
          final reason = result.outcomeReason ?? "Foreach child step '${childStep.id}' requires input";
          _clearCompletedForeachSubStepIds(context, controllerStep.id, iterIndex);
          mapCtx.recordBlocked(
            iterIndex,
            'blocked: $reason',
            result.task?.id,
            requiresDependencyHold: result.requiresDependencyHold,
          );
          await persistProgress();
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
              outcome: result.outcome,
              reason: reason,
              tokenCount: tokenCount,
              timestamp: DateTime.now(),
              displayScope: _mapItemDisplayScope(mapContext),
            ),
          );
          _eventBus.fire(
            MapIterationCompletedEvent(
              runId: run.id,
              stepId: controllerStep.id,
              iterationIndex: iterIndex,
              totalIterations: mapCtx.collection.length,
              itemId: mapCtx.itemId(iterIndex),
              taskId: result.task?.id ?? '',
              success: false,
              outcome: result.outcome,
              reason: reason,
              tokenCount: tokenCount,
              timestamp: DateTime.now(),
            ),
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
            outcome: result.outcome,
            reason: result.outcomeReason,
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
      final projectIdValue = projectId;
      final integrationBranchValue = integrationBranch;

      if (promote == null) {
        await failAndReturn('promotion failed: host promotion callback is not configured', firstTaskId);
        return;
      }
      if (projectIdValue == null || projectIdValue.isEmpty) {
        await failAndReturn('promotion failed: foreach iteration has no project binding', firstTaskId);
        return;
      }
      if (storyBranch == null || storyBranch.isEmpty) {
        await failAndReturn('promotion failed: task worktree branch is unavailable', firstTaskId);
        return;
      }
      if (integrationBranchValue == null || integrationBranchValue.isEmpty) {
        await failAndReturn('promotion failed: integration branch is not initialized', firstTaskId);
        return;
      }
      var stopAfterPromotion = false;
      await (runPromotionSpan<void>(
        lockPromotionSpan: _turnAdapter?.runResolverAttemptUnderLock,
        projectId: projectIdValue,
        body: () async {
          final promotionResult = await callPromote(
            promote: promote,
            runId: run.id,
            projectId: projectIdValue,
            branch: storyBranch,
            integrationBranch: integrationBranchValue,
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
                  integrationBranch: integrationBranchValue,
                  promotionStrategy: promotionStrategy,
                  storyId: storyId,
                  firstTaskId: firstTaskId,
                  iterTokens: iterTokens,
                  initialConflictingFiles: conflictingFiles,
                  initialConflictDetails: details,
                  projectId: projectIdValue,
                  config: mergeResolveConfig,
                  controllerMaxParallel: controllerMaxParallel,
                  activeWorkspaceRoot: activeWorkspaceRoot,
                  onFirstTaskCreated: recordFirstTaskId,
                );
                if (resolveResult == null) {
                  await failAndReturn('merge-resolve failed', firstTaskId);
                  stopAfterPromotion = true;
                  return;
                }
                switch (resolveResult) {
                  case WorkflowGitPromotionSuccess(:final commitSha):
                    if (storyId != null && storyId.isNotEmpty) promotedIds.add(storyId);
                    context['${controllerStep.id}[$iterIndex].promotion'] = 'success';
                    context['${controllerStep.id}[$iterIndex].promotion_sha'] = commitSha;
                  case WorkflowGitPromotionSerializeRemaining():
                    // Outer loop detects the typed serialize state and lets siblings settle.
                    // Re-queue first so this iteration stays visible after it leaves
                    // `inFlight` (BPC: distinct concurrent exhausted iters).
                    requeueSerializeExhausted(iterIndex);
                    _clearCompletedForeachSubStepIds(context, controllerStep.id, iterIndex);
                    mapCtx.inFlightCount--;
                    stopAfterPromotion = true;
                    return;
                  case WorkflowGitPromotionConflict():
                  case WorkflowGitPromotionError():
                    final conflictMsg =
                        'promotion-conflict: ${conflictingFiles.isEmpty ? 'merge conflict' : conflictingFiles.join(', ')}';
                    context['${controllerStep.id}[$iterIndex].promotion'] = 'conflict';
                    context['${controllerStep.id}[$iterIndex].promotion_details'] = details;
                    await failAndReturn(conflictMsg, firstTaskId);
                    stopAfterPromotion = true;
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
                stopAfterPromotion = true;
                return;
              }
            case PromotionError(:final failureMessage):
              context['${controllerStep.id}[$iterIndex].promotion'] = 'failed';
              await failAndReturn(failureMessage, firstTaskId);
              stopAfterPromotion = true;
              return;
            case PromotionSerializeRemaining():
              // Direct promote() never returns this sentinel; only merge-resolve does.
              requeueSerializeExhausted(iterIndex);
              _clearCompletedForeachSubStepIds(context, controllerStep.id, iterIndex);
              mapCtx.inFlightCount--;
              stopAfterPromotion = true;
              return;
            case PromotionNotConfigured():
            case PromotionNoProjectBinding():
            case PromotionNoBranch():
            case PromotionNoIntegrationBranch():
              // These are handled above via explicit guard checks before callPromote.
              break;
          }
        },
      ));
      if (stopAfterPromotion) return;
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
    // Inverse flush order to map (context before run row) is intentional and
    // crash-recovery-safe: resume rehydrates from the same run cursor + context
    // snapshot regardless of which write lands first.
    await _persistContext(run.id, context);
    await _repository.update(updatedRun);
  }
}

/// Builds a pause reason when a still-open (pending) foreach item depends on an
/// item that settled blocked or hard-failed; returns null when no such hold exists.
///
/// Implements the dependency-aware pause: an open dependent of a blocked or
/// hard-failed prerequisite can force a human checkpoint rather than silently
/// cancelling. Promotion-conflict/-failure indices are excluded – those carry
/// their own resume-cursor recovery path and must not be collapsed into a pause.
String? _foreachDependencyHold(
  DependencyGraph depGraph,
  MapStepContext mapCtx,
  Iterable<int> pending, {
  bool includeFailures = true,
}) {
  bool isPromotionFailure(int index) {
    final slot = mapCtx.results[index];
    final message = slot is Map ? slot['message'] as String? : null;
    if (message == null) return false;
    return message.startsWith('promotion-conflict') || message.startsWith('promotion failed:');
  }

  bool blockedRequiresDependencyHold(int index) {
    if (includeFailures) return true;
    final slot = mapCtx.results[index];
    return slot is Map && slot[MapStepContext.requiresDependencyHoldKey] == true;
  }

  final settledIds = <String>{};
  final candidateIndices = {
    for (final index in mapCtx.blockedIndices)
      if (blockedRequiresDependencyHold(index)) index,
    if (includeFailures) ...mapCtx.failedIndices,
  };
  for (final index in candidateIndices) {
    if (mapCtx.failedIndices.contains(index) && isPromotionFailure(index)) continue;
    final id = depGraph.idAt(index);
    if (id != null) settledIds.add(id);
  }
  if (settledIds.isEmpty) return null;
  for (final dependentIndex in pending) {
    for (final blockerId in settledIds) {
      if (!depGraph.dependentIndicesOf(blockerId).contains(dependentIndex)) continue;
      final dependentId = depGraph.idAt(dependentIndex) ?? 'item #$dependentIndex';
      final blockerIndex = depGraph.indexOfId(blockerId);
      final state = blockerIndex != null && mapCtx.blockedIndices.contains(blockerIndex) ? 'blocked' : 'failed';
      final blockerDetail = blockerIndex == null ? null : _foreachBlockerDetail(mapCtx.results[blockerIndex]);
      // Resume guidance must match restore semantics: a blocked item stays
      // pending (resume re-runs it); a failed item is restored as settled and
      // is never re-dispatched, so resume would re-pause on the same hold.
      final resumeGuidance = state == 'blocked'
          ? 'On resume the blocked story re-runs its full pipeline from scratch in a fresh worktree – '
                'land manual fixes on the integration branch or in the spec, not on the abandoned story branch.'
          : 'Resume does not re-run a failed story – cancel this run and start a fresh one after resolving '
                'the failure.';
      return "Story '$blockerId' settled $state; dependent story '$dependentId' cannot proceed. "
          "${blockerDetail == null ? '' : 'Blocker detail (step-reported): $blockerDetail. '}"
          '$resumeGuidance';
    }
  }
  return null;
}

/// Builds a pause reason when a foreach item settled blocked carrying the
/// escalation marker (`MapStepContext.requiresDependencyHoldKey`, written by a
/// nested loop exhausting under `onMaxIterations: escalate`); returns null when
/// no escalation-marked blocked item exists.
///
/// Unlike [_foreachDependencyHold] this does not require an open dependent: an
/// escalated exhaustion is an explicit "a human must look" signal, so a leaf or
/// single-story plan holds for review rather than shipping the residual in the
/// settle digest only. Resume re-runs the still-pending blocked story from
/// scratch, matching the blocked-story dependency-hold guidance.
String? _foreachEscalatedHold(MapStepContext mapCtx) {
  final markedIndices = [
    for (final index in mapCtx.blockedIndices.toList()..sort())
      if (mapCtx.results[index] case final Map<dynamic, dynamic> slot
          when slot[MapStepContext.requiresDependencyHoldKey] == true)
        index,
  ];
  if (markedIndices.isEmpty) return null;
  final storyIds = [for (final index in markedIndices) mapCtx.itemId(index) ?? 'item #$index'];
  // First blocker's step-reported detail; a parallel plan can escalate several
  // leaves at once, so the id list names them all while one detail keeps the
  // reason bounded.
  final blockerDetail = _foreachBlockerDetail(mapCtx.results[markedIndices.first]);
  final subject = storyIds.length == 1
      ? "Story '${storyIds.single}'"
      : "Stories ${storyIds.map((id) => "'$id'").join(', ')}";
  final verb = storyIds.length == 1 ? 'story re-runs its' : 'stories re-run their';
  return '$subject settled blocked after escalated remediation exhaustion; run paused for review. '
      "${blockerDetail == null ? '' : 'Blocker detail (step-reported): $blockerDetail. '}"
      'On resume the blocked $verb full pipeline from scratch in a fresh worktree – '
      'land manual fixes on the integration branch or in the spec, not on the abandoned story branch.';
}

String? _foreachBlockerDetail(dynamic resultSlot) {
  if (resultSlot is! Map) return null;
  final message = resultSlot['message'];
  if (message is! String) return null;
  final trimmed = message.trim();
  if (trimmed.isEmpty) return null;
  final detail = trimmed.startsWith('blocked: ') ? trimmed.substring('blocked: '.length) : trimmed;
  return _sanitizeAgentReportedText(detail);
}

/// Flattens and bounds agent-reported text before embedding it in an
/// operator-facing reason: ANSI/CSI escape sequences are removed, whitespace
/// collapses to single spaces, any remaining control characters – including
/// the C1 range (U+0080–U+009F, single-code-point CSI/OSC introducers some
/// terminals honor) – are stripped, and the value is truncated. Agent output
/// is untrusted; the surrounding engine-built sentence must stay
/// authoritative.
String _sanitizeAgentReportedText(String value, {int maxLength = 300}) {
  final flattened = value
      .replaceAll(RegExp(r'\x1B\[[0-9;]*[A-Za-z]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'[\x00-\x1F\x7F-\x9F]'), '')
      .trim();
  if (flattened.length <= maxLength) return flattened;
  return '${flattened.substring(0, maxLength)}…';
}

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

bool _isForeachSubStepContextMetadataKey(String key) =>
    key == 'status' || key == 'tokenCount' || key == 'sessionId' || key == 'providerSessionId';

bool _isForeachSubStepMetadataKey(String key) =>
    _isForeachSubStepContextMetadataKey(key) || key.endsWith('.providerSessionId');

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
