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
    void Function(String taskId)? onFirstTaskCreated,
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
          prompts: const [
            'Run dartclaw-merge-resolve to resolve any merge conflicts on this story branch against the '
                'integration branch, verify the result, and commit all-or-nothing.',
          ],
          emitsOwnOutcome: true,
          outputs: const {
            'merge_resolve.outcome': OutputConfig(
              format: OutputFormat.text,
              description:
                  "Outcome of the merge resolution attempt. Enum-typed string: must be one of 'resolved', 'failed', or 'cancelled'.",
            ),
            'merge_resolve.conflicted_files': OutputConfig(
              format: OutputFormat.json,
              description: 'JSON array of relative file paths that had conflict markers, sorted lexicographically.',
            ),
            'merge_resolve.resolution_summary': OutputConfig(
              format: OutputFormat.text,
              description:
                  'Prose summary of the resolution rationale and steps taken. Non-empty for all terminal outcomes.',
            ),
            'merge_resolve.error_message': OutputConfig(
              format: OutputFormat.text,
              description:
                  "Error or cancellation message. Null (emit the literal string 'null') when outcome is 'resolved'; a non-empty string for 'failed' or 'cancelled'.",
            ),
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
          onFirstTaskCreated: onFirstTaskCreated,
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
  /// `serializeRemaining` → persists the typed serialize state in `enacting`
  /// and returns the sentinel that makes the foreach controller settle siblings
  /// before entering serial mode.
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
        return WorkflowGitPromotionConflict(
          conflictingFiles: _escalationConflictFiles(lastAttempt, conflictingFiles),
          details: conflictDetails,
        );
      case MergeResolveEscalation.serializeRemaining:
        // Idempotent only while the first serialize-remaining transition is still
        // being enacted. Once terminal, a serial retry that still conflicts has
        // exhausted its retry path and must fail normally.
        final existingState = _SerializeRemainingState.read(context, stepId: controllerStep.id);
        if (existingState != null) {
          if (existingState.phase == _SerializeRemainingPhase.enacting) {
            return const WorkflowGitPromotionSerializeRemaining();
          }
          return WorkflowGitPromotionConflict(
            conflictingFiles: _escalationConflictFiles(lastAttempt, conflictingFiles),
            details: conflictDetails,
          );
        }
        // Mark 'enacting' before the foreach controller stops dispatching so
        // crash recovery resumes into the serial-settle path.
        _SerializeRemainingState(
          stepId: controllerStep.id,
          phase: _SerializeRemainingPhase.enacting,
          iterIndex: iterIndex,
          failedAttemptNumber: attemptCounter,
          eventEmitted: false,
          settleDeadlineIso: _newSerializeRemainingSettleDeadlineIso(_serializeRemainingSettleTimeout),
        ).writeTo(context);
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

  List<String> _escalationConflictFiles(MergeResolveAttemptArtifact? lastAttempt, List<String> fallback) =>
      lastAttempt?.conflictedFiles.isNotEmpty == true ? lastAttempt!.conflictedFiles : fallback;

  /// Stops new dispatch, lets in-flight siblings settle, then enters serial mode.
  ///
  /// Returns null on success. Returns an error message when siblings do not
  /// settle inside [_serializeRemainingSettleTimeout].
  Future<String?> _enactSerializeRemaining({
    required WorkflowRun run,
    required WorkflowStep controllerStep,
    required WorkflowContext context,
    required MapStepContext mapCtx,
    required Queue<int> pending,
    required Map<int, Future<void>> inFlight,
    required int failingIterIndex,
    required int stepIndex,
    required Set<String> promotedIds,
  }) async {
    var state =
        _SerializeRemainingState.read(context, stepId: controllerStep.id) ??
        _SerializeRemainingState(
          stepId: controllerStep.id,
          phase: _SerializeRemainingPhase.enacting,
          iterIndex: failingIterIndex,
          failedAttemptNumber: 0,
          eventEmitted: false,
          settleDeadlineIso: _newSerializeRemainingSettleDeadlineIso(_serializeRemainingSettleTimeout),
        );
    if (state.phase == _SerializeRemainingPhase.drained) return null;

    final shouldFireEvent = !state.eventEmitted;
    if (shouldFireEvent) {
      _eventBus.fire(
        WorkflowSerializationEnactedEvent(
          runId: run.id,
          foreachStepId: controllerStep.id,
          failingIterationIndex: failingIterIndex,
          failedAttemptNumber: state.failedAttemptNumber,
          timestamp: DateTime.now(),
        ),
      );
    }

    // Fire once per serialize transition, deduped via the typed state's eventEmitted flag.
    if (shouldFireEvent || state.settleDeadlineIso == null) {
      state = state.copyWith(
        eventEmitted: true,
        settleDeadlineIso:
            state.settleDeadlineIso ?? _newSerializeRemainingSettleDeadlineIso(_serializeRemainingSettleTimeout),
      );
      state.writeTo(context);
      await _persistForeachProgress(
        run,
        controllerStep,
        context,
        mapCtx,
        stepIndex: stepIndex,
        promotedIds: promotedIds,
      );
    }

    final oldPending = pending.toList();
    pending.clear();
    if (!mapCtx.completedIndices.contains(failingIterIndex) &&
        !mapCtx.failedIndices.contains(failingIterIndex) &&
        !mapCtx.cancelledIndices.contains(failingIterIndex) &&
        !mapCtx.blockedIndices.contains(failingIterIndex)) {
      pending.add(failingIterIndex);
    }
    for (final idx in oldPending) {
      if (idx != failingIterIndex &&
          !mapCtx.completedIndices.contains(idx) &&
          !mapCtx.failedIndices.contains(idx) &&
          !mapCtx.cancelledIndices.contains(idx) &&
          !mapCtx.blockedIndices.contains(idx)) {
        pending.add(idx);
      }
    }

    if (inFlight.isNotEmpty) {
      final remainingTimeout = _remainingSerializeRemainingSettleTimeout(state, _serializeRemainingSettleTimeout);
      if (remainingTimeout == Duration.zero) {
        return "serialize-remaining settle-timeout: foreach step '${controllerStep.id}' still had "
            '${inFlight.length} in-flight iteration(s) after ${_serializeRemainingSettleTimeout.inMilliseconds}ms';
      }
      try {
        await Future.any(inFlight.values.map((future) => future.catchError((_) {}))).timeout(remainingTimeout);
      } on TimeoutException {
        return "serialize-remaining settle-timeout: foreach step '${controllerStep.id}' still had "
            '${inFlight.length} in-flight iteration(s) after ${_serializeRemainingSettleTimeout.inMilliseconds}ms';
      }
      await _persistForeachProgress(
        run,
        controllerStep,
        context,
        mapCtx,
        stepIndex: stepIndex,
        promotedIds: promotedIds,
      );
      return null;
    }

    // Discard parallel-mode pre_attempt_sha for the serial retry.
    context.remove('_merge_resolve.${controllerStep.id}.$failingIterIndex.pre_attempt_sha');

    // Atomically advance to the terminal serial-attempt-consumed marker.
    state.copyWith(phase: _SerializeRemainingPhase.drained, eventEmitted: true).writeTo(context);
    WorkflowExecutor._log.info(
      "Workflow '${run.id}': serialize-remaining enacted for step '${controllerStep.id}'; "
      'failing iter $failingIterIndex placed at head for serial retry.',
    );
    await _persistForeachProgress(run, controllerStep, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
    return null;
  }
}
