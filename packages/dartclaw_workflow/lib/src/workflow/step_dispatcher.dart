part of 'workflow_executor.dart';

/// Public step-dispatch contract consumed by scenario tests.
Future<StepHandoff> dispatchStep(WorkflowNode node, StepExecutionContext ctx) async {
  final definition = ctx.definition;
  final run = ctx.run;
  final context = ctx.workflowContext;
  if (definition == null || run == null || context == null) {
    throw StateError('dispatchStep requires run, definition, and workflowContext on StepExecutionContext.');
  }
  final step = switch (node) {
    ActionNode(stepId: final stepId) => definition.steps.firstWhere((candidate) => candidate.id == stepId),
    _ => throw UnsupportedError('dispatchStep handles ActionNode; coordinator runners handle ${node.type}.'),
  };
  if (step.type == 'bash') {
    final outcome = await bash_step_runner.bashStepRun(node, ctx);
    return StepHandoffSuccess.fromOutcome(outcome);
  }
  if (step.type == 'approval') {
    final outcome = await approval_step_runner.approvalStepRun(node, ctx);
    return StepHandoffRetrying(outputs: Map<String, Object?>.from(outcome.outputs), retryState: StepRetryState.none);
  }
  throw UnsupportedError('Agent task dispatch requires a WorkflowExecutor instance.');
}

extension WorkflowExecutorStepDispatcher on WorkflowExecutor {
  /// Executes a single step: resolves template, creates task, waits for terminal state.
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
    bool promoteAfterSuccess = false,
  }) async {
    if (step.type == 'bash') {
      return _executeBashStep(run, step, context);
    }

    if (step.type == 'approval') {
      await _executeApprovalStep(run, step, context, stepIndex: stepIndex);
      return null;
    }

    final resolved = resolveStepConfig(step, definition.stepDefaults, roleDefaults: _roleDefaults);
    final effectiveOutputs = _effectiveOutputsFor(step);
    final resolvedFirstPrompt = step.prompts != null
        ? _templateEngine.resolveWithMap(step.prompts!.first, context, mapCtx)
        : null;
    final contextSummary = step.skill != null && resolvedFirstPrompt == null
        ? SkillPromptBuilder.formatContextSummary({
            for (final key in step.contextInputs) key: context[key] ?? '',
          }, outputConfigs: _inputConfigsFor(definition, step.contextInputs))
        : null;
    final skillDefaultPrompt = _skillDefaultPromptFor(step);
    final resolvedInputValues = _resolvedInputValuesFor(step, definition, context);
    final variableNames = _autoFrameVariableNames(step);
    final resolvedWorktreeMode = _resolvedWorktreeModeForScope(
      definition,
      step,
      context,
      enclosingMaxParallel: enclosingMaxParallel,
    );
    final effectivePromotion = _effectivePromotion(definition.gitStrategy, resolvedWorktreeMode: resolvedWorktreeMode);
    var taskConfig = _buildStepConfig(
      run,
      definition,
      step,
      resolved,
      context,
      resolvedWorktreeMode: resolvedWorktreeMode,
      effectivePromotion: effectivePromotion,
    );

    final continuedRootStep = step.continueSession != null ? _resolveContinueSessionRootStep(definition, step) : null;
    final effectiveProvider = continuedRootStep != null
        ? _resolveContinueSessionProvider(definition, step, continuedRootStep, resolved)
        : resolved.provider;
    final effectiveProjectId = mapCtx != null
        ? _resolveProjectIdWithMap(definition, continuedRootStep ?? step, context, mapCtx, resolved: resolved)
        : _resolveProjectId(definition, continuedRootStep ?? step, context, resolved: resolved);

    if (mapCtx != null) {
      taskConfig = {...taskConfig, '_mapIterationIndex': mapCtx.index, '_mapIterationTotal': mapCtx.length};
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
            'mode': mount.mode,
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
        ? '${definition.name} — ${step.name} ($loopId iter $loopIteration)'
        : '${definition.name} — ${step.name}';

    final emitOutcomeProtocol = !step.emitsOwnOutcome;
    final firstTaskPrompt = step.isMultiPrompt
        ? _skillPromptBuilder.build(
            skill: step.skill,
            resolvedPrompt: resolvedFirstPrompt,
            contextSummary: contextSummary,
            contextOutputs: step.contextOutputs,
            skillDefaultPrompt: skillDefaultPrompt,
            autoFrameContext: step.autoFrameContext,
            contextInputs: step.contextInputs,
            variables: variableNames,
            resolvedInputValues: resolvedInputValues,
            templatePrompt: step.prompts?.first,
            provider: effectiveProvider,
          )
        : _skillPromptBuilder.build(
            skill: step.skill,
            resolvedPrompt: resolvedFirstPrompt,
            contextSummary: contextSummary,
            outputs: effectiveOutputs,
            contextOutputs: step.contextOutputs,
            emitStepOutcomeProtocol: emitOutcomeProtocol,
            skillDefaultPrompt: skillDefaultPrompt,
            autoFrameContext: step.autoFrameContext,
            contextInputs: step.contextInputs,
            variables: variableNames,
            resolvedInputValues: resolvedInputValues,
            templatePrompt: step.prompts?.first,
            provider: effectiveProvider,
          );
    final followUpPrompts = _buildOneShotFollowUpPrompts(
      step,
      context,
      effectiveOutputs,
      contextOutputs: step.contextOutputs,
      mapCtx: mapCtx,
    );
    final structuredSchema = _buildStructuredOutputEnvelopeSchema(step);
    taskConfig = {...taskConfig};
    if (followUpPrompts.isNotEmpty) {
      taskConfig['_workflowFollowUpPrompts'] = followUpPrompts;
    }
    if (structuredSchema != null) {
      taskConfig['_workflowStructuredSchema'] = structuredSchema;
    }
    final outcomeRetryLimit = step.onFailure == OnFailurePolicy.retry ? (resolved.maxRetries ?? 0) : 0;
    var attempt = 0;
    var accumulatedTokenCount = 0;

    while (true) {
      final taskId = _uuid.v4();
      final completer = Completer<Task>();
      final sub = _eventBus.on<TaskStatusChangedEvent>().where((e) => e.taskId == taskId).listen((event) async {
        if (event.newStatus == TaskStatus.failed) {
          final t = await _taskService.get(taskId);
          if (t == null) return;
          if (t.status == TaskStatus.queued || t.status == TaskStatus.running) return;
          if (t.retryCount < t.maxRetries) return;
          if (!completer.isCompleted) completer.complete(t);
        } else if (event.newStatus.terminal) {
          if (!completer.isCompleted) {
            final t = await _taskService.get(taskId);
            if (t != null) completer.complete(t);
          }
        }
      });

      try {
        await _createWorkflowTaskTriple(
          taskId: taskId,
          run: run,
          step: step,
          stepIndex: stepIndex,
          title: title,
          description: firstTaskPrompt,
          type: TaskType.coding,
          provider: effectiveProvider,
          projectId: effectiveProjectId,
          maxTokens: resolved.maxTokens,
          maxRetries: resolved.maxRetries ?? 0,
          taskConfig: taskConfig,
        );
      } catch (e, st) {
        await sub.cancel();
        final msg = "Failed to create task for step '${step.name}': $e";
        WorkflowExecutor._log.severe("Workflow '${run.id}': $msg", e, st);
        await _failRun(run, msg);
        return null;
      }

      WorkflowExecutor._log.fine("Workflow '${run.id}': step '${step.id}' → task $taskId");

      late Task finalTask;
      try {
        finalTask = await _waitForTaskCompletion(taskId, step, completer, sub, runId: run.id);
      } on TimeoutException {
        final msg = 'Step "${step.name}" timed out after ${step.timeoutSeconds}s';
        WorkflowExecutor._log.warning("Workflow '${run.id}': $msg");
        await _failRun(run, msg);
        return null;
      } on StateError catch (e) {
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
          outputs = await _contextExtractor.extract(step, finalTask, effectiveOutputs: effectiveOutputs);
        } on MissingArtifactFailure catch (e, st) {
          extractionFailure = StepValidationFailure(reason: e.toString(), missingArtifacts: e.missingPaths);
          WorkflowExecutor._log.warning("Context extraction failed for step '${step.id}'", e, st);
        } on StateError catch (e, st) {
          extractionFailure = StepValidationFailure(reason: e.message);
          WorkflowExecutor._log.warning("Context extraction failed for step '${step.id}'", e, st);
        } catch (e, st) {
          WorkflowExecutor._log.warning("Context extraction failed for step '${step.id}'", e, st);
        }
      }

      final wj = finalTask.worktreeJson;
      outputs['${step.id}.branch'] = (wj?['branch'] as String?) ?? '';
      outputs['${step.id}.worktree_path'] = (wj?['path'] as String?) ?? '';
      if (wj == null && _stepNeedsWorktree(definition, step, resolved, resolvedWorktreeMode: resolvedWorktreeMode)) {
        WorkflowExecutor._log.warning(
          "Workflow '${run.id}': step '${step.id}' requires a worktree but has no worktree metadata — "
          'branch/worktree_path context values will be empty',
        );
      }
      final normalizedOutputs = _validateStorySpecOutputs(run, step, outputs, context);
      outputs = normalizedOutputs.outputs;
      final validationFailure = extractionFailure ?? normalizedOutputs.validationFailure;
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

      final (outcome, outcomeReason) = await _resolveStepOutcome(step, finalTask);
      final effectiveOutcome = validationFailure != null && outcome != 'needsInput' ? 'failed' : outcome;
      final effectiveReason = (outcomeReason != null && outcomeReason.isNotEmpty)
          ? outcomeReason
          : validationFailure?.reason ?? (finalTask.configJson['failReason'] as String?) ?? finalTask.status.name;
      if (validationFailure != null && outcome != effectiveOutcome) {
        WorkflowExecutor._log.warning(
          "Workflow '${run.id}': step '${step.id}' outcome overridden from "
          "'$outcome' to 'failed' due to post-extraction validation failure: "
          '${validationFailure.reason}',
        );
      }

      if (effectiveOutcome == 'needsInput') {
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
            );
          case OnFailurePolicy.retry:
            if (attempt < outcomeRetryLimit) {
              attempt++;
              WorkflowExecutor._log.info(
                "Workflow '${run.id}': retrying step '${step.id}' after failed outcome "
                '($attempt/$outcomeRetryLimit)',
              );
              continue;
            }
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
      );
    }
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

  Future<void> _executeApprovalStep(
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
}
