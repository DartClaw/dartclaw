part of 'workflow_executor.dart';

/// Uniform runner signature for direct map nodes.
Future<StepOutcome> mapRun(MapNode node, StepExecutionContext ctx) async =>
    _stepOutcomeFromHandoff(node, ctx, await dispatchStep(node, ctx));

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
  Future<String?> _readCodingDiff(Task task) async {
    try {
      final artifacts = await _taskService.listArtifacts(task.id);
      for (final artifact in artifacts) {
        if (artifact.path.endsWith('diff.json')) {
          final file = File(
            p.isAbsolute(artifact.path)
                ? artifact.path
                : p.join(_dataDir, 'tasks', task.id, 'artifacts', artifact.path),
          );
          if (!file.existsSync()) return null;
          final raw = await file.readAsString();
          try {
            final json = jsonDecode(raw) as Map<String, dynamic>;
            final files = (json['files'] as int?) ?? 0;
            final additions = (json['additions'] as int?) ?? 0;
            final deletions = (json['deletions'] as int?) ?? 0;
            return '$files files changed, +$additions -$deletions';
          } catch (_) {
            return raw;
          }
        }
      }
    } catch (_) {}
    return null;
  }

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
  }) async {
    // 1. Resolve collection from context.
    final rawCollection = context[step.mapOver!];
    if (rawCollection == null) {
      return MapStepResult(
        results: const [],
        totalTokens: 0,
        success: false,
        error: "Map step '${step.id}': context key '${step.mapOver}' is null or missing",
      );
    }
    // Auto-unwrap: if the value is a Map with a single key whose value is a
    // List, use that List (LLM output normalization).
    final resolvedCollection = switch (rawCollection) {
      final List<dynamic> list => list,
      final Map<String, dynamic> map when map.length == 1 && map.values.first is List => () {
        WorkflowExecutor._log.info(
          'Map step \'${step.id}\': auto-unwrapped Map key \'${map.keys.first}\' '
          'to List (${(map.values.first as List).length} items)',
        );
        return map.values.first as List<dynamic>;
      }(),
      final Map<Object?, Object?> map when map.length == 1 && map.values.first is List => () {
        final normalized = map.map((key, value) => MapEntry(key.toString(), value));
        WorkflowExecutor._log.info(
          'Map step \'${step.id}\': auto-unwrapped Map key \'${normalized.keys.first}\' '
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
            "Map step '${step.id}': context key '${step.mapOver}' is not a List "
            '(got ${rawCollection.runtimeType})',
      );
    }
    final collection = resolvedCollection;

    // 2. Check maxItems.
    if (collection.length > step.maxItems) {
      return MapStepResult(
        results: const [],
        totalTokens: 0,
        success: false,
        error:
            "Map step '${step.id}': collection has ${collection.length} items "
            'which exceeds maxItems (${step.maxItems}). '
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
        "Workflow '${run.id}': map step '${step.id}' has empty collection — "
        'succeeding with empty result array',
      );
      return const MapStepResult(results: [], totalTokens: 0, success: true);
    }

    // 5. Validate dependencies (detect cycles before any dispatch).
    final depGraph = DependencyGraph(collection);
    final strategy = definition.gitStrategy;
    final resolvedWorktreeMode = strategy?.effectiveWorktreeMode(maxParallel: maxParallel, isMap: true) ?? 'inline';
    final promotionStrategy = _effectivePromotion(strategy, resolvedWorktreeMode: resolvedWorktreeMode);
    final promotionAware = _isPromotionAwareScope(
      strategy,
      resolvedWorktreeMode: resolvedWorktreeMode,
      hasCodingSteps: _stepTouchesProjectBranch(definition, step),
    );
    final integrationBranch = (context['_workflow.git.integration_branch'] as String?)?.trim();
    final promotedIds = (context['_map.${step.id}.promotedIds'] as List?)?.whereType<String>().toSet() ?? <String>{};
    if (depGraph.hasDependencies) {
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
      if (promotionAware) {
        final unknownDeps = depGraph.unknownDependencyIds().toList()..sort();
        if (unknownDeps.isNotEmpty) {
          return MapStepResult(
            results: const [],
            totalTokens: 0,
            success: false,
            error: "Map step '${step.id}': unknown dependency IDs: ${unknownDeps.join(', ')}",
          );
        }
      }
    }

    // 6. Create MapStepContext.
    final mapCtx = MapStepContext(collection: collection, maxParallel: maxParallel, maxItems: step.maxItems);
    final completedIds = <String>{};
    _restoreMapProgress(mapCtx, completedIds, resumeCursor, collectionLength: collection.length);

    // 7. Persist map tracking state.
    await _persistMapProgress(run, step, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);

    // 8. Resolve step config once for all iterations.
    final resolved = resolveStepConfig(step, definition.stepDefaults, roleDefaults: _roleDefaults);

    // 9. Bounded concurrency dispatch loop.
    //    inFlight: index → Future that settles when the iteration completes/fails.
    //    pending: FIFO queue of indices yet to dispatch.
    //    completedIds: set of item IDs that have finished (for dep tracking).
    final inFlight = <int, Future<void>>{};
    final settledIndices = mapCtx.completedIndices;
    final pending = Queue<int>.from(
      List.generate(collection.length, (i) => i).where((i) => !settledIndices.contains(i)),
    );
    var totalTokens = 0;

    while (pending.isNotEmpty || inFlight.isNotEmpty) {
      // Check budget before dispatching more items.
      if (mapCtx.budgetExhausted) {
        // Cancel all remaining pending items.
        while (pending.isNotEmpty) {
          final cancelIdx = pending.removeFirst();
          mapCtx.recordCancelled(cancelIdx, 'Cancelled: budget exhausted');
        }
        await _persistMapProgress(run, step, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
        break;
      }

      // Dispatch eligible items up to the concurrency cap.
      final poolAvailable = _turnAdapter?.availableRunnerCount?.call();
      final concurrencyCap = mapCtx.effectiveConcurrency(poolAvailable);
      while (inFlight.length < concurrencyCap && pending.isNotEmpty) {
        // Find the next dependency-eligible index from the pending queue.
        int? nextIndex;
        if (depGraph.hasDependencies) {
          final ready = depGraph.getReady(promotionAware ? promotedIds : completedIds);
          // Find first pending index that is in the ready set.
          for (final idx in pending) {
            if (ready.contains(idx)) {
              nextIndex = idx;
              break;
            }
          }
        } else {
          nextIndex = pending.first;
        }
        if (nextIndex == null) break; // All remaining blocked on deps.
        pending.remove(nextIndex);

        final iterIndex = nextIndex;
        final mapContext = MapContext(
          item: (collection[iterIndex] as Object?) ?? '',
          index: iterIndex,
          length: collection.length,
          alias: step.mapAlias,
        );
        final effectiveProjectId = _resolveProjectIdWithMap(definition, step, context, mapContext, resolved: resolved);

        // Resolve per-iteration prompt (resolveWithMap handles {{map.*}}).
        final rawPrompt = step.prompt;
        final resolvedPrompt = rawPrompt != null
            ? _templateEngine.resolveWithMap(rawPrompt, context, mapContext)
            : null;
        final contextSummary = step.skill != null && resolvedPrompt == null
            ? SkillPromptBuilder.formatContextSummary({
                for (final key in step.contextInputs) key: context[key] ?? '',
              }, outputConfigs: _inputConfigsFor(definition, step.contextInputs))
            : null;
        final effectiveOutputs = _effectiveOutputsFor(step);
        final skillDefaultPrompt = _skillDefaultPromptFor(step);
        final resolvedInputValues = _resolvedInputValuesFor(step, definition, context);
        final variableNames = _autoFrameVariableNames(step);
        final iterPrompt = _skillPromptBuilder.build(
          skill: step.skill,
          resolvedPrompt: resolvedPrompt,
          contextSummary: contextSummary,
          outputs: effectiveOutputs,
          contextOutputs: step.contextOutputs,
          skillDefaultPrompt: skillDefaultPrompt,
          autoFrameContext: step.autoFrameContext,
          contextInputs: step.contextInputs,
          variables: variableNames,
          resolvedInputValues: resolvedInputValues,
          templatePrompt: rawPrompt,
          provider: resolved.provider,
        );
        final taskConfig = _buildStepConfig(
          run,
          definition,
          step,
          resolved,
          context,
          resolvedWorktreeMode: resolvedWorktreeMode,
          effectivePromotion: promotionStrategy,
        );
        final iterTitle = '${definition.name} — ${step.name} (${iterIndex + 1}/${collection.length})';

        // Dispatch: create the task and await its completion in a detached future.
        // Increment inFlight count synchronously before awaiting to prevent races.
        mapCtx.inFlightCount++;

        inFlight[iterIndex] =
            _dispatchIteration(
              run: run,
              definition: definition,
              step: step,
              stepIndex: stepIndex,
              iterIndex: iterIndex,
              iterPrompt: iterPrompt,
              iterTitle: iterTitle,
              taskConfig: taskConfig,
              projectId: effectiveProjectId,
              resolved: resolved,
              mapCtx: mapCtx,
              context: context,
              promotionAware: promotionAware,
              integrationBranch: integrationBranch,
              promotionStrategy: promotionStrategy,
              promotedIds: promotedIds,
            ).then((_) {
              inFlight.remove(iterIndex);
              final itemId = mapCtx.itemId(iterIndex);
              if (itemId != null) completedIds.add(itemId);
            });
      }

      // If nothing dispatched and nothing in-flight but items remain — deadlock.
      if (inFlight.isEmpty && pending.isNotEmpty) {
        WorkflowExecutor._log.warning(
          "Workflow '${run.id}': map step '${step.id}' — "
          '${pending.length} items blocked by unsatisfiable dependencies (deadlock guard).',
        );
        while (pending.isNotEmpty) {
          mapCtx.recordCancelled(pending.removeFirst(), 'Cancelled: dependency deadlock');
        }
        await _persistMapProgress(run, step, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
        break;
      }

      if (inFlight.isEmpty) break;

      // Wait for any one in-flight iteration to complete.
      await Future.any(inFlight.values);

      // Budget check after each completion.
      final refreshedRun = await _repository.getById(run.id) ?? run;
      run = refreshedRun;
      if (_workflowBudgetExceeded(run, definition)) {
        mapCtx.budgetExhausted = true;
      }

      // Yield to event loop to prevent microtask starvation.
      await Future<void>.delayed(Duration.zero);
    }

    // 10. Wait for all remaining in-flight to settle.
    if (inFlight.isNotEmpty) {
      await Future.wait(inFlight.values, eagerError: false);
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

  void _restoreMapProgress(
    MapStepContext mapCtx,
    Set<String> completedIds,
    WorkflowExecutionCursor? cursor, {
    required int collectionLength,
  }) {
    if (cursor == null || cursor.nodeType != WorkflowExecutionCursorNodeType.map) return;

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
          // Leave this iteration unsettled so resume can re-attempt promotion.
          continue;
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
        for (final e in refreshedRun.contextJson.entries)
          if (e.key.startsWith('_') && !e.key.startsWith('_map.current')) e.key: e.value,
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

    await _repository.update(updatedRun);
  }

  String _restoredMapFailureMessage(dynamic slotValue) =>
      slotValue is Map && slotValue['message'] is String ? slotValue['message'] as String : 'Failed before restart';

  String _restoredMapCancellationMessage(dynamic slotValue) =>
      slotValue is Map && slotValue['message'] is String ? slotValue['message'] as String : 'Cancelled before restart';

  String? _restoredMapTaskId(dynamic slotValue) =>
      slotValue is Map && slotValue['task_id'] is String ? slotValue['task_id'] as String : null;
}
