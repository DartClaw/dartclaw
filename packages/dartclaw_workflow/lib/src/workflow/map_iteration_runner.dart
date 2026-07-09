part of 'workflow_executor.dart';

/// Runs direct map and foreach iteration nodes.
extension WorkflowExecutorMapIterationRunner on WorkflowExecutor {
  // ── Map step execution ─────────────────────────────────────────────────────

  /// Resolves the `maxParallel` field from `step.maxParallel` at runtime.
  ///
  /// - `null` → default 1 (sequential)
  /// - `int` → use directly
  /// - `"unlimited"` → `null` (no cap)
  /// - template string (e.g. `"{{MAX_PARALLEL}}"`) → resolve via [context] then parse
  ///
  /// Throws [ArgumentError] if the resolved value cannot be parsed as an integer.
  int? _resolveMaxParallel(Object? raw, WorkflowContext context, String stepId) =>
      step_config_policy.resolveMaxParallel(raw, context, stepId, templateEngine: _templateEngine);

  /// Builds a structured coding task result from a completed [task].
  ///
  /// Returns a Map with `text`, `task_id`, `diff`, and `worktree` fields.
  /// `diff` and `worktree` may be null if not available.
  Future<Map<String, Object?>> _buildCodingResult(Task task, Map<String, Object?> outputs) async {
    final text = outputs.values.whereType<String>().firstOrNull ?? '';
    final diff = await _readCodingDiff(task);
    final worktree = _readWorktreePath(task);
    return {'text': text, 'task_id': task.id, 'diff': diff, 'worktree': worktree};
  }

  /// Reads the diff summary from the task's `diff.json` artifact, if present.
  Future<String?> _readCodingDiff(Task task) => readDiffArtifactSummary(_taskService, _dataDir, task);

  /// Extracts the worktree path from a task's `worktreeJson`, if available.
  String? _readWorktreePath(Task task) {
    final wj = task.worktreeJson;
    if (wj == null) return null;
    return wj['path'] as String?;
  }

  /// Executes a map/fan-out step.
  ///
  /// Resolves the collection from context, validates size, dispatches per-item
  /// tasks with bounded concurrency (respecting `maxParallel` and dependency
  /// ordering), collects index-ordered results, and fires progress events.
  ///
  /// Returns `null` if the executor has already paused the run (task creation
  /// failure). Returns a [MapStepResult] on success or failure.
  Future<MapStepResult?> _executeMapStep(
    WorkflowRun run,
    WorkflowDefinition definition,
    WorkflowStep step,
    WorkflowContext context, {
    required int stepIndex,
    WorkflowExecutionCursor? resumeCursor,
    required String? activeWorkspaceRoot,
    bool Function()? isCancelled,
  }) async {
    // 1. Resolve collection from context (shared with the foreach controller).
    final resolvedCollection = resolveIterationCollection(
      context[step.mapOver!],
      stepKind: 'Map',
      stepId: step.id,
      mapOverKey: step.mapOver!,
    );
    if (resolvedCollection.error != null) {
      return MapStepResult(results: const [], totalTokens: 0, success: false, error: resolvedCollection.error);
    }
    final collection = resolvedCollection.collection!;
    final maxItems = step.maxItems;

    // 2. Check maxItems.
    if (maxItems != null && collection.length > maxItems) {
      return MapStepResult(
        results: const [],
        totalTokens: 0,
        success: false,
        error:
            "Map step '${step.id}': collection has ${collection.length} items "
            'which exceeds maxItems ($maxItems). '
            'Consider decomposing into smaller batches.',
      );
    }

    // 3. Resolve maxParallel.
    final int? maxParallel;
    try {
      maxParallel = _resolveMaxParallel(step.maxParallel, context, step.id);
    } on ArgumentError catch (e) {
      return MapStepResult(results: const [], totalTokens: 0, success: false, error: e.message.toString());
    }

    // 4. Empty collection → succeed immediately.
    if (collection.isEmpty) {
      WorkflowExecutor._log.warning(
        "Workflow '${run.id}': map step '${step.id}' has empty collection – "
        'succeeding with empty result array',
      );
      return const MapStepResult(results: [], totalTokens: 0, success: true);
    }

    // 5. Validate dependencies (detect cycles before any dispatch).
    final depGraph = DependencyGraph(collection);
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
      hasCodingSteps: _stepTouchesProjectBranch(definition, step),
    );
    final integrationBranch = (context['_workflow.git.integration_branch'] as String?)?.trim();
    final promotedIds = (context['_map.${step.id}.promotedIds'] as List?)?.whereType<String>().toSet() ?? <String>{};
    if (depGraph.isDependencyAware) {
      try {
        depGraph.validate();
      } on ArgumentError catch (e) {
        return MapStepResult(
          results: const [],
          totalTokens: 0,
          success: false,
          error: "Map step '${step.id}': ${e.message}",
        );
      }
    }

    // 6. Create MapStepContext.
    //    An inline worktree shares the operator's live checkout, so iterations
    //    must run one at a time regardless of maxParallel — concurrent items
    //    would clobber the shared tree. Keyed on the resolved mode (which now
    //    treats a null strategy as `auto`, so a parallel map resolves to
    //    `per-map-item` and keeps its fan-out on isolated worktrees); only a
    //    genuine inline scope (authored `worktree: inline` or `--inline`)
    //    serializes here, matching the dispatcher's worktree-provisioning gate.
    final effectiveMaxParallel = resolvedWorktreeMode == 'inline' ? 1 : maxParallel;
    final mapCtx = MapStepContext(collection: collection, maxParallel: effectiveMaxParallel, maxItems: maxItems);
    final completedIds = <String>{};
    restoreIterationProgress(
      mapCtx,
      completedIds,
      resumeCursor,
      nodeType: WorkflowExecutionCursorNodeType.map,
      collectionLength: collection.length,
    );

    // 7. Persist map tracking state.
    await _persistMapProgress(run, step, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);

    // 8. Resolve step config once for all iterations.
    final resolved = resolveStepConfig(step, definition.stepDefaults, roleDefaults: _roleDefaults);

    // Finalizer wiring is per-step, not per-iteration: a map child that is a
    // workflow-owned agent step with model-derived declared outputs finalizes
    // through the structured envelope, exactly like a foreach child dispatched
    // via step_dispatcher. Without this the child falls back to the legacy
    // inline path with none of the envelope's re-ask/hard-fail robustness.
    final mapNeedsFinalizer = stepNeedsFinalizer(step, step.outputs);
    final mapFinalizerCoveredKeys = mapNeedsFinalizer
        ? modelDerivedFinalizerKeys(step, step.outputs)
        : const <String>[];
    final mapStructuredSchema = mapNeedsFinalizer
        ? buildExecutionEnvelopeSchema(
            step,
            step.outputs,
            gatingSeverity: resolved.gatingSeverity ?? defaultGatingSeverity,
          )
        : null;

    // 9. Bounded concurrency dispatch loop.
    //    inFlight: index → Future that settles when the iteration completes/fails.
    //    pending: FIFO queue of indices yet to dispatch.
    //    completedIds: set of item IDs that have finished (for dep tracking).
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

    while (engine.hasWork()) {
      // Check budget before dispatching more items.
      if (mapCtx.budgetExhausted) {
        // Cancel all remaining pending items.
        engine.cancelPending('Cancelled: budget exhausted');
        await _persistMapProgress(run, step, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
        break;
      }

      // Run left `running` (pause/cancel) while an item awaited its task: stop
      // dispatching siblings. In-flight items settle below; the step returns null.
      if (mapCtx.aborted) break;

      // Dispatch eligible items up to the concurrency cap.
      final poolAvailable = _turnAdapter?.availableRunnerCount?.call();
      while (engine.canDispatch(poolAvailable: poolAvailable)) {
        if ((isCancelled?.call() ?? false) || mapCtx.aborted) break;
        // Find the next dependency-eligible index from the pending queue.
        final nextIndex = engine.takeNextReadyIndex();
        if (nextIndex == null) break; // All remaining blocked on deps.

        final iterIndex = nextIndex;
        final mapContext = MapContext(
          item: (collection[iterIndex] as Object?) ?? '',
          index: iterIndex,
          length: collection.length,
          alias: step.mapAlias,
        );
        // Resolve per-iteration prompt (resolveWithMap handles {{map.*}}).
        final rawPrompt = step.prompt;
        final resolvedPrompt = rawPrompt != null
            ? _templateEngine.resolveWithMap(rawPrompt, context, mapContext)
            : null;
        final contextSummary = step.skill != null && resolvedPrompt == null
            ? SkillPromptBuilder.formatContextSummary({
                for (final key in step.inputs) key: context[key] ?? '',
              }, outputConfigs: _inputConfigsFor(definition, step.inputs))
            : null;
        final effectiveOutputs = step.outputs;
        final effectiveOutputKeys = effectiveOutputKeysFor(step, effectiveOutputs);
        final effectiveProjectId = _resolveProjectIdWithMap(
          definition,
          step,
          context,
          mapContext,
          resolved: resolved,
          effectiveOutputs: effectiveOutputs,
        );
        final resolvedInputValues = _resolvedInputValuesFor(step, definition, context);
        final variableNames = _autoFrameVariableNames(step);
        final taskProvider = resolved.provider ?? _skillPreflightConfig.defaultProvider;
        final visibleSkill = step.skill == null
            ? null
            : _skillPreflightResult.visibleSkillFor(provider: taskProvider, skill: step.skill!);
        final iterPrompt = _skillPromptBuilder.build(
          skill: visibleSkill,
          resolvedPrompt: resolvedPrompt,
          contextSummary: contextSummary,
          outputs: effectiveOutputs,
          outputKeys: effectiveOutputKeys,
          outputExamples: step.outputExamples,
          finalizerCoveredKeys: mapFinalizerCoveredKeys,
          autoFrameContext: step.autoFrameContext,
          inputs: step.inputs,
          variables: variableNames,
          resolvedInputValues: resolvedInputValues,
          templatePrompt: rawPrompt,
          provider: taskProvider,
          gatingSeverity: resolved.gatingSeverity,
        );
        var taskConfig = _buildStepConfig(
          run,
          definition,
          step,
          resolved,
          context,
          resolvedWorktreeMode: resolvedWorktreeMode,
          effectivePromotion: promotionStrategy,
          effectiveOutputs: effectiveOutputs,
        );
        if (mapStructuredSchema != null) {
          taskConfig = {...taskConfig, '_workflowStructuredSchema': mapStructuredSchema};
        }
        final iterTitle = '${definition.name} – ${step.name} (${iterIndex + 1}/${collection.length})';

        // Dispatch: create the task and await its completion in a detached future.
        // Increment inFlight count synchronously before awaiting to prevent races.
        mapCtx.inFlightCount++;

        final iterationFuture = (() async {
          try {
            await _dispatchIteration(
              run: run,
              definition: definition,
              step: step,
              stepIndex: stepIndex,
              iterIndex: iterIndex,
              iterPrompt: iterPrompt,
              iterTitle: iterTitle,
              taskConfig: taskConfig,
              projectId: effectiveProjectId,
              provider: taskProvider,
              resolved: resolved,
              mapCtx: mapCtx,
              context: context,
              promotionAware: promotionAware,
              integrationBranch: integrationBranch,
              promotionStrategy: promotionStrategy,
              promotedIds: promotedIds,
            );
          } catch (e, st) {
            WorkflowExecutor._log.severe(
              "Workflow '${run.id}': map step '${step.id}' iteration $iterIndex failed unexpectedly: $e",
              e,
              st,
            );
            if (!mapCtx.completedIndices.contains(iterIndex)) {
              mapCtx.recordFailure(iterIndex, 'Unexpected iteration error: $e', null);
              await _persistMapProgress(run, step, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
              _eventBus.fire(
                MapIterationCompletedEvent(
                  runId: run.id,
                  stepId: step.id,
                  iterationIndex: iterIndex,
                  totalIterations: mapCtx.collection.length,
                  itemId: mapCtx.itemId(iterIndex),
                  taskId: '',
                  success: false,
                  tokenCount: 0,
                  timestamp: DateTime.now(),
                ),
              );
            }
            // Controller-level invariant breach – abort remaining iterations
            // rather than silently re-dispatching against possibly-corrupt
            // state. See foreach_iteration_runner for the same rationale.
            mapCtx.budgetExhausted = true;
          }
        })().catchError((_) {});
        engine.track(
          iterIndex,
          iterationFuture,
          onSettled: (iterIndex) {
            final itemId = mapCtx.itemId(iterIndex);
            if (itemId != null) completedIds.add(itemId);
          },
        );
      }

      // If nothing dispatched and nothing in-flight but items remain – deadlock.
      if (engine.isDispatchStalled) {
        if (promotionAware && depGraph.hasDependencies && mapCtx.failedIndices.isNotEmpty) {
          WorkflowExecutor._log.warning(
            "Workflow '${run.id}': map step '${step.id}' – "
            '${engine.pending.length} items remain blocked on unresolved promoted dependencies; leaving them pending for resume.',
          );
          break;
        }
        WorkflowExecutor._log.warning(
          "Workflow '${run.id}': map step '${step.id}' – "
          '${engine.pending.length} items blocked by unsatisfiable dependencies (deadlock guard).',
        );
        engine.cancelPending('Cancelled: dependency deadlock');
        await _persistMapProgress(run, step, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
        break;
      }

      if (!engine.hasInFlight) break;

      await engine.waitForWake();

      // Budget check after each completion.
      final refreshedRun = await _repository.getById(run.id) ?? run;
      run = refreshedRun;
      // Map-iteration tokens reach run.totalTokens only at map completion, so the
      // mid-map check (and the 80% warning) adds them back as an evaluation-only
      // basis from the persisted per-iteration `<stepId>[i].tokenCount` keys, so
      // settled and sibling in-flight iterations count against maxTokens.
      final mapConsumedTokens = workflow_budget_monitor.foreachScopeConsumedTokens(
        context.data,
        foreachStepId: step.id,
        childStepIds: [step.id],
      );
      run = await _checkWorkflowBudgetWarning(run, definition, additionalTokens: mapConsumedTokens);
      if (_workflowBudgetExceeded(run, definition, additionalTokens: mapConsumedTokens)) {
        mapCtx.budgetExhausted = true;
      }
    }

    // 10. Wait for all remaining in-flight to settle.
    if (engine.hasInFlight) {
      await Future.wait(engine.inFlight.values, eagerError: false);
    }

    // Aborted mid-step: either the run left `running` (pause/cancel) or a
    // teardown-cancelled item flagged the abort while the run was still
    // running. Persist progress for resume and return null so the executor
    // exits without marking the run completed. The deferred _pauseRun covers
    // the cancelled-while-running ordering and no-ops when the run already
    // left `running` (mirroring the foreach controller's deferred pause).
    if (mapCtx.aborted) {
      WorkflowExecutor._log.info("Workflow '${run.id}': map step '${step.id}' aborted before settling all items");
      await _persistMapProgress(run, step, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
      await _pauseRun(run, mapCtx.abortReason ?? "Map step '${step.id}' was interrupted and can be resumed.");
      return null;
    }

    // Accumulate total tokens from context metadata keys.
    for (var i = 0; i < collection.length; i++) {
      final tokenKey = '${step.id}[$i].tokenCount';
      final t = context[tokenKey];
      if (t is int) totalTokens += t;
    }

    // 11. Fire MapStepCompletedEvent.
    _eventBus.fire(
      MapStepCompletedEvent(
        runId: run.id,
        stepId: step.id,
        stepName: step.name,
        totalIterations: collection.length,
        successCount: mapCtx.successCount,
        failureCount: mapCtx.failedIndices.length,
        cancelledCount: mapCtx.cancelledCount,
        totalTokens: totalTokens,
        timestamp: DateTime.now(),
      ),
    );

    // 12. Return result.
    if (mapCtx.hasFailures) {
      final failCount = mapCtx.failedIndices.length;
      for (final index in mapCtx.failedIndices) {
        final slot = mapCtx.results[index];
        final message = slot is Map ? slot['message'] : slot;
        WorkflowExecutor._log.warning("Map step '${step.id}' iteration [$index] failed: $message");
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
            ? "promotion-conflict: map step '${step.id}' has unresolved promotion conflicts"
            : "Map step '${step.id}': $failCount iteration(s) failed",
      );
    }

    return MapStepResult(results: List<dynamic>.from(mapCtx.results), totalTokens: totalTokens, success: true);
  }

  Future<void> _persistMapProgress(
    WorkflowRun run,
    WorkflowStep step,
    WorkflowContext context,
    MapStepContext mapCtx, {
    required int stepIndex,
    Set<String> promotedIds = const <String>{},
  }) async {
    context['_map.${step.id}.promotedIds'] = promotedIds.toList()..sort();
    final refreshedRun = await _repository.getById(run.id) ?? run;
    final cursor = WorkflowExecutionCursor.map(
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
        ...privateContextEntries(refreshedRun.contextJson, exclude: '_map.current'),
        ...context.toJson(),
        '_map.current.stepId': step.id,
        '_map.current.total': mapCtx.collection.length,
        '_map.current.completedIndices': cursor.completedIndices,
        '_map.current.failedIndices': cursor.failedIndices,
        '_map.current.cancelledIndices': cursor.cancelledIndices,
        '_map.${step.id}.promotedIds': context['_map.${step.id}.promotedIds'],
      },
      updatedAt: DateTime.now(),
    );

    // Inverse flush order to foreach (run row before context) is intentional: both
    // persist the same cursor+context snapshot and resume rehydrates from the run
    // cursor plus persisted context, so neither order opens a crash-recovery window.
    await _repository.update(updatedRun);
    await _persistContext(run.id, context);
  }
}
