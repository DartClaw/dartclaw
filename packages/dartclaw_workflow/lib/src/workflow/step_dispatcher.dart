part of 'workflow_executor.dart';

extension WorkflowExecutorStepDispatcher on WorkflowExecutor {
  /// Executes a single step: resolves template, creates task, waits for terminal state.
  ///
  Future<StepOutcome?> _executeStep(
    WorkflowRun run,
    WorkflowDefinition definition,
    WorkflowStep step,
    WorkflowContext context, {
    required int stepIndex,
    String? loopId,
    int? loopIteration,
    MapContext? mapCtx,
    int? enclosingMaxParallel,
    required String? activeWorkspaceRoot,
    bool promoteAfterSuccess = false,
    Map<String, dynamic>? extraTaskConfig,
    void Function(String taskId)? onFirstTaskCreated,
    _NestedLoopScope? nestedLoopScope,
  }) async {
    if (step.taskType == WorkflowTaskType.bash) {
      return _executeBashStep(run, step, context);
    }

    if (step.taskType == WorkflowTaskType.approval) {
      final paused = await _executeApprovalStep(run, step, context, stepIndex: stepIndex);
      if (paused) return null;
      return StepOutcome(
        step: step,
        outputs: {
          '${step.id}.status': 'accepted',
          '${step.id}.approval.status': 'approved',
          '${step.id}.tokenCount': 0,
        },
        tokenCount: 0,
        success: true,
        outcome: 'succeeded',
        outcomeReason: 'approval auto-resolved: ${step.id}',
      );
    }

    if (step.taskType == WorkflowTaskType.aggregateReviews) {
      return _executeAggregateStep(run, definition, step, context, activeWorkspaceRoot: activeWorkspaceRoot);
    }

    // A `loop`-type step is only reachable as a foreach child: the loop
    // controller runs against the per-iteration [context] (its iterContext).
    if (step.taskType == WorkflowTaskType.loop) {
      if (nestedLoopScope == null) {
        await _failRun(run, "Loop step '${step.id}' dispatched without a nested-loop scope");
        return null;
      }
      return _executeNestedLoopStep(
        run,
        definition,
        step,
        context,
        scope: nestedLoopScope,
        activeWorkspaceRoot: activeWorkspaceRoot,
      );
    }

    final resolved = resolveStepConfig(step, definition.stepDefaults, roleDefaults: _roleDefaults);
    final resolvedFirstPrompt = step.prompts != null
        ? _templateEngine.resolveWithMap(step.prompts!.first, context, mapCtx)
        : null;
    final contextSummary = step.skill != null && resolvedFirstPrompt == null
        ? SkillPromptBuilder.formatContextSummary({
            for (final key in step.inputs) key: context[key] ?? '',
          }, outputConfigs: _inputConfigsFor(definition, step.inputs))
        : null;
    final resolvedInputValues = _resolvedInputValuesFor(step, definition, context);
    final variableNames = _autoFrameVariableNames(step);
    final resolvedWorktreeMode = _resolvedWorktreeModeForScope(
      definition,
      step,
      context,
      enclosingMaxParallel: enclosingMaxParallel,
      enclosingMapScope: mapCtx != null,
    );
    final effectivePromotion = _effectivePromotion(definition.gitStrategy, resolvedWorktreeMode: resolvedWorktreeMode);
    final continuedRootStep = step.continueSession != null ? _resolveContinueSessionRootStep(definition, step) : null;
    final effectiveProvider = continuedRootStep != null
        ? _resolveContinueSessionProvider(definition, step, continuedRootStep, resolved)
        : resolved.provider;
    final taskProvider = effectiveProvider ?? resolved.provider ?? _skillPreflightConfig.defaultProvider;
    final visibleSkill = step.skill == null
        ? null
        : _skillPreflightResult.visibleSkillFor(provider: taskProvider, skill: step.skill!);
    final effectiveOutputs = step.outputs;
    final effectiveOutputKeys = effectiveOutputKeysFor(step, effectiveOutputs);
    var taskConfig = _buildStepConfig(
      run,
      definition,
      step,
      resolved,
      context,
      resolvedWorktreeMode: resolvedWorktreeMode,
      effectivePromotion: effectivePromotion,
      effectiveOutputs: effectiveOutputs,
    );
    final effectiveProjectId = mapCtx != null
        ? _resolveProjectIdWithMap(
            definition,
            continuedRootStep ?? step,
            context,
            mapCtx,
            resolved: resolved,
            effectiveOutputs: effectiveOutputs,
          )
        : _resolveProjectId(
            definition,
            continuedRootStep ?? step,
            context,
            resolved: resolved,
            effectiveOutputs: effectiveOutputs,
          );

    if (mapCtx != null) {
      final displayScope = _mapItemDisplayScope(mapCtx);
      taskConfig = {...taskConfig, '_mapIterationIndex': mapCtx.index, '_mapIterationTotal': mapCtx.length};
      if (displayScope != null) {
        taskConfig = {...taskConfig, 'displayScope': displayScope};
      }
      final requiredInputPath = _mapItemSpecPath(mapCtx);
      if (requiredInputPath != null) {
        taskConfig = {...taskConfig, 'requiredInputPath': requiredInputPath};
      }
      final mount = definition.gitStrategy?.externalArtifactMount;
      if (mount != null) {
        final resolvedSource = mount.source == null
            ? null
            : _templateEngine.resolveWithMap(mount.source!, context, mapCtx).trim();
        final fromProjectId = _templateEngine.resolve(mount.fromProject, context).trim();
        if (fromProjectId.isNotEmpty) {
          final fromProjectDir = p.join(_dataDir, 'projects', fromProjectId);
          final mountJson = <String, Object?>{
            'mode': mount.mode.toJson(),
            'fromProjectDir': fromProjectDir,
            if (resolvedSource != null && resolvedSource.isNotEmpty) 'source': resolvedSource,
            if (mount.fromPath != null) 'fromPath': mount.fromPath,
            if (mount.toPath != null) 'toPath': mount.toPath,
          };
          taskConfig = {...taskConfig, '_workflow.externalArtifactMount': mountJson};
        }
      }
    }

    if (continuedRootStep != null) {
      final prevSessionId = _resolveContinueSessionRootSessionId(definition, step, context);
      if (prevSessionId == null) {
        final msg =
            "Step '${step.id}' uses continueSession but no session ID found for root step "
            "'${continuedRootStep.id}'. Ensure the referenced step completed successfully first.";
        WorkflowExecutor._log.warning("Workflow '${run.id}': $msg");
        await _failRun(run, msg);
        return null;
      }
      final baselineTokens = await _readSessionTokens(prevSessionId);
      taskConfig = {...taskConfig, '_continueSessionId': prevSessionId, '_sessionBaselineTokens': baselineTokens};
      final prevProviderSessionId = _resolveContinueSessionRootProviderSessionId(definition, step, context);
      if (prevProviderSessionId != null && prevProviderSessionId.isNotEmpty) {
        taskConfig = {...taskConfig, '_continueProviderSessionId': prevProviderSessionId};
      }
    }
    final title = loopId != null
        ? '${definition.name} – ${step.name} ($loopId iter $loopIteration)'
        : '${definition.name} – ${step.name}';

    // Workflow-owned agent steps whose declared outputs need model claims
    // finalize through the structured envelope: the main prompt drops the
    // output-contract and step-outcome sections (they move to the finalizer
    // turn), and the persisted schema is the strict envelope.
    final needsFinalizer = stepNeedsFinalizer(step, effectiveOutputs);
    final emitOutcomeProtocol = !needsFinalizer && !step.emitsOwnOutcome;
    // Keys the envelope claims travel out of the main prompt; the complement
    // (`outputMode: prompt` opt-outs, `*_source`, host-owned keys) still renders
    // its contract. Empty on non-finalizer steps, so all keys render.
    final finalizerCoveredKeys = needsFinalizer ? modelDerivedFinalizerKeys(step, effectiveOutputs) : const <String>[];
    final firstTaskPrompt = step.isMultiPrompt
        ? _skillPromptBuilder.build(
            skill: visibleSkill,
            resolvedPrompt: resolvedFirstPrompt,
            contextSummary: contextSummary,
            outputs: effectiveOutputs,
            outputKeys: effectiveOutputKeys,
            outputExamples: step.outputExamples,
            finalizerCoveredKeys: finalizerCoveredKeys,
            autoFrameContext: step.autoFrameContext,
            inputs: step.inputs,
            variables: variableNames,
            resolvedInputValues: resolvedInputValues,
            templatePrompt: step.prompts?.first,
            provider: taskProvider,
            gatingSeverity: resolved.gatingSeverity,
          )
        : _skillPromptBuilder.build(
            skill: visibleSkill,
            resolvedPrompt: resolvedFirstPrompt,
            contextSummary: contextSummary,
            outputs: effectiveOutputs,
            outputKeys: effectiveOutputKeys,
            outputExamples: step.outputExamples,
            emitStepOutcomeProtocol: emitOutcomeProtocol,
            finalizerCoveredKeys: finalizerCoveredKeys,
            autoFrameContext: step.autoFrameContext,
            inputs: step.inputs,
            variables: variableNames,
            resolvedInputValues: resolvedInputValues,
            templatePrompt: step.prompts?.first,
            provider: taskProvider,
            gatingSeverity: resolved.gatingSeverity,
          );
    final followUpPrompts = _buildOneShotFollowUpPrompts(
      step,
      context,
      effectiveOutputs,
      outputKeys: effectiveOutputKeys,
      gatingSeverity: resolved.gatingSeverity,
      finalizerHandlesOutputs: needsFinalizer,
      mapCtx: mapCtx,
    );
    final structuredSchema = needsFinalizer
        ? buildExecutionEnvelopeSchema(
            step,
            effectiveOutputs,
            gatingSeverity: resolved.gatingSeverity ?? defaultGatingSeverity,
          )
        : null;
    taskConfig = {...taskConfig, ...?extraTaskConfig};
    if (followUpPrompts.isNotEmpty) {
      taskConfig['_workflowFollowUpPrompts'] = followUpPrompts;
    }
    if (structuredSchema != null) {
      taskConfig['_workflowStructuredSchema'] = structuredSchema;
    }
    taskConfig[WorkflowTaskConfig.workflowStepName] = step.name;
    var accumulatedTokenCount = 0;

    String? lastFailureReason;
    return runWithWorkflowRetry<StepOutcome?>(
      onFailure: step.onFailure,
      maxRetries: resolved.maxRetries ?? 0,
      isFailedOutcome: (result) => result?.outcome == 'failed',
      failureReason: (result) {
        lastFailureReason = result?.outcomeReason ?? result?.error;
        return lastFailureReason;
      },
      onRetry: (retryNumber, retryLimit, _) {
        WorkflowExecutor._log.info(
          "Workflow '${run.id}': retrying step '${step.id}' after failed outcome ($retryNumber/$retryLimit)",
        );
      },
      dispatchAttempt: (attemptIndex) async {
        final taskId = _uuid.v4();
        final completer = Completer<Task>();
        final sub = _eventBus.on<TaskStatusChangedEvent>().where((e) => e.taskId == taskId).listen((event) {
          if (event.newStatus == TaskStatus.failed && event.trigger == 'retry-in-progress') {
            // Transient failed state before a task-level retry re-queues. The
            // matching queued(trigger:'retry') event will follow synchronously;
            // no DB read or delay needed – just ignore this transition.
            return;
          }
          if (event.newStatus == TaskStatus.queued || event.newStatus == TaskStatus.running) {
            // Task re-queued for retry or still active – not terminal.
            return;
          }
          if (event.newStatus.terminal && !completer.isCompleted) {
            _taskService.get(taskId).then((t) {
              if (t != null && !completer.isCompleted) completer.complete(t);
            });
          }
        });

        try {
          final description = attemptIndex == 0
              ? firstTaskPrompt
              : _withWorkflowRetryFeedback(firstTaskPrompt, lastFailureReason);
          await _createWorkflowTaskTriple(
            taskId: taskId,
            run: run,
            step: step,
            stepIndex: stepIndex,
            title: title,
            description: description,
            type: TaskType.coding,
            provider: taskProvider,
            projectId: effectiveProjectId,
            maxTokens: resolved.maxTokens,
            taskConfig: taskConfig,
          );
        } catch (e, st) {
          await sub.cancel();
          final msg = "Failed to create task for step '${step.name}': $e";
          WorkflowExecutor._log.severe("Workflow '${run.id}': $msg", e, st);
          await _failRun(run, msg);
          return null;
        }

        onFirstTaskCreated?.call(taskId);
        WorkflowExecutor._log.fine("Workflow '${run.id}': step '${step.id}' → task $taskId");

        late Task finalTask;
        try {
          finalTask = await _waitForTaskCompletion(
            taskId,
            step,
            completer,
            sub,
            runId: run.id,
            timeoutSeconds: resolved.timeoutSeconds,
          );
        } on TimeoutException {
          final msg = 'Step "${step.name}" timed out after ${resolved.timeoutSeconds}s';
          WorkflowExecutor._log.warning("Workflow '${run.id}': $msg");
          await _failRun(run, msg);
          return null;
        } on _WorkflowRunWaitAbort catch (e) {
          WorkflowExecutor._log.info("Workflow '${run.id}': step '${step.name}' wait aborted: ${e.message}");
          return null;
        } catch (e, st) {
          final msg = "Step '${step.name}' wait failed: $e";
          WorkflowExecutor._log.severe("Workflow '${run.id}': $msg", e, st);
          await _failRun(run, msg);
          return null;
        }

        final tokenCount = await _readStepTokenCount(finalTask);
        accumulatedTokenCount += tokenCount;

        Map<String, dynamic> outputs = {};
        StepValidationFailure? extractionFailure;
        if (finalTask.status != TaskStatus.failed && finalTask.status != TaskStatus.cancelled) {
          try {
            final extractionStep = resolved.gatingSeverity == step.gatingSeverity
                ? step
                : step.copyWith(gatingSeverity: resolved.gatingSeverity);
            outputs = await _contextExtractor.extract(extractionStep, finalTask, effectiveOutputs: effectiveOutputs);
          } on MissingArtifactFailure catch (e, st) {
            extractionFailure = StepValidationFailure(reason: e.toString(), missingArtifacts: e.missingPaths);
            WorkflowExecutor._log.warning("Context extraction failed for step '${step.id}'", e, st);
          } on StateError catch (e, st) {
            extractionFailure = StepValidationFailure(reason: e.message);
            WorkflowExecutor._log.warning("Context extraction failed for step '${step.id}'", e, st);
          } catch (e, st) {
            // Fail loud: an unexpected extraction error means the declared outputs
            // cannot be trusted, so the step must fail rather than report success
            // with empty/partial context. Matches the map path (map_iteration_dispatcher).
            extractionFailure = StepValidationFailure(reason: e.toString());
            WorkflowExecutor._log.warning("Context extraction failed for step '${step.id}'", e, st);
          }
        }

        final wj = finalTask.worktreeJson;
        outputs['${step.id}.branch'] = (wj?['branch'] as String?) ?? '';
        outputs['${step.id}.worktree_path'] = (wj?['path'] as String?) ?? '';
        if (wj == null &&
            resolvedWorktreeMode != 'inline' &&
            step_config_policy.stepNeedsWorktree(
              definition,
              step,
              resolved,
              resolvedWorktreeMode: resolvedWorktreeMode,
              effectiveOutputs: effectiveOutputs,
            )) {
          WorkflowExecutor._log.warning(
            "Workflow '${run.id}': step '${step.id}' requires a worktree but has no worktree metadata – "
            'branch/worktree_path context values will be empty',
          );
        }
        final outputWorkspaceRoot = _outputValidationWorkspaceRoot(wj, activeWorkspaceRoot);
        final normalizedOutputs = _validateStorySpecOutputs(run, step, outputs, outputWorkspaceRoot);
        outputs = normalizedOutputs.outputs;
        final validationFailure = normalizedOutputs.validationFailure ?? extractionFailure;
        final providerSessionId = _workflowStepExecutionRepository == null
            ? null
            : await WorkflowTaskConfig.readProviderSessionId(finalTask, _workflowStepExecutionRepository);
        if (providerSessionId != null) {
          outputs['${step.id}.providerSessionId'] = providerSessionId;
        }
        if (_outputTransformer != null &&
            finalTask.status != TaskStatus.failed &&
            finalTask.status != TaskStatus.cancelled) {
          outputs = await _outputTransformer(run, definition, step, finalTask, outputs);
        }

        final (outcome, outcomeReason) = await _resolveStepOutcome(step, finalTask, runId: run.id);
        final effectiveOutcome = validationFailure != null && outcome != 'needsInput' && outcome != 'cancelled'
            ? 'failed'
            : outcome;
        // A SIGTERM'd task usually leaves declared outputs unwritten, so a
        // co-occurring validation failure must not mask the interruption
        // reason (or rewrite the outcome) for cancelled tasks.
        final effectiveReason =
            (effectiveOutcome == 'cancelled' ? null : validationFailure?.reason) ??
            ((outcomeReason != null && outcomeReason.isNotEmpty)
                ? outcomeReason
                : (finalTask.configJson['failReason'] as String?) ?? finalTask.status.name);
        if (validationFailure != null && outcome != effectiveOutcome) {
          WorkflowExecutor._log.warning(
            "Workflow '${run.id}': step '${step.id}' outcome overridden from "
            "'$outcome' to 'failed' due to post-extraction validation failure: "
            '${validationFailure.reason}',
          );
        }

        // Teardown interruption bypasses every policy branch: onFailure
        // retry/continue/pause must not re-dispatch or advance past a task the
        // run's own teardown killed. Controllers map this outcome to their
        // interrupted/pause seams (the retry wrapper keys on 'failed', so no
        // second attempt fires).
        if (effectiveOutcome == 'cancelled') {
          // A cancelled task rarely records a failReason, leaving the bare (or
          // empty) status name as the reason; substitute an operator-facing
          // interruption message so pause reasons read as resumable. Worded
          // cause-neutrally: teardown is the designed producer, but operator
          // task-cancel and emergency stop reach this branch too.
          final interruptionReason = effectiveReason.isEmpty || effectiveReason == finalTask.status.name
              ? "Step '${step.id}' was interrupted by task cancellation and can be resumed."
              : effectiveReason;
          return StepOutcome(
            step: step,
            task: finalTask,
            outputs: outputs,
            tokenCount: accumulatedTokenCount,
            success: false,
            error: interruptionReason,
            outcome: effectiveOutcome,
            outcomeReason: interruptionReason,
            validationFailure: validationFailure,
          );
        }

        if (effectiveOutcome == 'needsInput') {
          final approvals = workflowApprovalPolicyFromRun(run);
          if (approvals == WorkflowApprovalPolicy.autoOnStall || approvals == WorkflowApprovalPolicy.auto) {
            final autoResolvedKey = '$approvalAutoResolvedPrefix${step.id}';
            final autoResolvedValue = approvalAutoResolvedValue(
              policy: approvals,
              reason: effectiveReason,
              source: 'needsInput',
            );
            context[autoResolvedKey] = autoResolvedValue;
            outputs[autoResolvedKey] = autoResolvedValue;
            WorkflowExecutor._log.info(
              "Workflow '${run.id}': auto-resolved needsInput for step '${step.id}' "
              'with approval policy ${approvals.yamlValue}: $effectiveReason',
            );
            _eventBus.fire(
              WorkflowApprovalResolvedEvent(
                runId: run.id,
                stepId: step.id,
                approved: true,
                feedback: effectiveReason,
                timestamp: DateTime.now(),
              ),
            );
            return StepOutcome(
              step: step,
              task: finalTask,
              outputs: outputs,
              tokenCount: accumulatedTokenCount,
              success: true,
              error: effectiveReason,
              outcome: effectiveOutcome,
              outcomeReason: effectiveReason,
              validationFailure: validationFailure,
            );
          }
          if (step.onFailure == OnFailurePolicy.continueWorkflow) {
            return StepOutcome(
              step: step,
              task: finalTask,
              outputs: outputs,
              tokenCount: accumulatedTokenCount,
              success: true,
              error: effectiveReason,
              outcome: effectiveOutcome,
              outcomeReason: effectiveReason,
              validationFailure: validationFailure,
            );
          }
          return StepOutcome(
            step: step,
            task: finalTask,
            outputs: outputs,
            tokenCount: accumulatedTokenCount,
            success: false,
            error: effectiveReason,
            outcome: effectiveOutcome,
            outcomeReason: effectiveReason,
            awaitingApproval: true,
            validationFailure: validationFailure,
          );
        }

        if (effectiveOutcome == 'failed') {
          switch (step.onFailure) {
            case OnFailurePolicy.continueWorkflow:
              return StepOutcome(
                step: step,
                task: finalTask,
                outputs: outputs,
                tokenCount: accumulatedTokenCount,
                success: true,
                error: effectiveReason,
                outcome: effectiveOutcome,
                outcomeReason: effectiveReason,
                validationFailure: validationFailure,
              );
            case OnFailurePolicy.retry:
              break;
            case OnFailurePolicy.pause:
              return StepOutcome(
                step: step,
                task: finalTask,
                outputs: outputs,
                tokenCount: accumulatedTokenCount,
                success: false,
                error: effectiveReason,
                outcome: effectiveOutcome,
                outcomeReason: effectiveReason,
                awaitingApproval: true,
                validationFailure: validationFailure,
              );
            case OnFailurePolicy.fail:
              break;
          }

          return StepOutcome(
            step: step,
            task: finalTask,
            outputs: outputs,
            tokenCount: accumulatedTokenCount,
            success: false,
            error: effectiveReason,
            outcome: effectiveOutcome,
            outcomeReason: effectiveReason,
            validationFailure: validationFailure,
          );
        }

        if (promoteAfterSuccess) {
          final promotionFailure = await _promoteWorkflowTask(
            run: run,
            step: step,
            task: finalTask,
            context: context,
            outputs: outputs,
            projectId: effectiveProjectId,
            promotionStrategy: effectivePromotion,
          );
          if (promotionFailure != null) {
            return StepOutcome(
              step: step,
              task: finalTask,
              outputs: outputs,
              tokenCount: accumulatedTokenCount,
              success: false,
              error: promotionFailure,
              outcome: effectiveOutcome,
              outcomeReason: outcomeReason,
              validationFailure: validationFailure,
            );
          }
        }

        return StepOutcome(
          step: step,
          task: finalTask,
          outputs: outputs,
          tokenCount: accumulatedTokenCount,
          success: true,
          outcome: effectiveOutcome,
          outcomeReason: outcomeReason,
          validationFailure: validationFailure,
        );
      },
    );
  }

  Future<StepOutcome> _executeBashStep(WorkflowRun run, WorkflowStep step, WorkflowContext context) =>
      bash_step_runner.executeBashStep(
        run: run,
        step: step,
        context: context,
        dataDir: _dataDir,
        templateEngine: _templateEngine,
        hostEnvironment: _hostEnvironment,
        envAllowlist: _bashStepEnvAllowlist,
        extraStripPatterns: _bashStepExtraStripPatterns,
      );

  Future<bool> _executeApprovalStep(
    WorkflowRun run,
    WorkflowStep step,
    WorkflowContext context, {
    required int stepIndex,
  }) => approval_step_runner.executeApprovalStep(
    run: run,
    step: step,
    context: context,
    stepIndex: stepIndex,
    templateEngine: _templateEngine,
    dependencies: approval_step_runner.ApprovalStepDependencies(
      eventBus: _eventBus,
      repository: _repository,
      persistContext: _persistContext,
      cancelRun: _cancelRun,
      approvalTimers: _approvalTimers,
    ),
  );

  Future<StepOutcome> _executeAggregateStep(
    WorkflowRun run,
    WorkflowDefinition definition,
    WorkflowStep step,
    WorkflowContext context, {
    required String? activeWorkspaceRoot,
  }) => aggregate_step_runner.executeAggregateStep(
    run: run,
    definition: definition,
    step: step,
    context: context,
    dataDir: _dataDir,
    activeWorkspaceRoot: activeWorkspaceRoot,
  );
}

String? _outputValidationWorkspaceRoot(Map<String, dynamic>? worktreeJson, String? activeWorkspaceRoot) {
  final worktreePath = (worktreeJson?['path'] as String?)?.trim();
  return worktreePath == null || worktreePath.isEmpty ? activeWorkspaceRoot : worktreePath;
}

String _withWorkflowRetryFeedback(String prompt, String? failureReason) {
  final reason = failureReason == null || failureReason.trim().isEmpty
      ? 'The previous attempt failed workflow validation.'
      : failureReason.trim();
  return '$prompt\n\n'
      '## Previous Workflow Attempt\n'
      'The previous attempt failed workflow validation:\n'
      '$reason\n\n'
      'Correct that failure before returning. If you emit artifact paths, write those files first.';
}
