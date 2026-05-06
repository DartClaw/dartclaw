import 'dart:async' show Completer, StreamSubscription, TimeoutException, Timer;
import 'dart:collection' show Queue;
import 'dart:convert';
import 'dart:io';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show ProviderIdentity;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'approval_step_runner.dart' as approval_step_runner;
import 'bash_step_runner.dart' as bash_step_runner;
import 'context_extractor.dart';
import 'dependency_graph.dart';
import 'gate_evaluator.dart';
import 'map_context.dart';
import 'map_step_context.dart';
import 'missing_artifact_failure.dart';
import 'skill_prompt_builder.dart';
import 'skill_registry.dart';
import 'step_config_policy.dart' as step_config_policy;
import 'step_config_resolver.dart';
import 'step_outcome_normalizer.dart' as step_outcome_normalizer;
import 'built_in_workflow_workspace.dart';
import 'workflow_context.dart';
import 'workflow_artifact_committer.dart' as workflow_artifact_committer;
import 'workflow_budget_monitor.dart' as workflow_budget_monitor;
import 'workflow_git_lifecycle.dart' as workflow_git_lifecycle;
import 'workflow_git_port.dart';
import 'workflow_run_paths.dart';
import 'workflow_runner_types.dart';
import 'workflow_task_factory.dart' as workflow_task_factory;
import 'workflow_template_engine.dart';
import 'merge_resolve_attempt_artifact.dart';
import 'workflow_task_config.dart';
import 'workflow_turn_adapter.dart';
export 'workflow_runner_types.dart';
part 'public_node_runners.dart';
part 'public_step_dispatcher.dart';
part 'public_step_dispatcher_helpers.dart';
part 'step_dispatcher.dart';
part 'parallel_group_runner.dart';
part 'loop_step_runner.dart';
part 'map_iteration_runner.dart';
part 'foreach_iteration_runner.dart';
part 'map_iteration_dispatcher.dart';
part 'workflow_executor_helpers.dart';

class WorkflowExecutor {
  static final _log = Logger('WorkflowExecutor');
  final WorkflowTaskService _taskService;
  final EventBus _eventBus;
  final KvService _kvService;
  final WorkflowRunRepositoryPort _repository;
  final GateEvaluator _gateEvaluator;
  final ContextExtractor _contextExtractor;
  final WorkflowTemplateEngine _templateEngine;
  final WorkflowGitPort? _workflowGitPort;
  final SkillPromptBuilder _skillPromptBuilder;
  final WorkflowTurnAdapter? _turnAdapter;
  final WorkflowStepOutputTransformer? _outputTransformer;
  final SkillRegistry? _skillRegistry;
  final TaskRepository? _taskRepository;
  final AgentExecutionRepository? _agentExecutionRepository;
  final WorkflowStepExecutionRepository? _workflowStepExecutionRepository;
  final ExecutionRepositoryTransactor? _executionTransactor;
  final String _dataDir;
  final Uuid _uuid;
  final WorkflowRoleDefaults _roleDefaults;
  final Map<String, String>? _hostEnvironment;
  final List<String> _bashStepEnvAllowlist;
  final List<String> _bashStepExtraStripPatterns;
  final ProjectService? _projectService;
  String? _workflowWorkspaceDirCache;
  final _approvalTimers = <String, Timer>{};
  final _inputConfigCache = Expando<Map<String, Map<String, OutputConfig>>>('workflowInputConfigCache');
  factory WorkflowExecutor({
    required StepExecutionContext executionContext,
    StepPromptConfiguration? promptConfiguration,
    required String dataDir,
    WorkflowRoleDefaults? roleDefaults,
    BashStepPolicy bashStepPolicy = const BashStepPolicy(),
    Uuid? uuid,
  }) => WorkflowExecutor._internal(
    executionContext: executionContext,
    promptConfiguration: promptConfiguration ?? StepPromptConfiguration(),
    dataDir: dataDir,
    roleDefaults: roleDefaults,
    bashStepPolicy: bashStepPolicy,
    uuid: uuid,
  );
  WorkflowExecutor._internal({
    required StepExecutionContext executionContext,
    required StepPromptConfiguration promptConfiguration,
    required String dataDir,
    WorkflowRoleDefaults? roleDefaults,
    BashStepPolicy bashStepPolicy = const BashStepPolicy(),
    Uuid? uuid,
  }) : _taskService = executionContext.taskService,
       _eventBus = executionContext.eventBus,
       _kvService = executionContext.kvService,
       _repository = WorkflowRunRepositoryPort(executionContext.repository),
       _gateEvaluator = executionContext.gateEvaluator,
       _contextExtractor = executionContext.contextExtractor,
       _templateEngine = promptConfiguration.templateEngine,
       _workflowGitPort = executionContext.workflowGitPort,
       _skillPromptBuilder = promptConfiguration.skillPromptBuilder,
       _turnAdapter = executionContext.turnAdapter,
       _outputTransformer = executionContext.outputTransformer,
       _skillRegistry = executionContext.skillRegistry,
       _taskRepository = executionContext.taskRepository,
       _agentExecutionRepository = executionContext.agentExecutionRepository,
       _workflowStepExecutionRepository = executionContext.workflowStepExecutionRepository,
       _executionTransactor = executionContext.executionTransactor,
       _dataDir = dataDir,
       _roleDefaults = roleDefaults ?? const WorkflowRoleDefaults(),
       _hostEnvironment = bashStepPolicy.hostEnvironment,
       _bashStepEnvAllowlist = List.unmodifiable(bashStepPolicy.envAllowlist),
       _bashStepExtraStripPatterns = List.unmodifiable(bashStepPolicy.extraStripPatterns),
       _projectService = executionContext.projectService,
       _uuid = uuid ?? const Uuid();
  Future<void> execute(
    WorkflowRun run,
    WorkflowDefinition definition,
    WorkflowContext context, {
    int startFromStepIndex = 0,
    WorkflowExecutionCursor? startCursor,
    int? startFromLoopIndex,
    int? startFromLoopIteration,
    String? startFromLoopStepId,
    bool Function()? isCancelled,
  }) async {
    final runtimeArtifactsDir = await _initializeRuntimeArtifactsDir(run.id);
    context.mergeSystemVariables({'workflow.runtime_artifacts_dir': runtimeArtifactsDir});
    final resumeCursor =
        startCursor ??
        _legacyResumeCursor(
          definition,
          startFromLoopIndex: startFromLoopIndex,
          startFromLoopIteration: startFromLoopIteration,
          startFromLoopStepId: startFromLoopStepId,
        );
    final effectiveStartStepIndex = resumeCursor?.stepIndex ?? startFromStepIndex;
    _log.info("Workflow '${definition.name}' (${run.id}) executing from step $effectiveStartStepIndex");
    final nodes = definition.nodes;
    final stepById = {for (final step in definition.steps) step.id: step};
    final stepIndexById = {
      for (var index = 0; index < definition.steps.length; index++) definition.steps[index].id: index,
    };
    final loopById = {for (final loop in definition.loops) loop.id: loop};
    final totalSteps = definition.steps.length;
    final gitInitError = await _initializeWorkflowGit(run, definition, context);
    if (gitInitError != null) {
      await _failRun(run, gitInitError);
      return;
    }
    var activeCursor = resumeCursor;
    var nodeIndex = resumeCursor != null
        ? _nodeIndexForCursor(nodes, stepIndexById, resumeCursor)
        : _nodeIndexForStepIndex(nodes, stepIndexById, effectiveStartStepIndex);
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
          final pauseOrCancel = await _executeLoop(
            run,
            definition,
            loop,
            context,
            isCancelled: isCancelled,
            startFromIteration: loopCursor?.iteration ?? 1,
            startFromStepId: loopCursor?.stepId,
            onRunUpdated: (updated) => run = updated,
          );
          if (pauseOrCancel) return;
          activeCursor = null;
          final nextStepIndex = nodeIndex + 1 < nodes.length
              ? _firstStepIndexForNode(nodes[nodeIndex + 1], stepIndexById)
              : definition.steps.length;
          run = run.copyWith(currentStepIndex: nextStepIndex, updatedAt: DateTime.now());
          await _repository.update(run);
          nodeIndex++;
        case MapNode(stepId: final stepId):
          final step = stepById[stepId];
          final stepIndex = stepIndexById[stepId];
          if (step == null || stepIndex == null) {
            await _failRun(run, 'Normalized map node references missing step "$stepId".');
            return;
          }
          final skippedRun = await _skipDueToEntryGate(run, step, stepIndex, context);
          if (skippedRun != null) {
            run = skippedRun;
            nodeIndex++;
            continue;
          }
          if (step.gate != null) {
            final gatePasses = _gateEvaluator.evaluate(step.gate!, context);
            if (!gatePasses) {
              final msg = "Gate failed for map step '${step.name}': ${step.gate}";
              _log.info("Workflow '${run.id}': $msg");
              await _failRun(run, msg);
              return;
            }
          }
          final refreshedRun = await _repository.getById(run.id) ?? run;
          run = refreshedRun;
          run = await _checkWorkflowBudgetWarning(run, definition);
          if (_workflowBudgetExceeded(run, definition)) {
            final msg = 'Workflow budget exceeded: ${run.totalTokens} / ${definition.maxTokens} tokens';
            _log.info("Workflow '${run.id}': $msg");
            await _failRun(run, msg);
            return;
          }
          final mapCursor = switch (activeCursor) {
            WorkflowExecutionCursor(nodeType: WorkflowExecutionCursorNodeType.map, nodeId: final cursorStepId)
                when cursorStepId == step.id =>
              activeCursor,
            _ => null,
          };
          final mapResult = await _executeMapStep(
            run,
            definition,
            step,
            context,
            stepIndex: stepIndex,
            resumeCursor: mapCursor,
          );
          if (mapResult == null) return;
          activeCursor = null;
          for (final outputKey in step.outputKeys) {
            context[outputKey] = mapResult.results;
          }
          if (!mapResult.success) {
            final msg = mapResult.error ?? "Map step '${step.id}' failed";
            _log.info("Workflow '${run.id}': $msg");
            final refreshedRun = await _repository.getById(run.id) ?? run;
            final keepCursor =
                mapResult.error?.startsWith('promotion-conflict') == true ||
                mapResult.results.any((result) => result == null);
            run = refreshedRun.copyWith(
              totalTokens: refreshedRun.totalTokens + mapResult.totalTokens,
              executionCursor: keepCursor ? refreshedRun.executionCursor : null,
              contextJson: {
                for (final e in refreshedRun.contextJson.entries)
                  if (e.key.startsWith('_') && !e.key.startsWith('_map.current')) e.key: e.value,
                ...context.toJson(),
              },
              updatedAt: DateTime.now(),
            );
            await _persistContext(run.id, context);
            await _repository.update(run);
            await _failRun(run, msg);
            return;
          }
          run = run.copyWith(
            totalTokens: run.totalTokens + mapResult.totalTokens,
            currentStepIndex: stepIndex + 1,
            executionCursor: null,
            contextJson: {
              for (final e in run.contextJson.entries)
                if (e.key.startsWith('_') && !e.key.startsWith('_map.current')) e.key: e.value,
              ...context.toJson(),
            },
            updatedAt: DateTime.now(),
          );
          await _persistContext(run.id, context);
          await _repository.update(run);
          _eventBus.fire(
            WorkflowStepCompletedEvent(
              runId: run.id,
              stepId: step.id,
              stepName: step.name,
              stepIndex: stepIndex,
              totalSteps: totalSteps,
              taskId: '',
              success: true,
              tokenCount: mapResult.totalTokens,
              timestamp: DateTime.now(),
            ),
          );
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
            _log.info(
              "Workflow '${run.id}': resuming parallel group — "
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
          for (final groupStep in group) {
            if (groupStep.gate != null) {
              final gatePasses = _gateEvaluator.evaluate(groupStep.gate!, context);
              if (!gatePasses) {
                final msg = "Gate failed for parallel step '${groupStep.name}': ${groupStep.gate}";
                _log.info("Workflow '${run.id}': $msg");
                await _failRun(run, msg);
                return;
              }
            }
          }
          final refreshedRun = await _repository.getById(run.id) ?? run;
          run = refreshedRun;
          run = await _checkWorkflowBudgetWarning(run, definition);
          if (_workflowBudgetExceeded(run, definition)) {
            final msg = 'Workflow budget exceeded: ${run.totalTokens} / ${definition.maxTokens} tokens';
            _log.info("Workflow '${run.id}': $msg");
            await _failRun(run, msg);
            return;
          }
          run = run.copyWith(
            contextJson: {...run.contextJson, '_parallel.current.stepIds': fullGroupStepIds},
            updatedAt: DateTime.now(),
          );
          await _repository.update(run);
          final results = await _executeParallelGroup(run, definition, group, context);
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
              _eventBus.fire(
                WorkflowStepCompletedEvent(
                  runId: run.id,
                  stepId: result.step.id,
                  stepName: result.step.name,
                  stepIndex: si,
                  totalSteps: totalSteps,
                  taskId: result.task?.id ?? '',
                  displayScope: _displayScopeForTask(result.task),
                  success: result.success,
                  tokenCount: result.tokenCount,
                  timestamp: DateTime.now(),
                ),
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
            if (refreshedRun.status == WorkflowRunStatus.paused || refreshedRun.status == WorkflowRunStatus.cancelled) {
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
            _log.info("Workflow '${run.id}': $msg");
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
                  artifactCommitResult.failureReason ?? "Artifact commit failed for parallel step '${result.step.id}'";
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
          final refreshedRunForeach = await _repository.getById(run.id) ?? run;
          run = refreshedRunForeach;
          run = await _checkWorkflowBudgetWarning(run, definition);
          if (_workflowBudgetExceeded(run, definition)) {
            final msg = 'Workflow budget exceeded: ${run.totalTokens} / ${definition.maxTokens} tokens';
            _log.info("Workflow '${run.id}': $msg");
            await _failRun(run, msg);
            return;
          }
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
            stepById: stepById,
            stepIndex: foreachStepIndex,
            resumeCursor: foreachCursor,
          );
          if (foreachResult == null) return;
          activeCursor = null;
          for (final outputKey in foreachStep.outputKeys) {
            context[outputKey] = foreachResult.results;
          }
          if (!foreachResult.success) {
            final msg = foreachResult.error ?? "Foreach step '${foreachStep.id}' failed";
            _log.info("Workflow '${run.id}': $msg");
            context['${foreachStep.id}.status'] = 'failed';
            context['step.${foreachStep.id}.outcome'] = 'failed';
            context['step.${foreachStep.id}.outcome.reason'] = msg;
            final refreshedRun = await _repository.getById(run.id) ?? run;
            final keepCursor =
                foreachResult.error?.startsWith('promotion-conflict') == true ||
                foreachResult.results.any((result) => result == null);
            final hasCompleteItemResults =
                foreachResult.results.isNotEmpty && !foreachResult.results.any((result) => result == null);
            final isControllerFailure = foreachResult.error?.startsWith('foreach-controller-failure:') == true;
            final isPromotionFailure = foreachResult.error?.startsWith('promotion-') == true;
            final continueAfterFailure =
                foreachStep.onFailure == OnFailurePolicy.continueWorkflow &&
                hasCompleteItemResults &&
                !isControllerFailure &&
                !isPromotionFailure;
            run = refreshedRun.copyWith(
              totalTokens: refreshedRun.totalTokens + foreachResult.totalTokens,
              currentStepIndex: continueAfterFailure ? foreachStepIndex + 1 : refreshedRun.currentStepIndex,
              executionCursor: continueAfterFailure
                  ? null
                  : keepCursor
                  ? refreshedRun.executionCursor
                  : null,
              contextJson: {
                for (final e in refreshedRun.contextJson.entries)
                  if (e.key.startsWith('_') && !e.key.startsWith('_foreach.current')) e.key: e.value,
                ...context.toJson(),
              },
              updatedAt: DateTime.now(),
            );
            await _persistContext(run.id, context);
            await _repository.update(run);
            _eventBus.fire(
              WorkflowStepCompletedEvent(
                runId: run.id,
                stepId: foreachStep.id,
                stepName: foreachStep.name,
                stepIndex: foreachStepIndex,
                totalSteps: totalSteps,
                taskId: '',
                success: false,
                tokenCount: foreachResult.totalTokens,
                timestamp: DateTime.now(),
              ),
            );
            if (continueAfterFailure) {
              nodeIndex++;
              continue;
            }
            await _failRun(run, msg);
            return;
          }
          run = run.copyWith(
            totalTokens: run.totalTokens + foreachResult.totalTokens,
            currentStepIndex: foreachStepIndex + 1,
            executionCursor: null,
            contextJson: {
              for (final e in run.contextJson.entries)
                if (e.key.startsWith('_') && !e.key.startsWith('_foreach.current')) e.key: e.value,
              ...context.toJson(),
            },
            updatedAt: DateTime.now(),
          );
          await _persistContext(run.id, context);
          await _repository.update(run);
          _eventBus.fire(
            WorkflowStepCompletedEvent(
              runId: run.id,
              stepId: foreachStep.id,
              stepName: foreachStep.name,
              stepIndex: foreachStepIndex,
              totalSteps: totalSteps,
              taskId: '',
              success: true,
              tokenCount: foreachResult.totalTokens,
              timestamp: DateTime.now(),
            ),
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
          if (step.gate != null) {
            final gatePasses = _gateEvaluator.evaluate(step.gate!, context);
            if (!gatePasses) {
              final msg = "Gate failed for step '${step.name}': ${step.gate}";
              _log.info("Workflow '${run.id}': $msg");
              await _failRun(run, msg);
              return;
            }
          }
          final refreshedRun = await _repository.getById(run.id) ?? run;
          run = refreshedRun;
          run = await _checkWorkflowBudgetWarning(run, definition);
          if (_workflowBudgetExceeded(run, definition)) {
            final msg = 'Workflow budget exceeded: ${run.totalTokens} / ${definition.maxTokens} tokens';
            _log.info("Workflow '${run.id}': $msg");
            await _failRun(run, msg);
            return;
          }
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
            _log.info("Workflow '${run.id}': $msg");
            if (step.onError == 'continue') {
              _mergeStepResultIntoContext(context, result, fallbackStatus: 'failed');
              run = run.copyWith(
                totalTokens: run.totalTokens + result.tokenCount,
                currentStepIndex: stepIndex + 1,
                contextJson: {
                  for (final e in run.contextJson.entries)
                    if (e.key.startsWith('_')) e.key: e.value,
                  ...context.toJson(),
                },
                updatedAt: DateTime.now(),
              );
              await _persistContext(run.id, context);
              await _repository.update(run);
              _eventBus.fire(
                WorkflowStepCompletedEvent(
                  runId: run.id,
                  stepId: step.id,
                  stepName: step.name,
                  stepIndex: stepIndex,
                  totalSteps: totalSteps,
                  taskId: result.task?.id ?? '',
                  displayScope: _displayScopeForTask(result.task),
                  success: false,
                  tokenCount: result.tokenCount,
                  timestamp: DateTime.now(),
                ),
              );
              nodeIndex++;
              continue;
            }
            _mergeStepResultIntoContext(context, result, fallbackStatus: 'failed');
            run = run.copyWith(
              totalTokens: run.totalTokens + result.tokenCount,
              contextJson: {
                for (final e in run.contextJson.entries)
                  if (e.key.startsWith('_')) e.key: e.value,
                ...context.toJson(),
              },
              updatedAt: DateTime.now(),
            );
            await _persistContext(run.id, context);
            await _repository.update(run);
            _eventBus.fire(
              WorkflowStepCompletedEvent(
                runId: run.id,
                stepId: step.id,
                stepName: step.name,
                stepIndex: stepIndex,
                totalSteps: totalSteps,
                taskId: result.task?.id ?? '',
                displayScope: _displayScopeForTask(result.task),
                success: false,
                tokenCount: result.tokenCount,
                timestamp: DateTime.now(),
              ),
            );
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
              contextJson: {
                for (final e in run.contextJson.entries)
                  if (e.key.startsWith('_')) e.key: e.value,
                ...context.toJson(),
              },
              updatedAt: DateTime.now(),
            );
            await _persistContext(run.id, context);
            await _repository.update(run);
            _eventBus.fire(
              WorkflowStepCompletedEvent(
                runId: run.id,
                stepId: step.id,
                stepName: step.name,
                stepIndex: stepIndex,
                totalSteps: totalSteps,
                taskId: result.task?.id ?? '',
                displayScope: _displayScopeForTask(result.task),
                success: false,
                tokenCount: result.tokenCount,
                timestamp: DateTime.now(),
              ),
            );
            await _failRun(run, msg);
            return;
          }
          run = run.copyWith(
            totalTokens: run.totalTokens + result.tokenCount,
            currentStepIndex: stepIndex + 1,
            contextJson: {
              for (final e in run.contextJson.entries)
                if (e.key.startsWith('_')) e.key: e.value,
              ...context.toJson(),
            },
            updatedAt: DateTime.now(),
          );
          await _persistContext(run.id, context);
          await _repository.update(run);
          _eventBus.fire(
            WorkflowStepCompletedEvent(
              runId: run.id,
              stepId: step.id,
              stepName: step.name,
              stepIndex: stepIndex,
              totalSteps: totalSteps,
              taskId: result.task?.id ?? '',
              displayScope: _displayScopeForTask(result.task),
              success: true,
              tokenCount: result.tokenCount,
              timestamp: DateTime.now(),
            ),
          );
          nodeIndex++;
      }
    }
    await _completeRun(run, definition, context);
  }

  Future<void> _cancelRun(WorkflowRun run, String reason) async {
    final cancelled = run.copyWith(
      status: WorkflowRunStatus.cancelled,
      completedAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    await _repository.update(cancelled);
    _eventBus.fire(
      WorkflowRunStatusChangedEvent(
        runId: run.id,
        definitionName: run.definitionName,
        oldStatus: run.status,
        newStatus: WorkflowRunStatus.cancelled,
        errorMessage: reason,
        timestamp: DateTime.now(),
      ),
    );
    final allTasks = await _taskService.list();
    for (final task in allTasks) {
      if (task.workflowRunId == run.id && (task.status == TaskStatus.queued || task.status == TaskStatus.running)) {
        try {
          await _taskService.transition(task.id, TaskStatus.cancelled, trigger: 'approval-timeout');
        } on StateError {
          // Already transitioned concurrently.
        } catch (e) {
          _log.warning('Failed to cancel task ${task.id} on approval timeout: $e');
        }
      }
    }
    await _cleanupWorkflowGit(cancelled, preserveWorktrees: !_cleanupEnabledForRun(cancelled));
  }

  Future<void> _failRun(WorkflowRun run, String reason, {bool cleanupWorkflowGit = true}) async {
    final failed = run.copyWith(status: WorkflowRunStatus.failed, errorMessage: reason, updatedAt: DateTime.now());
    await _repository.update(failed);
    _eventBus.fire(
      WorkflowRunStatusChangedEvent(
        runId: run.id,
        definitionName: run.definitionName,
        oldStatus: run.status,
        newStatus: WorkflowRunStatus.failed,
        errorMessage: reason,
        timestamp: DateTime.now(),
      ),
    );
    if (cleanupWorkflowGit) {
      await _cleanupWorkflowGit(failed, preserveWorktrees: !_cleanupEnabledForRun(failed));
    }
  }

  Future<void> _completeRun(WorkflowRun run, WorkflowDefinition definition, WorkflowContext context) async {
    final publishStrategy = definition.gitStrategy?.publish;
    if (publishStrategy?.enabled == true) {
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
    _eventBus.fire(
      WorkflowRunStatusChangedEvent(
        runId: run.id,
        definitionName: run.definitionName,
        oldStatus: run.status,
        newStatus: WorkflowRunStatus.completed,
        timestamp: DateTime.now(),
      ),
    );
    final cleanupEnabled = definition.gitStrategy?.cleanupEnabled ?? true;
    await _cleanupWorkflowGit(completed, preserveWorktrees: !cleanupEnabled);
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

  bool _cleanupEnabledForRun(WorkflowRun run) {
    try {
      final definition = WorkflowDefinition.fromJson(run.definitionJson);
      return definition.gitStrategy?.cleanupEnabled ?? true;
    } catch (e, st) {
      _log.warning("Workflow '${run.id}': failed to resolve cleanup config; preserving worktrees", e, st);
      return false;
    }
  }
}
