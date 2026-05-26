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

extension WorkflowExecutorMergeResolveCoordinator on WorkflowExecutor {
  // ── Merge-resolve retry loop ────────────────────────────────────────────────

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
    required int? controllerMaxParallel,
    required String? activeWorkspaceRoot,
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
    // concurrent sibling promotion can mutate the integration branch mid-resolution.
    final lockWrapper = _turnAdapter?.runResolverAttemptUnderLock;
    Future<_ResolverAttemptDecision> runAttempt(Future<_ResolverAttemptDecision> Function() body) {
      if (lockWrapper == null) return body();
      return lockWrapper<_ResolverAttemptDecision>(projectId: projectId, body: body);
    }

    MergeResolveAttemptArtifact? lastAttempt;
    while (attemptCounter < config.maxAttempts) {
      final decision = await runAttempt(() async {
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

        // Build env-var map.
        final envMap = _buildMergeResolveEnv(config, integrationBranch, storyBranch);

        // Spawn the skill step.
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
          activeWorkspaceRoot: activeWorkspaceRoot,
          stepIndex: skillStepIndex,
          mapCtx: mapContext,
          enclosingMaxParallel: controllerMaxParallel,
          extraTaskConfig: {WorkflowTaskConfig.mergeResolveEnv: envMap},
        );
        final attemptElapsedMs = DateTime.now().difference(attemptStartedAt).inMilliseconds;

        // Advance counter immediately after invocation.
        attemptCounter++;
        context['$statePrefix.attempt_counter'] = attemptCounter;

        // Cancellation gets the canonical 'cancelled' outcome.
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

        // Persist artifact (idempotent on resume).
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

        // On resolved, retry promotion.
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

        // Post-attempt cleanup on non-resolved outcome.
        if (preAttemptSha.isNotEmpty) {
          final cleanupError = await _turnAdapter?.cleanupWorktreeForRetry?.call(
            projectId: projectId,
            branch: storyBranch,
            preAttemptSha: preAttemptSha,
          );
          if (cleanupError != null) {
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

    // Attempts exhausted — escalate.
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

  // ── Support helpers ─────────────────────────────────────────────────────────

  Future<String?> _capturePreAttemptSha({required String projectId, required String branch}) =>
      _turnAdapter?.captureWorkflowBranchSha?.call(projectId: projectId, branch: branch) ?? Future.value(null);

  Map<String, String> _buildMergeResolveEnv(MergeResolveConfig cfg, String integrationBranch, String storyBranch) {
    return <String, String>{
      'MERGE_RESOLVE_INTEGRATION_BRANCH': integrationBranch,
      'MERGE_RESOLVE_STORY_BRANCH': storyBranch,
      'MERGE_RESOLVE_TOKEN_CEILING': cfg.tokenCeiling.toString(),
    };
  }

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
    final artifactPath = p.join(workflowMergeResolveAttemptsDir(dataDir: _dataDir, runId: run.id), name);
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
    final repo = _taskRepository;
    if (repo != null) {
      final name = 'merge_resolve_iter_${iterIndex}_attempt_$attemptNumber.json';
      final existing = await repo.listArtifactsByTask(taskId);
      final existing_ = existing.where((a) => a.name == name).firstOrNull;
      if (existing_ != null) {
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

  /// Dispatch method for max-attempts exhaustion.
  ///
  /// `fail` → returns WorkflowGitPromotionConflict immediately.
  /// `serializeRemaining` → sets serialize_remaining_phase='enacting', stores attempt
  /// number for _drainAndRequeue, persists state, returns sentinel.
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
        // Idempotent — if already serial, return sentinel without re-firing event.
        if (context[phaseKey] != null) {
          return const WorkflowGitPromotionSerializeRemaining();
        }
        // Mark 'enacting' BEFORE issuing any cancel signals (crash safety).
        context[phaseKey] = 'enacting';
        context['_merge_resolve.${controllerStep.id}.serializing_iter_index'] = iterIndex;
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
  /// with [failingIterIndex] at head followed by drained siblings.
  ///
  /// Returns null on success. Returns an error message when a sibling is stuck —
  /// caller must abort the foreach with that message.
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
    if (context[phaseKey] == 'drained') return null;

    final siblingIndices = inFlight.keys.toList(growable: false);
    final drainedCount = siblingIndices.length;

    // Fire exactly one event per run (PRD US06 / FR4).
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
      await _persistForeachProgress(
        run,
        controllerStep,
        context,
        mapCtx,
        stepIndex: stepIndex,
        promotedIds: promotedIds,
      );
    }

    // Cancel all in-flight siblings.
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

    // Await all siblings in parallel with a single 30s cap.
    const drainTimeout = Duration(seconds: 30);
    final drainFutures = <({int idx, Future<void> future})>[
      for (final idx in siblingIndices)
        if (inFlight[idx] != null) (idx: idx, future: inFlight[idx]!.catchError((_) {})),
    ];
    if (drainFutures.isNotEmpty) {
      try {
        await Future.wait(drainFutures.map((e) => e.future)).timeout(drainTimeout);
      } on TimeoutException {
        final stuckIdx = drainFutures.firstWhere((e) => inFlight.containsKey(e.idx)).idx;
        final stuckTaskId = iterTaskIds[stuckIdx] ?? 'unknown';
        return 'serialize-remaining drain failed: task $stuckTaskId did not honor cancellation within timeout';
      }
    }

    // Discard parallel-mode pre_attempt_sha for all re-queued iterations.
    context.remove('_merge_resolve.${controllerStep.id}.$failingIterIndex.pre_attempt_sha');
    for (final idx in siblingIndices) {
      context.remove('_merge_resolve.${controllerStep.id}.$idx.pre_attempt_sha');
    }

    // Rebuild pending: failing iter at head, drained siblings after, remaining pending preserved.
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

    // Atomically advance phase to 'drained'.
    context[phaseKey] = 'drained';
    WorkflowExecutor._log.info(
      "Workflow '${run.id}': serialize-remaining enacted for step '${controllerStep.id}'; "
      'drained $drainedCount sibling(s), failing iter $failingIterIndex placed at head.',
    );
    await _persistForeachProgress(run, controllerStep, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
    return null;
  }
}
