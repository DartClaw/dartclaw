import 'dart:async' show Completer, StreamSubscription, TimeoutException, Timer, unawaited;
import 'dart:collection' show Queue;
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';

import 'workflow_definition.dart';
import 'workflow_run.dart';
import 'workflow_run_repository.dart' show WorkflowRunRepository;

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'approval_step_runner.dart' as approval_step_runner;
import 'aggregate_step_runner.dart' as aggregate_step_runner;
import 'bash_step_runner.dart' as bash_step_runner;
import 'context_extractor.dart';
import 'dependency_graph.dart';
import 'execution_envelope_schema.dart';
import 'gate_evaluator.dart';
import 'map_context.dart';
import 'map_step_context.dart';
import 'missing_artifact_failure.dart';
import 'workflow_cleanup_policy.dart';
import 'skill_prompt_builder.dart';
import '../skills/provider_auth_preflight.dart';
import 'skill_introspector.dart';
import 'step_config_policy.dart' as step_config_policy;
import 'step_config_resolver.dart';
import 'step_retry_policy.dart';
import 'step_outcome_normalizer.dart' as step_outcome_normalizer;
import 'built_in_workflow_workspace.dart';
import 'workflow_context.dart';
import 'workflow_context_persistence.dart';
import 'workflow_approval_policy.dart';
import 'workflow_failure.dart';
import 'workflow_artifact_committer.dart' as workflow_artifact_committer;
import 'workflow_budget_monitor.dart' as workflow_budget_monitor;
import 'workflow_git_lifecycle.dart' as workflow_git_lifecycle;
import 'workflow_git_port.dart';
import 'workflow_run_paths.dart';
import 'workflow_runner_types.dart';
import 'workflow_task_factory.dart' as workflow_task_factory;
import 'workflow_skill_preflight.dart';
import 'workflow_step_effective_outputs.dart';
import 'workflow_template_engine.dart';
import 'merge_resolve_attempt_artifact.dart';
import 'workflow_task_config.dart';
import 'promotion_coordinator.dart';
import 'workflow_turn_adapter.dart';
export 'workflow_runner_types.dart';
part 'step_dispatcher.dart';
part 'parallel_group_and_step_outcome_runner.dart';
part 'loop_step_runner.dart';
part 'iteration_dispatch_engine.dart';
part 'foreach_iteration_runner.dart';
part 'workflow_executor_helpers.dart';
part 'workflow_executor_task_wait.dart';
part 'workflow_executor_node_helpers.dart';
part 'workflow_executor_session_helpers.dart';
part 'workflow_executor_run_lifecycle.dart';
part 'merge_resolve_coordinator.dart';

class WorkflowExecutor {
  static final _log = Logger('WorkflowExecutor');
  final StepExecutionContext _executionContext;
  final WorkflowTaskService _taskService;
  final EventBus _eventBus;
  final KvService _kvService;
  final WorkflowRunRepository _repository;
  final GateEvaluator _gateEvaluator;
  final ContextExtractor _contextExtractor;
  final WorkflowTemplateEngine _templateEngine;
  final WorkflowGitPort? _workflowGitPort;
  final SkillPromptBuilder _skillPromptBuilder;
  final WorkflowTurnAdapter? _turnAdapter;
  final SkillIntrospector? _skillIntrospector;
  final ProviderAuthPreflight? _providerAuthPreflight;
  final WorkflowSkillPreflightConfig _skillPreflightConfig;
  final TaskRepository? _taskRepository;
  final WorkflowStepExecutionRepository? _workflowStepExecutionRepository;
  final String _dataDir;
  final Uuid _uuid;
  final WorkflowRoleDefaults _roleDefaults;
  WorkflowSkillPreflightResult _skillPreflightResult = WorkflowSkillPreflightResult.empty;
  final Map<String, String>? _hostEnvironment;
  final List<String> _bashStepEnvAllowlist;
  final List<String> _bashStepExtraStripPatterns;
  final ProjectService? _projectService;
  final String? _defaultWorkspaceRoot;
  final Duration _serializeRemainingSettleTimeout;
  String? _workflowWorkspaceDirCache;
  final _approvalTimers = <String, Timer>{};
  final _inputConfigCache = Expando<Map<String, Map<String, OutputConfig>>>('workflowInputConfigCache');
  factory({
    required StepExecutionContext executionContext,
    StepPromptConfiguration? promptConfiguration,
    required String dataDir,
    WorkflowRoleDefaults? roleDefaults,
    BashStepPolicy bashStepPolicy = const BashStepPolicy(),
    Duration serializeRemainingSettleTimeout = const Duration(seconds: 30),
    Uuid? uuid,
  }) {
    final effectivePromptConfiguration = promptConfiguration ?? StepPromptConfiguration();
    final effectiveRoleDefaults = roleDefaults ?? const WorkflowRoleDefaults();
    final effectiveUuid = uuid ?? const Uuid();
    return WorkflowExecutor._internal(
      executionContext: executionContext,
      promptConfiguration: effectivePromptConfiguration,
      dataDir: dataDir,
      roleDefaults: effectiveRoleDefaults,
      bashStepPolicy: bashStepPolicy,
      serializeRemainingSettleTimeout: serializeRemainingSettleTimeout,
      uuid: effectiveUuid,
    );
  }

  new _internal({
    required StepExecutionContext executionContext,
    required StepPromptConfiguration promptConfiguration,
    required String dataDir,
    required WorkflowRoleDefaults roleDefaults,
    BashStepPolicy bashStepPolicy = const BashStepPolicy(),
    required Duration serializeRemainingSettleTimeout,
    required Uuid uuid,
  }) : _executionContext = executionContext.configured(
         dataDir: dataDir,
         promptConfiguration: promptConfiguration,
         roleDefaults: roleDefaults,
         bashStepPolicy: bashStepPolicy,
         uuid: uuid,
       ),
       _taskService = executionContext.taskService,
       _eventBus = executionContext.eventBus,
       _kvService = executionContext.kvService,
       _repository = executionContext.repository,
       _gateEvaluator = executionContext.gateEvaluator,
       _contextExtractor = executionContext.contextExtractor,
       _templateEngine = promptConfiguration.templateEngine,
       _workflowGitPort = executionContext.workflowGitPort,
       _skillPromptBuilder = promptConfiguration.skillPromptBuilder,
       _turnAdapter = executionContext.turnAdapter,
       _skillIntrospector = executionContext.skillIntrospector,
       _providerAuthPreflight = executionContext.providerAuthPreflight,
       _skillPreflightConfig = executionContext.skillPreflightConfig,
       _taskRepository = executionContext.taskRepository,
       _workflowStepExecutionRepository = executionContext.workflowStepExecutionRepository,
       _dataDir = dataDir,
       _roleDefaults = roleDefaults,
       _hostEnvironment = bashStepPolicy.hostEnvironment,
       _bashStepEnvAllowlist = List.unmodifiable(bashStepPolicy.envAllowlist),
       _bashStepExtraStripPatterns = List.unmodifiable(bashStepPolicy.extraStripPatterns),
       _projectService = executionContext.projectService,
       _defaultWorkspaceRoot = executionContext.defaultWorkspaceRoot,
       _serializeRemainingSettleTimeout = serializeRemainingSettleTimeout,
       _uuid = uuid;

  void _logRun(WorkflowRun run, String msg, {Level level = Level.FINE}) {
    _log.log(level, "Workflow '${run.id}': $msg");
  }

  Future<void> execute(
    WorkflowRun run,
    WorkflowDefinition definition,
    WorkflowContext context, {
    int startFromStepIndex = 0,
    WorkflowExecutionCursor? startCursor,
    bool Function()? isCancelled,
  }) async {
    final runtimeArtifactsDir = await _initializeRuntimeArtifactsDir(run.id);
    context.mergeSystemVariables({'workflow.runtime_artifacts_dir': runtimeArtifactsDir});
    final resumeCursor = startCursor;
    final effectiveStartStepIndex = resumeCursor?.stepIndex ?? startFromStepIndex;
    _log.info("Workflow '${definition.name}' (${run.id}) executing from step $effectiveStartStepIndex");
    final nodes = definition.nodes;
    final stepById = {for (final step in definition.steps) step.id: step};
    final stepIndexById = {
      for (var index = 0; index < definition.steps.length; index++) definition.steps[index].id: index,
    };
    final loopById = {for (final loop in definition.loops) loop.id: loop};
    final totalSteps = definition.steps.length;
    // A run persisted before the map controller was removed re-normalizes its
    // retired controller into whichever node its `parallel` flag selects. Any of
    // them would send the controller's own prompt once instead of fanning out,
    // so refuse the run rather than silently executing a different workflow.
    final retiredController = definition.steps.where((step) => step.isMapStep && !step.isForeachController).firstOrNull;
    if (retiredController != null) {
      await _failRun(
        run,
        'Step "${retiredController.id}" declares "map_over" but no per-item steps. The single-step map controller '
        'was removed; declare the per-item sub-pipeline with "foreach_steps" (or a nested "steps:" block).',
      );
      return;
    }
    final gitInitError = await _initializeWorkflowGit(run, definition, context);
    if (gitInitError != null) {
      await _failRun(run, gitInitError);
      return;
    }
    try {
      _skillPreflightResult = WorkflowSkillPreflightResult.empty;
      _skillPreflightResult = await preflightWorkflowSkillRefs(
        definition: definition,
        introspector: _skillIntrospector,
        skillPreflightConfig: _skillPreflightConfig,
        roleDefaults: _roleDefaults,
        context: context,
        providerAuthPreflight: _providerAuthPreflight,
      );
    } on WorkflowPreflightException catch (e) {
      final failure = _failRun(run, e.message);
      await failure;
      return;
    }
    // Resolve the active workspace root when the workflow emits story_specs so
    // path validation can enforce existence when a root is available. A missing
    // root no longer fails the run: the generic validator falls back to
    // containment-only and skips existence (ADR-041 §Open edge case).
    final activeWorkspaceRoot = _emitsStorySpecs(definition)
        ? await _resolveActiveWorkspaceRoot(run, definition, context)
        : null;
    var activeCursor = resumeCursor;
    var nodeIndex = resumeCursor != null
        ? _nodeIndexForCursor(nodes, stepIndexById, resumeCursor)
        : _nodeIndexForStepIndex(nodes, stepIndexById, effectiveStartStepIndex);
    try {
      while (nodeIndex < nodes.length) {
        final node = nodes[nodeIndex];
        if (isCancelled?.call() ?? false) {
          _log.info("Workflow '${run.id}' cancelled before node ${node.type}");
          return;
        }
        switch (node) {
          case LoopNode(loopId: final loopId):
            final loop = loopById[loopId];
            if (loop == null) {
              await _failRun(run, 'Normalized loop "$loopId" is missing from the definition snapshot.');
              return;
            }
            final loopCursor = switch (activeCursor) {
              WorkflowExecutionCursor(nodeType: WorkflowExecutionCursorNodeType.loop, nodeId: final cursorLoopId)
                  when cursorLoopId == loop.id =>
                activeCursor,
              _ => null,
            };
            final loopResult = await _executeLoop(
              run,
              definition,
              loop,
              context,
              activeWorkspaceRoot: activeWorkspaceRoot,
              isCancelled: isCancelled,
              startFromIteration: loopCursor?.iteration ?? 1,
              startFromStepId: loopCursor?.stepId,
              onRunUpdated: (updated) => run = updated,
            );
            if (loopResult.halted) return;
            activeCursor = null;
            final nextStepIndex = nodeIndex + 1 < nodes.length
                ? _firstStepIndexForNode(nodes[nodeIndex + 1], stepIndexById)
                : definition.steps.length;
            run = run.copyWith(currentStepIndex: nextStepIndex, updatedAt: DateTime.now());
            await _repository.update(run);
            nodeIndex++;
          case ParallelGroupNode(stepIds: final fullGroupStepIds):
            final fullGroup = fullGroupStepIds.map((stepId) => stepById[stepId]).nonNulls.toList(growable: false);
            if (fullGroup.isEmpty) {
              await _failRun(run, 'Normalized parallel group is empty.');
              return;
            }
            final groupStartStepIndex = stepIndexById[fullGroup.first.id]!;
            final failedStepIdsRaw = run.contextJson['_parallel.failed.stepIds'];
            final resumeFailedIds = failedStepIdsRaw is List
                ? Set<String>.from(failedStepIdsRaw.cast<String>())
                : <String>{};
            final isParallelResume = resumeFailedIds.isNotEmpty;
            var group = isParallelResume
                ? fullGroup.where((step) => resumeFailedIds.contains(step.id)).toList()
                : fullGroup;
            if (isParallelResume) {
              _logRun(
                run,
                'resuming parallel group — '
                're-running ${group.length} failed step(s): '
                '${group.map((step) => step.id).join(', ')}',
              );
            }
            final filteredGroup = <WorkflowStep>[];
            for (final groupStep in group) {
              final groupStepIndex = stepIndexById[groupStep.id];
              if (groupStepIndex == null) {
                await _failRun(run, 'Normalized parallel group references missing step "${groupStep.id}".');
                return;
              }
              final skippedRun = await _skipDueToEntryGate(run, groupStep, groupStepIndex, context);
              if (skippedRun != null) {
                run = skippedRun;
                continue;
              }
              filteredGroup.add(groupStep);
            }
            group = filteredGroup;
            if (group.isEmpty) {
              nodeIndex++;
              continue;
            }
            final budgetedRun = await _budgetPreflight(run, definition);
            if (budgetedRun == null) return;
            run = budgetedRun;
            run = run.copyWith(
              contextJson: {...run.contextJson, '_parallel.current.stepIds': fullGroupStepIds},
              updatedAt: DateTime.now(),
            );
            await _repository.update(run);
            final results = await _executeParallelGroup(
              run,
              definition,
              group,
              context,
              activeWorkspaceRoot: activeWorkspaceRoot,
              isCancelled: isCancelled,
            );
            final postGroupRun = await _repository.getById(run.id) ?? run;
            if (postGroupRun.status == WorkflowRunStatus.paused || postGroupRun.status == WorkflowRunStatus.cancelled) {
              return;
            }
            run = postGroupRun;
            _mergeParallelResults(results, context);
            run = _updateParallelBudget(run, results);
            final failedSteps = results.where((result) => !result.success).toList();
            // These closures capture `run` and `group` by reference; `run` is reassigned
            // later in this scope. Read only invariant fields (run.id, group's identity)
            // — anything else will see whichever value happens to be live at fire time.
            void fireParallelStepCompletedEvents(List<StepOutcome> eventResults) {
              for (final result in eventResults) {
                final si = stepIndexById[result.step.id] ?? groupStartStepIndex;
                _fireStepCompletedEvent(
                  run: run,
                  step: result.step,
                  stepIndex: si,
                  totalSteps: totalSteps,
                  taskId: result.task?.id ?? '',
                  success: result.success,
                  outcome: result.outcome,
                  reason: result.outcomeReason,
                  tokenCount: result.tokenCount,
                );
              }
            }
            void fireParallelGroupCompletedEvent(List<StepOutcome> eventResults) {
              final eventFailedSteps = eventResults.where((result) => !result.success).toList();
              _eventBus.fire(
                ParallelGroupCompletedEvent(
                  runId: run.id,
                  stepIds: group.map((step) => step.id).toList(),
                  successCount: eventResults.length - eventFailedSteps.length,
                  failureCount: eventFailedSteps.length,
                  totalTokens: eventResults.fold(0, (sum, result) => sum + result.tokenCount),
                  timestamp: DateTime.now(),
                ),
              );
            }
            if (failedSteps.isNotEmpty) {
              final refreshedRun = await _repository.getById(run.id) ?? run;
              if (refreshedRun.status == WorkflowRunStatus.paused ||
                  refreshedRun.status == WorkflowRunStatus.cancelled) {
                return;
              }
              // Failure path keeps every refreshedRun.contextJson key (including any
              // _parallel.* markers), then overwrites the two we set here. Symmetric
              // with the success path's filtered spread is intentional: on failure-resume
              // we want the merged-but-not-yet-cleaned context preserved.
              run = refreshedRun.copyWith(
                totalTokens: run.totalTokens,
                currentStepIndex: groupStartStepIndex,
                contextJson: {
                  ...refreshedRun.contextJson,
                  ...context.toJson(),
                  '_parallel.current.stepIds': fullGroupStepIds,
                  '_parallel.failed.stepIds': failedSteps.map((result) => result.step.id).toList(),
                },
                updatedAt: DateTime.now(),
              );
              await _persistContext(run.id, context);
              await _repository.update(run);
              fireParallelStepCompletedEvents(results);
              fireParallelGroupCompletedEvent(results);

              // Interruption dominates the group verdict: a teardown-cancelled
              // member pauses the run (group-restart state is already persisted
              // above), never fails it – genuinely-failed members keep their
              // `_parallel.failed.stepIds` restart semantics on resume.
              final cancelledMember = failedSteps.where((result) => result.outcome == 'cancelled').firstOrNull;
              if (cancelledMember != null) {
                await _pauseRun(
                  run,
                  "Parallel step '${cancelledMember.step.id}' was interrupted by task cancellation; "
                  'resume re-runs the interrupted and failed steps.',
                );
                return;
              }
              final approvalHold = failedSteps.where((result) => result.awaitingApproval).firstOrNull;
              if (approvalHold != null) {
                run = await _transitionStepAwaitingApproval(
                  run,
                  approvalHold.step,
                  context,
                  stepIndex: stepIndexById[approvalHold.step.id] ?? groupStartStepIndex,
                  reason: approvalHold.outcomeReason ?? approvalHold.error ?? 'approval required',
                );
                return;
              }
              final failedNames = failedSteps.map((result) => "'${result.step.name}'").join(', ');
              final msg = 'Parallel step(s) failed: $failedNames';
              _logRun(run, msg, level: Level.INFO);
              await _failRun(run, msg);
              return;
            }

            for (final result in results) {
              final task = result.task;
              if (!result.success || task == null) continue;
              final artifactCommitResult = await _maybeCommitArtifacts(
                run: run,
                definition: definition,
                step: result.step,
                context: context,
                task: task,
              );
              if (artifactCommitResult.failed && artifactCommitResult.fatal) {
                final msg =
                    artifactCommitResult.failureReason ??
                    "Artifact commit failed for parallel step '${result.step.id}'";
                run = run.copyWith(
                  currentStepIndex: groupStartStepIndex,
                  contextJson: {
                    for (final e in run.contextJson.entries)
                      if (e.key != '_parallel.current.stepIds' && e.key != '_parallel.failed.stepIds') e.key: e.value,
                    ...context.toJson(),
                  },
                  updatedAt: DateTime.now(),
                );
                await _persistContext(run.id, context);
                await _repository.update(run);
                final eventResults = [
                  for (final eventResult in results)
                    eventResult.step.id == result.step.id
                        ? StepOutcome(
                            step: eventResult.step,
                            task: eventResult.task,
                            outputs: eventResult.outputs,
                            tokenCount: eventResult.tokenCount,
                            success: false,
                            error: msg,
                            outcome: eventResult.outcome,
                            outcomeReason: eventResult.outcomeReason,
                            awaitingApproval: eventResult.awaitingApproval,
                            validationFailure: eventResult.validationFailure,
                          )
                        : eventResult,
                ];
                fireParallelStepCompletedEvents(eventResults);
                fireParallelGroupCompletedEvent(eventResults);
                await _failRun(run, msg);
                return;
              }
            }

            run = run.copyWith(
              currentStepIndex: groupStartStepIndex + fullGroup.length,
              contextJson: {
                for (final e in run.contextJson.entries)
                  if (e.key != '_parallel.current.stepIds' && e.key != '_parallel.failed.stepIds') e.key: e.value,
                ...context.toJson(),
              },
              updatedAt: DateTime.now(),
            );
            await _persistContext(run.id, context);
            await _repository.update(run);
            // Events are intentionally emitted after the run row has the same
            // context that sequential step consumers observe.
            fireParallelStepCompletedEvents(results);
            fireParallelGroupCompletedEvent(results);
            nodeIndex++;
          case ForeachNode(stepId: final foreachStepId, childStepIds: final childStepIds):
            final foreachStep = stepById[foreachStepId];
            final foreachStepIndex = stepIndexById[foreachStepId];
            if (foreachStep == null || foreachStepIndex == null) {
              await _failRun(run, 'Normalized foreach node references missing step "$foreachStepId".');
              return;
            }
            final budgetedRun = await _budgetPreflight(run, definition);
            if (budgetedRun == null) return;
            run = budgetedRun;
            final foreachCursor = switch (activeCursor) {
              WorkflowExecutionCursor(nodeType: WorkflowExecutionCursorNodeType.foreach, nodeId: final cursorStepId)
                  when cursorStepId == foreachStep.id =>
                activeCursor,
              _ => null,
            };
            final foreachResult = await _executeForeachStep(
              run,
              definition,
              foreachStep,
              childStepIds,
              context,
              activeWorkspaceRoot: activeWorkspaceRoot,
              stepById: stepById,
              stepIndex: foreachStepIndex,
              resumeCursor: foreachCursor,
              isCancelled: isCancelled,
            );
            if (foreachResult == null) return;
            activeCursor = null;
            for (final outputKey in foreachStep.outputKeys) {
              context[outputKey] = foreachResult.results;
            }
            final foreachFailure = foreachResult.failure;
            if (foreachFailure != null) {
              final msg = foreachFailure.message;
              _logRun(run, msg, level: Level.INFO);
              final refreshedRun = await _repository.getById(run.id) ?? run;
              // A promotion conflict keeps its cursor so the conflicted item can
              // be re-dispatched; so does a legacy-state resume break, which must
              // leave the persisted cursor describing where the run stopped.
              final keepCursor =
                  foreachFailure is WorkflowPromotionConflictFailure ||
                  foreachFailure is WorkflowLegacyIterationStateFailure ||
                  foreachResult.results.any((result) => result == null);
              // The shipped stop set: these fail the run even under
              // `onFailure: continue`. The empty-result guard beside it keeps the
              // settle-timeout and the zero-item preflight aggregates out too.
              final stopsRun = switch (foreachFailure) {
                WorkflowForeachControllerFailure() ||
                WorkflowEscalatedHardFailure() ||
                WorkflowPromotionConflictFailure() ||
                WorkflowPromotionFailure() ||
                WorkflowSerializeRemainingSettleTimeout() ||
                WorkflowLegacyIterationStateFailure() => true,
                WorkflowIterationFailure() || WorkflowIterationBlockedHold() || WorkflowIterationCancelled() => false,
              };
              if (foreachStep.onFailure == OnFailurePolicy.continueWorkflow &&
                  foreachResult.results.isNotEmpty &&
                  !stopsRun) {
                context['step.${foreachStep.id}.outcome'] = 'failed';
                context['step.${foreachStep.id}.outcome.reason'] = msg;
                run = refreshedRun.copyWith(
                  totalTokens: refreshedRun.totalTokens + foreachResult.totalTokens,
                  currentStepIndex: foreachStepIndex + 1,
                  executionCursor: keepCursor ? refreshedRun.executionCursor : null,
                  contextJson: {
                    ...privateContextEntries(refreshedRun.contextJson, exclude: '_foreach.current'),
                    ...context.toJson(),
                  },
                  updatedAt: DateTime.now(),
                );
                await _persistContext(run.id, context);
                await _repository.update(run);
                _fireStepCompletedEvent(
                  run: run,
                  step: foreachStep,
                  stepIndex: foreachStepIndex,
                  totalSteps: totalSteps,
                  taskId: '',
                  success: false,
                  tokenCount: foreachResult.totalTokens,
                );
                nodeIndex++;
                continue;
              }
              run = refreshedRun.copyWith(
                totalTokens: refreshedRun.totalTokens + foreachResult.totalTokens,
                executionCursor: keepCursor ? refreshedRun.executionCursor : null,
                contextJson: {
                  ...privateContextEntries(refreshedRun.contextJson, exclude: '_foreach.current'),
                  ...context.toJson(),
                },
                updatedAt: DateTime.now(),
              );
              await _persistContext(run.id, context);
              await _repository.update(run);
              if (foreachFailure is WorkflowSerializeRemainingSettleTimeout) {
                await _failRunAndCancelActiveTasks(run, msg, taskCancelTrigger: 'serialize-remaining-settle-timeout');
              } else {
                await _failRun(run, msg);
              }
              return;
            }
            run = run.copyWith(
              totalTokens: run.totalTokens + foreachResult.totalTokens,
              currentStepIndex: foreachStepIndex + 1,
              executionCursor: null,
              contextJson: {
                ...privateContextEntries(run.contextJson, exclude: '_foreach.current'),
                ...context.toJson(),
              },
              updatedAt: DateTime.now(),
            );
            await _persistContext(run.id, context);
            await _repository.update(run);
            _fireStepCompletedEvent(
              run: run,
              step: foreachStep,
              stepIndex: foreachStepIndex,
              totalSteps: totalSteps,
              taskId: '',
              success: true,
              tokenCount: foreachResult.totalTokens,
            );
            nodeIndex++;
          case ActionNode(stepId: final stepId):
            final step = stepById[stepId];
            final stepIndex = stepIndexById[stepId];
            if (step == null || stepIndex == null) {
              await _failRun(run, 'Normalized action node references missing step "$stepId".');
              return;
            }
            final skippedRun = await _skipDueToEntryGate(run, step, stepIndex, context);
            if (skippedRun != null) {
              run = skippedRun;
              nodeIndex++;
              continue;
            }
            final budgetedRun = await _budgetPreflight(run, definition);
            if (budgetedRun == null) return;
            run = budgetedRun;
            final followingActionSteps = nodes
                .skip(nodeIndex + 1)
                .whereType<ActionNode>()
                .map((candidate) => stepById[candidate.stepId])
                .nonNulls;
            final result = await _executeStep(
              run,
              definition,
              step,
              context,
              activeWorkspaceRoot: activeWorkspaceRoot,
              stepIndex: stepIndex,
              promoteAfterSuccess: _isLastBranchTouchingStepInScope(definition, step, followingActionSteps),
            );
            if (result == null) return;
            if (isCancelled?.call() ?? false) {
              _log.info("Workflow '${run.id}' cancelled after step ${step.id}");
              return;
            }
            if (!result.success) {
              final reason = result.error ?? result.task?.configJson['failReason'] as String?;
              final msg =
                  "Step '${step.id}' (${step.name}) ${result.task?.status.name ?? 'failed'}"
                  "${reason != null ? ': $reason' : ''}";
              _logRun(run, msg, level: Level.INFO);
              void fireFailedStepCompletedEvent() => _fireStepCompletedEvent(
                run: run,
                step: step,
                stepIndex: stepIndex,
                totalSteps: totalSteps,
                taskId: result.task?.id ?? '',
                success: false,
                outcome: result.outcome,
                reason: result.outcomeReason ?? reason,
                tokenCount: result.tokenCount,
              );

              // Teardown interruption pauses without advancing currentStepIndex
              // (resume re-runs this step) and is checked before `onError:
              // continue` – advancing past a task the run's own teardown killed
              // would dispatch the next step mid-teardown. The partial attempt's
              // tokens are not charged, consistent with crash-resume.
              if (result.outcome == 'cancelled') {
                _mergeStepResultIntoContext(context, result, fallbackStatus: 'cancelled');
                run = run.copyWith(
                  contextJson: {...privateContextEntries(run.contextJson), ...context.toJson()},
                  updatedAt: DateTime.now(),
                );
                await _persistContextThenRun(run, context);
                fireFailedStepCompletedEvent();
                await _pauseRun(
                  run,
                  "Step '${step.id}' was interrupted by task cancellation; resume re-runs it from its checkpoint.",
                );
                return;
              }
              if (step.onError == OnErrorPolicy.continueWorkflow) {
                _mergeStepResultIntoContext(context, result, fallbackStatus: 'failed');
                run = run.copyWith(
                  totalTokens: run.totalTokens + result.tokenCount,
                  currentStepIndex: stepIndex + 1,
                  contextJson: {...privateContextEntries(run.contextJson), ...context.toJson()},
                  updatedAt: DateTime.now(),
                );
                await _persistContextThenRun(run, context);
                fireFailedStepCompletedEvent();
                nodeIndex++;
                continue;
              }
              _mergeStepResultIntoContext(context, result, fallbackStatus: 'failed');
              run = run.copyWith(
                totalTokens: run.totalTokens + result.tokenCount,
                contextJson: {...privateContextEntries(run.contextJson), ...context.toJson()},
                updatedAt: DateTime.now(),
              );
              await _persistContextThenRun(run, context);
              fireFailedStepCompletedEvent();
              if (result.awaitingApproval) {
                run = await _transitionStepAwaitingApproval(
                  run,
                  step,
                  context,
                  stepIndex: stepIndex,
                  reason: result.outcomeReason ?? reason ?? msg,
                );
                return;
              }
              await _failRun(run, msg);
              return;
            }
            _mergeStepResultIntoContext(context, result, fallbackStatus: result.task?.status.name ?? 'completed');
            var artifactCommitResult = const workflow_artifact_committer.ArtifactCommitResult.skipped();
            if (result.task != null) {
              artifactCommitResult = await _maybeCommitArtifacts(
                run: run,
                definition: definition,
                step: step,
                context: context,
                task: result.task!,
              );
            }
            if (artifactCommitResult.failed && artifactCommitResult.fatal) {
              final msg = artifactCommitResult.failureReason ?? "Artifact commit failed for step '${step.id}'";
              run = run.copyWith(
                totalTokens: run.totalTokens + result.tokenCount,
                contextJson: {...privateContextEntries(run.contextJson), ...context.toJson()},
                updatedAt: DateTime.now(),
              );
              await _persistContextThenRun(run, context);
              _fireStepCompletedEvent(
                run: run,
                step: step,
                stepIndex: stepIndex,
                totalSteps: totalSteps,
                taskId: result.task?.id ?? '',
                success: false,
                tokenCount: result.tokenCount,
              );
              await _failRun(run, msg);
              return;
            }
            run = run.copyWith(
              totalTokens: run.totalTokens + result.tokenCount,
              currentStepIndex: stepIndex + 1,
              contextJson: {...privateContextEntries(run.contextJson), ...context.toJson()},
              updatedAt: DateTime.now(),
            );
            await _persistContextThenRun(run, context);
            _fireStepCompletedEvent(
              run: run,
              step: step,
              stepIndex: stepIndex,
              totalSteps: totalSteps,
              taskId: result.task?.id ?? '',
              success: true,
              tokenCount: result.tokenCount,
            );
            nodeIndex++;
        }
      }
    } on GateUnproducedOutputFailure catch (failure) {
      // A gate with nothing to decide on, not a gate that failed. The refusal
      // is only useful as a recorded failure: letting it escape here tears the
      // executor down with no controlled record to resume or report from.
      await _failRun(run, failure.toString());
      return;
    }
    await _completeRun(run, definition, context);
  }

  Future<void> _cancelRun(WorkflowRun run, String reason) async {
    final cancelled = run.copyWith(
      status: WorkflowRunStatus.cancelled,
      completedAt: DateTime.now(),
      errorMessage: null,
      updatedAt: DateTime.now(),
    );
    await _repository.update(cancelled);
    _fireRunStatusChangedEvent(run: run, newStatus: WorkflowRunStatus.cancelled, errorMessage: reason);
    await _cancelActiveTasksForRun(run.id, trigger: 'approval-timeout');
    await _cleanupWorkflowGit(cancelled, preserveWorktrees: !workflowCleanupEnabledForRun(cancelled, _log));
  }

  Future<void> _cancelActiveTasksForRun(String runId, {required String trigger}) async {
    final allTasks = await _taskService.list();
    for (final task in allTasks) {
      if (task.workflowRunId == runId && (task.status == TaskStatus.queued || task.status == TaskStatus.running)) {
        try {
          await _taskService.transition(task.id, TaskStatus.cancelled, trigger: trigger);
        } on StateError {
          // Already transitioned concurrently.
        } catch (e) {
          _log.warning('Failed to cancel task ${task.id} with trigger "$trigger": $e');
        }
      }
    }
  }

  Future<void> _pauseRun(WorkflowRun run, String reason) async {
    final latest = await _repository.getById(run.id) ?? run;
    if (latest.status != WorkflowRunStatus.running) return;
    final paused = latest.copyWith(status: WorkflowRunStatus.paused, errorMessage: reason, updatedAt: DateTime.now());
    await _repository.update(paused);
    _fireRunStatusChangedEvent(run: latest, newStatus: WorkflowRunStatus.paused, errorMessage: reason);
  }

  Future<void> _failRun(WorkflowRun run, String reason, {bool cleanupWorkflowGit = true}) async {
    final failed = run.copyWith(status: WorkflowRunStatus.failed, errorMessage: reason, updatedAt: DateTime.now());
    await _repository.update(failed);
    _fireRunStatusChangedEvent(run: run, newStatus: WorkflowRunStatus.failed, errorMessage: reason);
    if (cleanupWorkflowGit) {
      await _cleanupWorkflowGit(failed, preserveWorktrees: !workflowCleanupEnabledForRun(failed, _log));
    }
  }

  Future<void> _failRunAndCancelActiveTasks(
    WorkflowRun run,
    String reason, {
    required String taskCancelTrigger,
    bool cleanupWorkflowGit = true,
  }) async {
    final failed = run.copyWith(status: WorkflowRunStatus.failed, errorMessage: reason, updatedAt: DateTime.now());
    await _repository.update(failed);
    _fireRunStatusChangedEvent(run: run, newStatus: WorkflowRunStatus.failed, errorMessage: reason);
    await _cancelActiveTasksForRun(run.id, trigger: taskCancelTrigger);
    if (cleanupWorkflowGit) {
      await _cleanupWorkflowGit(failed, preserveWorktrees: !workflowCleanupEnabledForRun(failed, _log));
    }
  }

  Future<void> _completeRun(WorkflowRun run, WorkflowDefinition definition, WorkflowContext context) async {
    if (definition.gitStrategy?.publish == true) {
      final publishError = await _runDeterministicPublish(run, definition, context);
      if (publishError != null) {
        await _failRun(run, publishError, cleanupWorkflowGit: false);
        return;
      }
      final refreshed = await _repository.getById(run.id);
      if (refreshed != null) {
        run = refreshed;
      }
    }
    final completed = run.copyWith(
      status: WorkflowRunStatus.completed,
      executionCursor: null,
      completedAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    await _repository.update(completed);
    _fireRunStatusChangedEvent(run: run, newStatus: WorkflowRunStatus.completed);
    await _cleanupWorkflowGit(completed, preserveWorktrees: !workflowCleanupEnabledForRun(completed, _log));
    _log.info("Workflow '${run.definitionName}' (${run.id}) completed successfully");
  }

  Future<String?> _runDeterministicPublish(WorkflowRun run, WorkflowDefinition definition, WorkflowContext context) =>
      workflow_git_lifecycle.runDeterministicPublish(
        run: run,
        definition: definition,
        context: context,
        turnAdapter: _turnAdapter,
        repository: _repository,
        persistContext: _persistContext,
        workflowProjectId: _workflowProjectId,
      );
  Future<void> _cleanupWorkflowGit(WorkflowRun run, {required bool preserveWorktrees}) async {
    await workflow_git_lifecycle.cleanupWorkflowGit(
      run: run,
      turnAdapter: _turnAdapter,
      preserveWorktrees: preserveWorktrees,
    );
  }
}
