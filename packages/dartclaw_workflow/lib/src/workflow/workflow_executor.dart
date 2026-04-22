import 'dart:async' show Completer, FutureOr, StreamSubscription, TimeoutException, Timer;
import 'dart:collection' show Queue;
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        ActionNode,
        AgentExecution,
        AgentExecutionRepository,
        EventBus,
        ExecutionRepositoryTransactor,
        KvService,
        LoopNode,
        LoopIterationCompletedEvent,
        ForeachNode,
        HarnessFactory,
        MapNode,
        MapIterationCompletedEvent,
        MapStepCompletedEvent,
        MessageService,
        OutputConfig,
        OutputFormat,
        WorkflowExecutionCursor,
        WorkflowExecutionCursorNodeType,
        ParallelGroupNode,
        ParallelGroupCompletedEvent,
        StepSkippedEvent,
        Task,
        TaskRepository,
        TaskStatus,
        TaskStatusChangedEvent,
        TaskType,
        WorkflowApprovalRequestedEvent,
        WorkflowBudgetWarningEvent,
        WorkflowDefinition,
        WorkflowGitArtifactsStrategy,
        WorkflowGitStrategy,
        WorkflowNode,
        WorkflowLoop,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowRunStatusChangedEvent,
        WorkflowStep,
        WorkflowStepCompletedEvent,
        WorkflowStepExecution,
        WorkflowStepExecutionRepository,
        WorkflowTaskService,
        atomicWriteJson;
import 'package:dartclaw_config/dartclaw_config.dart' show ProviderIdentity;
import 'package:dartclaw_models/dartclaw_models.dart' show OnFailurePolicy;
import 'package:dartclaw_security/dartclaw_security.dart'
    show EnvPolicy, ProcessEnvironmentPlan, SafeProcess, kDefaultSensitivePatterns;
import 'package:dartclaw_storage/dartclaw_storage.dart' show SqliteWorkflowRunRepository;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'context_extractor.dart';
import 'dependency_graph.dart';
import 'gate_evaluator.dart';
import 'json_extraction.dart';
import 'map_context.dart';
import 'map_step_context.dart';
import 'prompt_augmenter.dart';
import 'schema_presets.dart';
import 'shell_escape.dart';
import 'skill_prompt_builder.dart';
import 'skill_registry.dart';
import 'step_config_resolver.dart';
import 'built_in_workflow_workspace.dart';
import 'workflow_context.dart';
import 'workflow_template_engine.dart';
import 'workflow_task_config.dart';
import 'workflow_turn_adapter.dart';

typedef WorkflowStepOutputTransformer =
    FutureOr<Map<String, dynamic>> Function(
      WorkflowRun run,
      WorkflowDefinition definition,
      WorkflowStep step,
      Task task,
      Map<String, dynamic> outputs,
    );

/// Result of a single step within a parallel group.
class _ParallelStepResult {
  final WorkflowStep step;
  final Task? task;
  final Map<String, dynamic> outputs;
  final int tokenCount;
  final bool success;
  final String? error;
  final String? outcome;
  final String? outcomeReason;
  final bool awaitingApproval;

  const _ParallelStepResult({
    required this.step,
    this.task,
    this.outputs = const {},
    this.tokenCount = 0,
    required this.success,
    this.error,
    this.outcome,
    this.outcomeReason,
    this.awaitingApproval = false,
  });
}

/// Result of a map/fan-out step execution.
class _MapStepResult {
  /// Index-ordered result array (one slot per collection item).
  final List<dynamic> results;

  /// Total tokens consumed across all iterations.
  final int totalTokens;

  /// Whether all iterations succeeded.
  final bool success;

  /// Error message if any iteration failed or the step itself failed.
  final String? error;

  const _MapStepResult({required this.results, required this.totalTokens, required this.success, this.error});
}

final class _EmptyProcessEnvironmentPlan implements ProcessEnvironmentPlan {
  @override
  final Map<String, String> environment;

  const _EmptyProcessEnvironmentPlan() : environment = const <String, String>{};
}

/// Sequential + parallel + iterative workflow execution engine.
///
/// Traverses the normalized node graph in authored order. Parallel groups use
/// [Future.wait], map nodes preserve indexed fan-out semantics, and loop nodes
/// keep iteration state local to the authored control structure.
class WorkflowExecutor {
  static final _log = Logger('WorkflowExecutor');

  final WorkflowTaskService _taskService;
  final EventBus _eventBus;
  final KvService _kvService;
  final SqliteWorkflowRunRepository _repository;
  final GateEvaluator _gateEvaluator;
  final ContextExtractor _contextExtractor;
  final WorkflowTemplateEngine _templateEngine;
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
  String? _workflowWorkspaceDirCache;

  // Approval timeout timers keyed by "<runId>:<stepId>".
  final _approvalTimers = <String, Timer>{};

  // Per-definition cache of input-config lookups used by
  // `SkillPromptBuilder.formatContextSummary`. Foreach loops over many
  // iterations would otherwise repeat identical scans.
  //
  // Stored on an Expando so entries are GC'd together with the
  // definition — hot-reloaded definitions don't leak. The inner map is
  // keyed on a null-separated join of the contextInputs list, which is
  // equality-safe (plain `String` key, no hash collisions across
  // distinct lists).
  final _inputConfigCache = Expando<Map<String, Map<String, OutputConfig>>>('workflowInputConfigCache');

  Map<String, OutputConfig> _inputConfigsFor(WorkflowDefinition definition, List<String> keys) {
    if (keys.isEmpty) return const {};
    final perDefinition = _inputConfigCache[definition] ??= <String, Map<String, OutputConfig>>{};
    final cacheKey = keys.join('\x00');
    return perDefinition.putIfAbsent(cacheKey, () => SkillPromptBuilder.collectInputConfigs(definition.steps, keys));
  }

  /// Returns the `workflow.default_prompt` declared in the step's skill
  /// frontmatter, or null when no registry is wired, the step has no skill,
  /// or the skill declares no default.
  String? _skillDefaultPromptFor(WorkflowStep step) {
    final skill = step.skill;
    if (skill == null) return null;
    return _skillRegistry?.getByName(skill)?.defaultPrompt;
  }

  /// Returns the effective `outputs:` for a step, shallow-merging the skill's
  /// `workflow.default_outputs` (keys only in the skill default are added;
  /// keys on the step win).
  Map<String, OutputConfig>? _effectiveOutputsFor(WorkflowStep step) {
    final explicit = step.outputs;
    final skill = step.skill;
    if (skill == null || _skillRegistry == null) return explicit;
    final defaults = _skillRegistry.getByName(skill)?.defaultOutputs;
    if (defaults == null || defaults.isEmpty) return explicit;
    if (explicit == null || explicit.isEmpty) return defaults;
    return {...defaults, ...explicit};
  }

  /// Resolved values for a step's contextInputs plus workflow variables used
  /// by auto-framing.
  ///
  /// Context inputs render missing entries as `''` so the auto-frame pass can
  /// drop an `_(empty)_` placeholder per the shared convention. Workflow
  /// variables only participate when they have a bound or default value —
  /// null-valued variables are intentionally omitted so they do not render as
  /// `_(empty)_`.
  Map<String, Object?> _resolvedInputValuesFor(
    WorkflowStep step,
    WorkflowDefinition definition,
    WorkflowContext context,
  ) {
    final values = <String, Object?>{for (final key in step.contextInputs) key: context[key] ?? ''};
    for (final entry in definition.variables.entries) {
      if (values.containsKey(entry.key)) continue;
      final resolved = context.variable(entry.key) ?? entry.value.defaultValue;
      if (resolved != null) values[entry.key] = resolved;
    }
    return values;
  }

  // Workflow-level `variables` are opt-in per step. Only names listed in
  // `step.workflowVariables` are auto-framed as `<NAME>{value}</NAME>` blocks
  // on that step's prompt. Undeclared variables never reach unrelated steps
  // (e.g. REQUIREMENTS must not land on discover-project). `contextInputs`
  // remains the declarative channel for upstream step outputs and is still
  // auto-framed by SkillPromptBuilder when `autoFrameContext` is true.
  List<String> _autoFrameVariableNames(WorkflowStep step) => step.workflowVariables;

  /// Fallback git identity for auto-commit in environments without a
  /// configured `user.name` / `user.email`. Applied only to the artifact-commit
  /// hook; does not affect user-authored commits.
  static const _artifactCommitAuthorName = 'DartClaw Workflow';
  static const _artifactCommitAuthorEmail = 'workflow@dartclaw.local';

  /// Skills whose outputs are considered artifact files on disk.
  static const _artifactProducingSkills = <String>{
    'dartclaw-prd',
    'dartclaw-plan',
    'dartclaw-spec',
    'dartclaw-remediate-findings',
  };

  /// True when a workflow contains at least one artifact-producing step —
  /// controls the default value of `gitStrategy.artifacts.commit`.
  bool _workflowHasArtifactProducer(WorkflowDefinition definition) {
    for (final step in definition.steps) {
      if (step.skill != null && _artifactProducingSkills.contains(step.skill)) return true;
      final outputs = step.outputs;
      if (outputs == null) continue;
      for (final cfg in outputs.values) {
        if (cfg.format == OutputFormat.path) return true;
      }
    }
    return false;
  }

  /// Resolves the effective workflow-branch target directory for artifact
  /// commits. Falls back in this order: `gitStrategy.artifacts.project` →
  /// `step.project` → workflow-level `{{PROJECT}}` variable → null.
  ///
  /// Project directories are resolved by the standard DartClaw convention:
  /// `<dataDir>/projects/<projectId>/`. Returns a `(projectId, dir, exists)`
  /// triple so callers can log the resolved path even when the directory is
  /// missing — makes misconfigured `artifacts.project` templates debuggable.
  _ResolvedArtifactProject? _resolveArtifactCommitProject(
    WorkflowDefinition definition,
    WorkflowStep step,
    WorkflowContext context,
    WorkflowGitArtifactsStrategy strategy,
  ) {
    final projectId =
        _resolveProjectTemplate(strategy.project, context) ??
        _resolveProjectTemplate(step.project, context) ??
        _resolveProjectTemplate(definition.project, context);
    if (projectId == null) return null;
    final dir = p.join(_dataDir, 'projects', projectId);
    return _ResolvedArtifactProject(projectId: projectId, dir: dir, exists: Directory(dir).existsSync());
  }

  /// Commits any artifact-path outputs the just-completed [step] produced to
  /// the workflow branch in the configured project's working tree, so that
  /// later per-map-item worktrees branching from the workflow branch inherit
  /// them.
  ///
  /// Silent no-op when:
  /// - `gitStrategy.artifacts.commit` effectively resolves to false;
  /// - the step's contextOutputs contain no path-shaped values;
  /// - no staged changes exist after `git add` (files were already committed).
  ///
  /// Failures are logged and swallowed — artifact commit is advisory for the
  /// workflow; downstream worktrees may still see the files via the workspace
  /// if using shared-mode worktrees.
  Future<void> _maybeCommitArtifacts({
    required WorkflowRun run,
    required WorkflowDefinition definition,
    required WorkflowStep step,
    required WorkflowContext context,
    required Task task,
  }) async {
    final artifacts = definition.gitStrategy?.artifacts;
    final hasProducer = _workflowHasArtifactProducer(definition);
    final shouldCommit = artifacts?.commit ?? hasProducer;
    if (!shouldCommit) return;
    if (artifacts == null && !hasProducer) return;

    // Collect produced artifact paths from this step's context outputs.
    final outputs = step.outputs;
    if (outputs == null) return;
    final producedPaths = <String>[];
    for (final outKey in step.contextOutputs) {
      final cfg = outputs[outKey];
      if (cfg == null || cfg.format != OutputFormat.path) continue;
      final value = context[outKey]?.toString().trim() ?? '';
      if (value.isEmpty || value == 'null') continue;
      producedPaths.add(value);
    }
    if (producedPaths.isEmpty) return;

    // Resolve the project working directory for the commit.
    final resolved = _resolveArtifactCommitProject(
      definition,
      step,
      context,
      artifacts ?? const WorkflowGitArtifactsStrategy(),
    );
    if (resolved == null) {
      _log.warning(
        "artifact-commit: step '${step.id}' produced paths but no project id "
        'could be resolved (checked gitStrategy.artifacts.project, step.project, '
        'and the {{PROJECT}} workflow variable)',
      );
      return;
    }
    if (!resolved.exists) {
      _log.warning(
        "artifact-commit: step '${step.id}' resolved project '${resolved.projectId}' "
        "but directory '${resolved.dir}' does not exist — skipping commit",
      );
      return;
    }
    final worktreeDir = (task.worktreeJson?['path'] as String?)?.trim();
    final projectDir = (worktreeDir != null && worktreeDir.isNotEmpty) ? worktreeDir : resolved.dir;

    final messageTemplate = artifacts?.commitMessage ?? 'chore(workflow): artifacts for run {{runId}}';
    final resolvedMessage = _templateEngine.resolve(messageTemplate.replaceAll('{{runId}}', run.id), context).trim();
    final commitMessage = resolvedMessage.isEmpty ? 'chore(workflow): artifacts for run ${run.id}' : resolvedMessage;

    try {
      final addResult = await SafeProcess.git(
        ['add', '--', ...producedPaths],
        plan: const _EmptyProcessEnvironmentPlan(),
        workingDirectory: projectDir,
        noSystemConfig: true,
      );
      if (addResult.exitCode != 0) {
        _log.warning("artifact-commit: git add failed in '$projectDir': ${addResult.stderr}");
        return;
      }
      final stagedResult = await SafeProcess.git(
        ['diff', '--cached', '--name-only'],
        plan: const _EmptyProcessEnvironmentPlan(),
        workingDirectory: projectDir,
        noSystemConfig: true,
      );
      final staged = (stagedResult.stdout as String).trim();
      if (staged.isEmpty) {
        _log.info("artifact-commit: no staged changes in '$projectDir' after step '${step.id}' — skipping commit");
        return;
      }
      final commitResult = await SafeProcess.git(
        [
          '-c',
          'user.name=$_artifactCommitAuthorName',
          '-c',
          'user.email=$_artifactCommitAuthorEmail',
          'commit',
          '-m',
          commitMessage,
        ],
        plan: const _EmptyProcessEnvironmentPlan(),
        workingDirectory: projectDir,
        noSystemConfig: true,
      );
      if (commitResult.exitCode != 0) {
        _log.warning("artifact-commit: git commit failed in '$projectDir': ${commitResult.stderr}");
        return;
      }
      _log.info(
        "artifact-commit: committed ${producedPaths.length} file(s) in '$projectDir' "
        "after step '${step.id}' with message '$commitMessage'",
      );
    } catch (e) {
      _log.warning("artifact-commit: unexpected error for step '${step.id}' in '$projectDir': $e");
    }
  }

  /// Returns `true` when [step].entryGate is set and evaluates false — the
  /// caller should skip the step (advance cursor, do not pause). Fires a
  /// [StepSkippedEvent] as a side effect. Unlike [WorkflowStep.gate], entryGate
  /// does not pause the run on false; it is a clean skip.
  bool _shouldSkipDueToEntryGate(WorkflowStep step, WorkflowContext context, String runId) {
    final expr = step.entryGate;
    if (expr == null || expr.trim().isEmpty) return false;
    final passes = _gateEvaluator.evaluate(expr, context);
    if (passes) return false;
    _log.info("Workflow '$runId': step '${step.id}' skipped: entryGate='$expr' evaluated false");
    _eventBus.fire(StepSkippedEvent(runId: runId, stepId: step.id, reason: expr, timestamp: DateTime.now()));
    return true;
  }

  WorkflowExecutor({
    required WorkflowTaskService taskService,
    required EventBus eventBus,
    required KvService kvService,
    required SqliteWorkflowRunRepository repository,
    required GateEvaluator gateEvaluator,
    required ContextExtractor contextExtractor,
    required String dataDir,
    WorkflowTemplateEngine? templateEngine,
    PromptAugmenter? promptAugmenter,
    SkillPromptBuilder? skillPromptBuilder,
    HarnessFactory? harnessFactory,
    MessageService? messageService,
    WorkflowTurnAdapter? turnAdapter,
    WorkflowStepOutputTransformer? outputTransformer,
    WorkflowRoleDefaults? roleDefaults,
    SkillRegistry? skillRegistry,
    TaskRepository? taskRepository,
    AgentExecutionRepository? agentExecutionRepository,
    WorkflowStepExecutionRepository? workflowStepExecutionRepository,
    ExecutionRepositoryTransactor? executionTransactor,
    Map<String, String>? hostEnvironment,
    List<String>? bashStepEnvAllowlist,
    List<String>? bashStepExtraStripPatterns,
    Uuid? uuid,
  }) : _taskService = taskService,
       _eventBus = eventBus,
       _kvService = kvService,
       _repository = repository,
       _gateEvaluator = gateEvaluator,
       _contextExtractor = contextExtractor,
       _templateEngine = templateEngine ?? WorkflowTemplateEngine(),
       _skillPromptBuilder =
           skillPromptBuilder ??
           SkillPromptBuilder(
             augmenter: promptAugmenter ?? const PromptAugmenter(),
             harnessFactory: (harnessFactory ?? HarnessFactory())..warnIfEmpty(context: 'WorkflowExecutor'),
           ),
       _turnAdapter = turnAdapter,
       _outputTransformer = outputTransformer,
       _skillRegistry = skillRegistry,
       _taskRepository = taskRepository,
       _agentExecutionRepository = agentExecutionRepository,
       _workflowStepExecutionRepository = workflowStepExecutionRepository,
       _executionTransactor = executionTransactor,
       _dataDir = dataDir,
       _roleDefaults = roleDefaults ?? const WorkflowRoleDefaults(),
       _hostEnvironment = hostEnvironment,
       _bashStepEnvAllowlist = List.unmodifiable(
         bashStepEnvAllowlist ??
             const <String>['PATH', 'HOME', 'LANG', 'LC_*', 'TZ', 'USER', 'SHELL', 'TERM', 'TMPDIR', 'TMP', 'TEMP'],
       ),
       _bashStepExtraStripPatterns = List.unmodifiable(bashStepExtraStripPatterns ?? const <String>[]),
       _uuid = uuid ?? const Uuid();

  /// Executes a workflow run in authored order over normalized steps/loops.
  ///
  /// Called for both fresh starts (startFromStepIndex=0) and crash recovery.
  /// Runs until completion, pause, failure, or cancellation.
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

      // Check cancellation between steps.
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

          if (_shouldSkipDueToEntryGate(step, context, run.id)) {
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

          for (final outputKey in step.contextOutputs) {
            context[outputKey] = mapResult.results;
          }

          if (!mapResult.success) {
            final msg = mapResult.error ?? "Map step '${step.id}' failed";
            _log.info("Workflow '${run.id}': $msg");
            run = run.copyWith(
              totalTokens: run.totalTokens + mapResult.totalTokens,
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

          // Drop any parallel-group steps whose entryGate evaluates false.
          // They are skipped individually; the rest of the group proceeds.
          group = [
            for (final groupStep in group)
              if (!_shouldSkipDueToEntryGate(groupStep, context, run.id)) groupStep,
          ];
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
          _mergeParallelResults(results, context);
          run = _updateParallelBudget(run, results);
          await _persistContext(run.id, context);

          for (final result in results) {
            final si = stepIndexById[result.step.id] ?? groupStartStepIndex;
            _eventBus.fire(
              WorkflowStepCompletedEvent(
                runId: run.id,
                stepId: result.step.id,
                stepName: result.step.name,
                stepIndex: si,
                totalSteps: totalSteps,
                taskId: result.task?.id ?? '',
                success: result.success,
                tokenCount: result.tokenCount,
                timestamp: DateTime.now(),
              ),
            );
          }

          final failedSteps = results.where((result) => !result.success).toList();
          _eventBus.fire(
            ParallelGroupCompletedEvent(
              runId: run.id,
              stepIds: group.map((step) => step.id).toList(),
              successCount: results.length - failedSteps.length,
              failureCount: failedSteps.length,
              totalTokens: results.fold(0, (sum, result) => sum + result.tokenCount),
              timestamp: DateTime.now(),
            ),
          );

          if (failedSteps.isNotEmpty) {
            run = run.copyWith(
              currentStepIndex: groupStartStepIndex,
              contextJson: {
                ...run.contextJson,
                '_parallel.current.stepIds': fullGroupStepIds,
                '_parallel.failed.stepIds': failedSteps.map((result) => result.step.id).toList(),
              },
              updatedAt: DateTime.now(),
            );
            await _repository.update(run);

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

          run = run.copyWith(
            currentStepIndex: groupStartStepIndex + fullGroup.length,
            contextJson: {
              for (final e in run.contextJson.entries)
                if (e.key != '_parallel.current.stepIds' && e.key != '_parallel.failed.stepIds') e.key: e.value,
              ...context.toJson(),
            },
            updatedAt: DateTime.now(),
          );
          await _repository.update(run);
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

          // Write aggregated per-item results to context for downstream steps that reference
          // {{context.story-pipeline}} or any declared contextOutputs on the foreach controller.
          for (final outputKey in foreachStep.contextOutputs) {
            context[outputKey] = foreachResult.results;
          }

          if (!foreachResult.success) {
            final msg = foreachResult.error ?? "Foreach step '${foreachStep.id}' failed";
            _log.info("Workflow '${run.id}': $msg");
            run = run.copyWith(
              totalTokens: run.totalTokens + foreachResult.totalTokens,
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

          if (_shouldSkipDueToEntryGate(step, context, run.id)) {
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
              success: true,
              tokenCount: result.tokenCount,
              timestamp: DateTime.now(),
            ),
          );

          if (result.task != null) {
            await _maybeCommitArtifacts(
              run: run,
              definition: definition,
              step: step,
              context: context,
              task: result.task!,
            );
          }

          nodeIndex++;
      }
    }

    // All nodes completed.
    await _completeRun(run, definition, context);
  }

  // ── Parallel group helpers ──────────────────────────────────────────────────

  int _nodeIndexForStepIndex(List<WorkflowNode> nodes, Map<String, int> stepIndexById, int stepIndex) {
    if (nodes.isEmpty) return 0;
    for (var index = 0; index < nodes.length; index++) {
      final referencedIndexes = _referencedStepIdsForNode(
        nodes[index],
      ).map((stepId) => stepIndexById[stepId]).nonNulls.toList(growable: false);
      if (referencedIndexes.contains(stepIndex)) {
        return index;
      }
      final firstStepIndex = referencedIndexes.isEmpty
          ? 0
          : referencedIndexes.reduce((left, right) => left < right ? left : right);
      if (firstStepIndex >= stepIndex) {
        return index;
      }
    }
    return nodes.length;
  }

  int _nodeIndexForCursor(List<WorkflowNode> nodes, Map<String, int> stepIndexById, WorkflowExecutionCursor cursor) =>
      _nodeIndexForStepIndex(nodes, stepIndexById, cursor.stepIndex);

  WorkflowExecutionCursor? _legacyResumeCursor(
    WorkflowDefinition definition, {
    int? startFromLoopIndex,
    int? startFromLoopIteration,
    String? startFromLoopStepId,
  }) {
    if (startFromLoopIndex == null || startFromLoopIndex < 0 || startFromLoopIndex >= definition.loops.length) {
      return null;
    }
    final loop = definition.loops[startFromLoopIndex];
    final firstStepId = startFromLoopStepId ?? loop.steps.firstOrNull;
    final stepIndex = firstStepId == null ? 0 : definition.steps.indexWhere((step) => step.id == firstStepId);
    return WorkflowExecutionCursor.loop(
      loopId: loop.id,
      stepIndex: stepIndex >= 0 ? stepIndex : 0,
      iteration: startFromLoopIteration ?? 1,
      stepId: startFromLoopStepId,
    );
  }

  int _firstStepIndexForNode(WorkflowNode node, Map<String, int> stepIndexById) {
    final indexes = _referencedStepIdsForNode(
      node,
    ).map((stepId) => stepIndexById[stepId]).nonNulls.toList(growable: false);
    if (indexes.isEmpty) return 0;
    return indexes.reduce((left, right) => left < right ? left : right);
  }

  Iterable<String> _referencedStepIdsForNode(WorkflowNode node) sync* {
    switch (node) {
      case ActionNode(stepId: final stepId):
        yield stepId;
      case MapNode(stepId: final stepId):
        yield stepId;
      case ParallelGroupNode(stepIds: final stepIds):
        yield* stepIds;
      case LoopNode(stepIds: final stepIds, finallyStepId: final finallyStepId):
        yield* stepIds;
        if (finallyStepId != null) {
          yield finallyStepId;
        }
      case ForeachNode(stepId: final stepId, childStepIds: final childStepIds):
        yield stepId;
        yield* childStepIds;
    }
  }

  /// Executes all steps in a parallel group concurrently via [Future.wait].
  ///
  /// Uses the same per-step dispatcher as sequential execution so hybrid step
  /// semantics stay consistent across both code paths.
  Future<List<_ParallelStepResult>> _executeParallelGroup(
    WorkflowRun run,
    WorkflowDefinition definition,
    List<WorkflowStep> group,
    WorkflowContext context,
  ) async {
    final futures = group.map((step) async {
      try {
        final stepIndex = definition.steps.indexOf(step);
        final result = await _executeStep(run, definition, step, context, stepIndex: stepIndex);
        if (result == null) {
          return _ParallelStepResult(
            step: step,
            outputs: const {},
            tokenCount: 0,
            success: false,
            error: 'step did not complete',
          );
        }
        return result;
      } catch (e, st) {
        _log.severe("Parallel step '${step.name}' failed: $e", e, st);
        return _ParallelStepResult(step: step, outputs: {}, tokenCount: 0, success: false, error: e.toString());
      }
    }).toList();

    return Future.wait(futures);
  }

  /// Merges parallel group results into [context] in definition order.
  ///
  /// Sets automatic metadata keys for all steps regardless of success.
  /// Successful steps' outputs are merged; failed steps are skipped.
  void _mergeParallelResults(List<_ParallelStepResult> results, WorkflowContext context) {
    for (final result in results) {
      _mergeStepResultIntoContext(
        context,
        result,
        fallbackStatus: result.success ? (result.task?.status.name ?? 'unknown') : 'failed',
      );
    }
  }

  /// Accumulates token counts from all parallel results into [run.totalTokens].
  WorkflowRun _updateParallelBudget(WorkflowRun run, List<_ParallelStepResult> results) {
    final total = results.fold(0, (sum, r) => sum + r.tokenCount);
    return run.copyWith(totalTokens: run.totalTokens + total, updatedAt: DateTime.now());
  }

  void _mergeStepResultIntoContext(WorkflowContext context, _ParallelStepResult result, {String? fallbackStatus}) {
    context.merge(result.outputs);
    final stepId = result.step.id;
    if (!result.outputs.containsKey('$stepId.status') && fallbackStatus != null) {
      context['$stepId.status'] = fallbackStatus;
    }
    if (!result.outputs.containsKey('$stepId.tokenCount')) {
      context['$stepId.tokenCount'] = result.tokenCount;
    }
    if (result.outcome != null) {
      context['step.$stepId.outcome'] = result.outcome!;
    }
    if (result.outcomeReason != null && result.outcomeReason!.isNotEmpty) {
      context['step.$stepId.outcome.reason'] = result.outcomeReason!;
    }
    final stepSessionId = result.task?.sessionId;
    if (stepSessionId != null) {
      context['$stepId.sessionId'] = stepSessionId;
    }
  }

  String? _fallbackOutcomeFromTaskStatus(TaskStatus? status) => switch (status) {
    TaskStatus.accepted => 'succeeded',
    TaskStatus.failed || TaskStatus.cancelled || TaskStatus.rejected => 'failed',
    _ => null,
  };

  Future<(String?, String?)> _resolveStepOutcome(WorkflowStep step, Task task) async {
    final parsed = await _contextExtractor.extractStepOutcome(task);
    final forcedOutcome = _fallbackOutcomeFromTaskStatus(task.status);
    if (forcedOutcome == 'failed') {
      if (parsed != null && parsed.outcome != 'failed') {
        _log.warning(
          "Workflow step '${step.id}' reported outcome '${parsed.outcome}' but task ${task.id} "
          'finished with terminal status ${task.status.name}; overriding to failed',
        );
      }
      final failReason =
          (task.configJson['failReason'] as String?) ?? (task.configJson['errorSummary'] as String?) ?? parsed?.reason;
      return ('failed', failReason ?? task.status.name);
    }
    if (parsed != null) {
      return (parsed.outcome, parsed.reason);
    }

    final fallbackOutcome = forcedOutcome;
    if (fallbackOutcome == null) {
      return (null, null);
    }

    await _incrementOutcomeFallbackCounter();
    _log.warning(
      "Workflow outcome fallback for step '${step.id}' "
      '(task ${task.id}, task status ${task.status.name})',
    );
    final failReason = task.configJson['failReason'] as String?;
    return (fallbackOutcome, failReason ?? task.status.name);
  }

  Future<void> _incrementOutcomeFallbackCounter() async {
    const key = 'workflow.outcome.fallback';
    final current = await _kvService.get(key);
    final next = (int.tryParse(current ?? '') ?? 0) + 1;
    await _kvService.set(key, next.toString());
  }

  Future<WorkflowRun> _transitionStepAwaitingApproval(
    WorkflowRun run,
    WorkflowStep step,
    WorkflowContext context, {
    required int stepIndex,
    required String reason,
  }) async {
    final requestedAt = DateTime.now().toIso8601String();
    context['${step.id}.approval.status'] = 'pending';
    context['${step.id}.approval.message'] = reason;
    context['${step.id}.approval.requested_at'] = requestedAt;

    // The held step has already executed and persisted its outputs (needsInput
    // outcome or `onFailure: pause`). Advance past it so resume continues at
    // the next step, matching the explicit approval-step contract.
    final awaitingApprovalRun = run.copyWith(
      status: WorkflowRunStatus.awaitingApproval,
      errorMessage: reason,
      currentStepIndex: stepIndex + 1,
      contextJson: {
        for (final e in run.contextJson.entries)
          if (e.key.startsWith('_')) e.key: e.value,
        ...context.toJson(),
        '${step.id}.approval.status': 'pending',
        '${step.id}.approval.message': reason,
        '${step.id}.approval.requested_at': requestedAt,
        '_approval.pending.stepId': step.id,
        '_approval.pending.stepIndex': stepIndex,
      },
      updatedAt: DateTime.now(),
    );
    await _persistContext(run.id, context);
    await _repository.update(awaitingApprovalRun);
    _eventBus.fire(
      WorkflowApprovalRequestedEvent(
        runId: run.id,
        stepId: step.id,
        message: reason,
        timeoutSeconds: step.timeoutSeconds,
        timestamp: DateTime.now(),
      ),
    );
    _eventBus.fire(
      WorkflowRunStatusChangedEvent(
        runId: run.id,
        definitionName: run.definitionName,
        oldStatus: run.status,
        newStatus: WorkflowRunStatus.awaitingApproval,
        errorMessage: reason,
        timestamp: DateTime.now(),
      ),
    );
    return awaitingApprovalRun;
  }

  // ── Loop execution ──────────────────────────────────────────────────────────

  /// Executes a single loop definition.
  ///
  /// Returns true if the workflow was paused or cancelled (caller should return).
  /// Returns false if the loop completed successfully.
  Future<bool> _executeLoop(
    WorkflowRun run,
    WorkflowDefinition definition,
    WorkflowLoop loop,
    WorkflowContext context, {
    bool Function()? isCancelled,
    int startFromIteration = 1,
    String? startFromStepId,
    required void Function(WorkflowRun) onRunUpdated,
  }) async {
    var gatePassed = false;
    // Track resume step — only applies to the first iteration when resuming.
    var resumeStepId = startFromStepId;
    final loopStartStepId = loop.steps.first;
    final loopStartStepIndex = definition.steps.indexWhere((step) => step.id == loopStartStepId);

    for (var iteration = startFromIteration; iteration <= loop.maxIterations; iteration++) {
      if (isCancelled?.call() ?? false) {
        _log.info("Workflow '${run.id}' cancelled during loop '${loop.id}'");
        return true;
      }

      // Set iteration counter in context.
      context.setLoopIteration(loop.id, iteration);

      // Persist loop tracking state before the iteration.
      run = run.copyWith(
        executionCursor: WorkflowExecutionCursor.loop(
          loopId: loop.id,
          stepIndex: loopStartStepIndex >= 0 ? loopStartStepIndex : 0,
          iteration: iteration,
          stepId: resumeStepId,
        ),
        contextJson: {
          ...run.contextJson,
          '_loop.current.id': loop.id,
          '_loop.current.iteration': iteration,
          // Clear step tracking at iteration start.
          if (resumeStepId == null) '_loop.current.stepId': null,
        },
        updatedAt: DateTime.now(),
      );
      await _repository.update(run);
      onRunUpdated(run);

      final entryGate = loop.entryGate?.trim();
      if (entryGate != null && entryGate.isNotEmpty && !_gateEvaluator.evaluate(entryGate, context)) {
        gatePassed = true;
        _log.info("Loop '${loop.id}' skipped: entry gate failed before iteration $iteration");
        _eventBus.fire(
          LoopIterationCompletedEvent(
            runId: run.id,
            loopId: loop.id,
            iteration: iteration,
            maxIterations: loop.maxIterations,
            gateResult: false,
            timestamp: DateTime.now(),
          ),
        );
        if (loop.finally_ != null) {
          final (updatedRun, finalizerMsg) = await _executeLoopFinalizer(
            run,
            definition,
            loop,
            context,
            onRunUpdated: onRunUpdated,
          );
          run = updatedRun;
          if (finalizerMsg != null) {
            await _failRun(run, finalizerMsg);
            return true;
          }
        }
        break;
      }

      // Execute each loop step sequentially.
      for (var loopStepIndex = 0; loopStepIndex < loop.steps.length; loopStepIndex++) {
        final stepId = loop.steps[loopStepIndex];
        // Skip completed steps when resuming from a specific failed step.
        if (resumeStepId != null && stepId != resumeStepId) {
          _log.fine(
            "Workflow '${run.id}': skipping completed loop step '$stepId' "
            "(resuming from '$resumeStepId')",
          );
          continue;
        }
        // Clear resume marker once we've reached the target step.
        resumeStepId = null;

        if (isCancelled?.call() ?? false) {
          _log.info("Workflow '${run.id}' cancelled in loop '${loop.id}' iter $iteration");
          return true;
        }

        final step = definition.steps.firstWhere((s) => s.id == stepId);

        if (step.parallel) {
          _log.warning(
            "Step '${step.id}' has parallel:true but is inside loop '${loop.id}' — "
            'executing sequentially (parallel flag ignored in loops)',
          );
        }

        if (_shouldSkipDueToEntryGate(step, context, run.id)) {
          continue;
        }

        // Gate check on individual loop step.
        if (step.gate != null) {
          final gatePasses = _gateEvaluator.evaluate(step.gate!, context);
          if (!gatePasses) {
            final msg = "Gate failed in loop '${loop.id}' iteration $iteration: ${step.gate}";
            _log.info("Workflow '${run.id}': $msg");
            await _failRun(run, msg);
            return true;
          }
        }

        // Workflow budget check.
        final refreshedRun = await _repository.getById(run.id) ?? run;
        run = refreshedRun;
        onRunUpdated(run);
        run = await _checkWorkflowBudgetWarning(run, definition);
        onRunUpdated(run);
        if (_workflowBudgetExceeded(run, definition)) {
          final msg = "Workflow budget exceeded during loop '${loop.id}'";
          _log.info("Workflow '${run.id}': $msg");
          await _failRun(run, msg);
          return true;
        }

        // Find step index in definition for task metadata and resume support.
        final stepIndex = definition.steps.indexOf(step);

        // Persist current step ID for resume support.
        run = run.copyWith(
          executionCursor: WorkflowExecutionCursor.loop(
            loopId: loop.id,
            stepIndex: stepIndex,
            iteration: iteration,
            stepId: stepId,
          ),
          contextJson: {
            ...run.contextJson,
            '_loop.current.id': loop.id,
            '_loop.current.iteration': iteration,
            '_loop.current.stepId': stepId,
          },
          updatedAt: DateTime.now(),
        );
        await _repository.update(run);
        onRunUpdated(run);

        final result = await _executeStep(
          run,
          definition,
          step,
          context,
          stepIndex: stepIndex,
          loopId: loop.id,
          loopIteration: iteration,
          promoteAfterSuccess: _isLastBranchTouchingStepInScope(
            definition,
            step,
            loop.steps
                .skip(loopStepIndex + 1)
                .map((id) => definition.steps.firstWhere((candidate) => candidate.id == id)),
          ),
        );
        if (result == null) return true; // Task creation failed — already paused.

        if (!result.success) {
          final failMsg = "Loop '${loop.id}' step '${step.name}' failed in iteration $iteration";
          _log.info("Workflow '${run.id}': $failMsg");

          if (step.onError == 'continue') {
            // Record failed-step metadata and continue to next loop step.
            _mergeStepResultIntoContext(context, result, fallbackStatus: 'failed');
            run = run.copyWith(totalTokens: run.totalTokens + result.tokenCount, updatedAt: DateTime.now());
            final nextLoopStepId = loopStepIndex + 1 < loop.steps.length ? loop.steps[loopStepIndex + 1] : null;
            final nextLoopStepIndex = nextLoopStepId == null
                ? (loopStartStepIndex >= 0 ? loopStartStepIndex : stepIndex)
                : definition.steps.indexWhere((candidate) => candidate.id == nextLoopStepId);
            run = await _persistLoopStepCheckpoint(
              run,
              context,
              loopId: loop.id,
              iteration: iteration,
              nextStepId: nextLoopStepId,
              nextStepIndex: nextLoopStepIndex >= 0 ? nextLoopStepIndex : stepIndex,
            );
            onRunUpdated(run);
            _eventBus.fire(
              WorkflowStepCompletedEvent(
                runId: run.id,
                stepId: step.id,
                stepName: step.name,
                stepIndex: stepIndex,
                totalSteps: definition.steps.length,
                taskId: result.task?.id ?? '',
                success: false,
                tokenCount: result.tokenCount,
                timestamp: DateTime.now(),
              ),
            );
            if (isCancelled?.call() ?? false) {
              _log.info("Workflow '${run.id}' cancelled in loop '${loop.id}' iter $iteration after step '${step.id}'");
              return true;
            }
            continue;
          }

          // Run the finalizer before pausing (if defined).
          if (loop.finally_ != null) {
            final (updatedRun, finalizerMsg) = await _executeLoopFinalizer(
              run,
              definition,
              loop,
              context,
              onRunUpdated: onRunUpdated,
            );
            run = updatedRun;
            if (finalizerMsg != null) {
              await _failRun(run, finalizerMsg);
              return true;
            }
          }
          if (result.awaitingApproval) {
            run = await _transitionStepAwaitingApproval(
              run,
              step,
              context,
              stepIndex: stepIndex,
              reason: result.outcomeReason ?? failMsg,
            );
            return true;
          }
          await _failRun(run, failMsg);
          return true;
        }

        _mergeStepResultIntoContext(context, result, fallbackStatus: result.task?.status.name ?? 'completed');

        run = run.copyWith(totalTokens: run.totalTokens + result.tokenCount, updatedAt: DateTime.now());
        final nextLoopStepId = loopStepIndex + 1 < loop.steps.length ? loop.steps[loopStepIndex + 1] : null;
        final nextLoopStepIndex = nextLoopStepId == null
            ? (loopStartStepIndex >= 0 ? loopStartStepIndex : stepIndex)
            : definition.steps.indexWhere((candidate) => candidate.id == nextLoopStepId);
        run = await _persistLoopStepCheckpoint(
          run,
          context,
          loopId: loop.id,
          iteration: iteration,
          nextStepId: nextLoopStepId,
          nextStepIndex: nextLoopStepIndex >= 0 ? nextLoopStepIndex : stepIndex,
        );
        onRunUpdated(run);

        _eventBus.fire(
          WorkflowStepCompletedEvent(
            runId: run.id,
            stepId: step.id,
            stepName: step.name,
            stepIndex: stepIndex,
            totalSteps: definition.steps.length,
            taskId: result.task?.id ?? '',
            success: result.success,
            tokenCount: result.tokenCount,
            timestamp: DateTime.now(),
          ),
        );

        if (isCancelled?.call() ?? false) {
          _log.info("Workflow '${run.id}' cancelled in loop '${loop.id}' iter $iteration after step '${step.id}'");
          return true;
        }
      }

      // Evaluate exit gate after all steps in this iteration.
      if (_gateEvaluator.evaluate(loop.exitGate, context)) {
        gatePassed = true;
        _log.info("Loop '${loop.id}' completed: exit gate passed at iteration $iteration");
        _eventBus.fire(
          LoopIterationCompletedEvent(
            runId: run.id,
            loopId: loop.id,
            iteration: iteration,
            maxIterations: loop.maxIterations,
            gateResult: true,
            timestamp: DateTime.now(),
          ),
        );
        // Run the finalizer before exiting the loop (if defined).
        if (loop.finally_ != null) {
          final (updatedRun, finalizerMsg) = await _executeLoopFinalizer(
            run,
            definition,
            loop,
            context,
            onRunUpdated: onRunUpdated,
          );
          run = updatedRun;
          if (finalizerMsg != null) {
            await _failRun(run, finalizerMsg);
            return true;
          }
        }
        break;
      }

      // Gate failed — fire event and continue to next iteration.
      _eventBus.fire(
        LoopIterationCompletedEvent(
          runId: run.id,
          loopId: loop.id,
          iteration: iteration,
          maxIterations: loop.maxIterations,
          gateResult: false,
          timestamp: DateTime.now(),
        ),
      );

      // Persist context after each iteration.
      await _persistContext(run.id, context);
      run = run.copyWith(contextJson: context.toJson(), updatedAt: DateTime.now());
      await _repository.update(run);
      onRunUpdated(run);
    }

    if (!gatePassed) {
      // Clear loop tracking before pausing.
      run = run.copyWith(
        executionCursor: null,
        contextJson: {
          for (final e in run.contextJson.entries)
            if (!e.key.startsWith('_loop.current')) e.key: e.value,
        },
        updatedAt: DateTime.now(),
      );
      await _repository.update(run);
      onRunUpdated(run);

      // Run the finalizer before pausing (if defined).
      if (loop.finally_ != null) {
        final (updatedRun, finalizerMsg) = await _executeLoopFinalizer(
          run,
          definition,
          loop,
          context,
          onRunUpdated: onRunUpdated,
        );
        run = updatedRun;
        if (finalizerMsg != null) {
          await _failRun(run, finalizerMsg);
          return true;
        }
      }

      final msg =
          "Loop '${loop.id}' reached max iterations (${loop.maxIterations}). "
          'Exit condition not met: ${loop.exitGate}';
      _log.info("Workflow '${run.id}': $msg");
      await _failRun(run, msg);
      return true;
    }

    // Clear loop tracking state on success.
    run = run.copyWith(
      executionCursor: null,
      contextJson: {
        for (final e in run.contextJson.entries)
          if (!e.key.startsWith('_loop.current')) e.key: e.value,
        ...context.toJson(),
      },
      updatedAt: DateTime.now(),
    );
    await _repository.update(run);
    onRunUpdated(run);

    return false;
  }

  Future<WorkflowRun> _persistLoopStepCheckpoint(
    WorkflowRun run,
    WorkflowContext context, {
    required String loopId,
    required int iteration,
    required String? nextStepId,
    required int nextStepIndex,
  }) async {
    final updatedRun = run.copyWith(
      executionCursor: WorkflowExecutionCursor.loop(
        loopId: loopId,
        stepIndex: nextStepIndex,
        iteration: iteration,
        stepId: nextStepId,
      ),
      contextJson: {
        for (final e in run.contextJson.entries)
          if (e.key.startsWith('_') && !e.key.startsWith('_map.current')) e.key: e.value,
        ...context.toJson(),
        '_loop.current.id': loopId,
        '_loop.current.iteration': iteration,
        '_loop.current.stepId': nextStepId,
      },
      updatedAt: DateTime.now(),
    );
    await _persistContext(run.id, context);
    await _repository.update(updatedRun);
    return updatedRun;
  }

  /// Executes the finalizer step for a loop, if one is defined.
  ///
  /// Returns a record of (updated run, error message). If [errorMessage] is non-null,
  /// the caller should pause the run with that message. If null, the finalizer
  /// completed successfully and execution may continue.
  Future<(WorkflowRun, String?)> _executeLoopFinalizer(
    WorkflowRun run,
    WorkflowDefinition definition,
    WorkflowLoop loop,
    WorkflowContext context, {
    required void Function(WorkflowRun) onRunUpdated,
  }) async {
    final finallyStepId = loop.finally_!;
    final finallyStep = definition.steps.firstWhere((s) => s.id == finallyStepId);
    final stepIndex = definition.steps.indexOf(finallyStep);

    _log.info("Workflow '${run.id}': executing finalizer '${finallyStep.id}' for loop '${loop.id}'");

    final result = await _executeStep(run, definition, finallyStep, context, stepIndex: stepIndex);

    if (result == null) {
      // Task creation failed — already paused by _executeStep.
      return (run, null);
    }

    if (!result.success) {
      final msg = "Loop '${loop.id}' finalizer '${finallyStep.name}' failed";
      _log.info("Workflow '${run.id}': $msg");
      return (run, msg);
    }

    _mergeStepResultIntoContext(context, result, fallbackStatus: result.task?.status.name ?? 'completed');

    run = run.copyWith(totalTokens: run.totalTokens + result.tokenCount, updatedAt: DateTime.now());
    onRunUpdated(run);

    _eventBus.fire(
      WorkflowStepCompletedEvent(
        runId: run.id,
        stepId: finallyStep.id,
        stepName: finallyStep.name,
        stepIndex: stepIndex,
        totalSteps: definition.steps.length,
        taskId: result.task!.id,
        success: true,
        tokenCount: result.tokenCount,
        timestamp: DateTime.now(),
      ),
    );

    return (run, null);
  }

  // ── Single step execution ───────────────────────────────────────────────────

  /// Executes a single step: resolves template, creates task, waits for terminal state.
  ///
  /// Returns null if task creation fails (workflow already paused by this method).
  /// Returns a [_ParallelStepResult] (success or failure) on completion.
  Future<_ParallelStepResult?> _executeStep(
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
    // Dispatch bash steps to the zero-task host executor.
    if (step.type == 'bash') {
      return _executeBashStep(run, step, context);
    }

    // Dispatch approval steps — zero-task pause with metadata persistence.
    if (step.type == 'approval') {
      await _executeApprovalStep(run, step, context, stepIndex: stepIndex);
      return null; // Already paused — caller must stop.
    }

    // Resolve effective config (per-step overrides matching stepDefaults entry).
    final resolved = resolveStepConfig(step, definition.stepDefaults, roleDefaults: _roleDefaults);

    // Augment only the LAST prompt with schema instructions.
    // resolveWithMap handles {{map.*}} references (null mapCtx falls back to resolve).
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

    // Inject per-iteration metadata for foreach child steps so downstream tracking and tests
    // can identify which story iteration this task belongs to.
    if (mapCtx != null) {
      taskConfig = {...taskConfig, '_mapIterationIndex': mapCtx.index, '_mapIterationTotal': mapCtx.length};

      // Resolve workflow externalArtifactMount for this iteration so the
      // task-side worktree manager can apply a per-story file copy before
      // the agent turn starts.
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

    // continueSession: resolve root session and snapshot token baseline.
    if (continuedRootStep != null) {
      final prevSessionId = _resolveContinueSessionRootSessionId(definition, step, context);
      if (prevSessionId == null) {
        final msg =
            "Step '${step.id}' uses continueSession but no session ID found for root step "
            "'${continuedRootStep.id}'. Ensure the referenced step completed successfully first.";
        _log.warning("Workflow '${run.id}': $msg");
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

    // For single-prompt steps, augment the first (only) prompt now.
    // For multi-prompt, augment the last prompt later; first prompt is unaugmented.
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
    // Note: auto-framing intentionally does not run on follow-up prompts;
    // the continuation shares the conversation's existing context and the
    // contract was already rendered on the first prompt.
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

      // Subscribe before create to avoid race condition.
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
        _log.severe("Workflow '${run.id}': $msg", e, st);
        await _failRun(run, msg);
        return null;
      }

      _log.fine("Workflow '${run.id}': step '${step.id}' → task $taskId");

      late Task finalTask;
      try {
        finalTask = await _waitForTaskCompletion(taskId, step, completer, sub, runId: run.id);
      } on TimeoutException {
        final msg = 'Step "${step.name}" timed out after ${step.timeoutSeconds}s';
        _log.warning("Workflow '${run.id}': $msg");
        await _failRun(run, msg);
        return null;
      } on StateError catch (e) {
        _log.info("Workflow '${run.id}': step '${step.name}' wait aborted: ${e.message}");
        return null;
      } catch (e, st) {
        final msg = "Step '${step.name}' wait failed: $e";
        _log.severe("Workflow '${run.id}': $msg", e, st);
        await _failRun(run, msg);
        return null;
      }

      final tokenCount = await _readStepTokenCount(finalTask);
      accumulatedTokenCount += tokenCount;

      Map<String, dynamic> outputs = {};
      if (finalTask.status != TaskStatus.failed && finalTask.status != TaskStatus.cancelled) {
        try {
          outputs = await _contextExtractor.extract(step, finalTask, effectiveOutputs: effectiveOutputs);
        } catch (e, st) {
          _log.warning("Context extraction failed for step '${step.id}'", e, st);
        }
      }

      // Always expose the `{stepId}.branch` / `{stepId}.worktree_path` keys
      // (empty when no worktree metadata) so downstream `{{context.X.branch}}`
      // template references resolve uniformly regardless of step type. Warn
      // only when a step that was supposed to have a worktree doesn't.
      final wj = finalTask.worktreeJson;
      outputs['${step.id}.branch'] = (wj?['branch'] as String?) ?? '';
      outputs['${step.id}.worktree_path'] = (wj?['path'] as String?) ?? '';
      if (wj == null && _stepNeedsWorktree(definition, step, resolved, resolvedWorktreeMode: resolvedWorktreeMode)) {
        _log.warning(
          "Workflow '${run.id}': step '${step.id}' requires a worktree but has no worktree metadata — "
          'branch/worktree_path context values will be empty',
        );
      }
      outputs = _normalizeWorkflowOutputs(run, step, outputs, context);
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
      final effectiveOutcome = outcome;
      final effectiveReason = (outcomeReason != null && outcomeReason.isNotEmpty)
          ? outcomeReason
          : (finalTask.configJson['failReason'] as String?) ?? finalTask.status.name;

      if (effectiveOutcome == 'needsInput') {
        return _ParallelStepResult(
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
            return _ParallelStepResult(
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
              _log.info(
                "Workflow '${run.id}': retrying step '${step.id}' after failed outcome "
                '($attempt/$outcomeRetryLimit)',
              );
              continue;
            }
            break;
          case OnFailurePolicy.pause:
            return _ParallelStepResult(
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

        return _ParallelStepResult(
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
          return _ParallelStepResult(
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

      return _ParallelStepResult(
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

  // ── Bash step execution ─────────────────────────────────────────────────────

  /// Executes a `type: bash` step on the host via [SafeProcess.start].
  ///
  /// - Zero task creation; zero token accounting.
  /// - `{{context.*}}` substitutions are shell-escaped before execution.
  /// - stdout truncated at 64 KB with `[truncated]` marker.
  /// - `onError: continue` records failure and returns success=true with
  ///   `<stepId>.status == 'failed'` so downstream steps see the failure.
  /// - `onError: pause` (default) returns success=false → caller pauses run.
  static const _bashStdoutMaxBytes = 64 * 1024;

  Future<_ParallelStepResult> _executeBashStep(WorkflowRun run, WorkflowStep step, WorkflowContext context) async {
    // Resolve workdir.
    final String workDir;
    try {
      workDir = _resolveBashWorkdir(step, context);
    } catch (e) {
      return _bashFailure(step, 'workdir resolution failed: $e');
    }

    // Validate workdir existence before spawning.
    if (!Directory(workDir).existsSync()) {
      return _bashFailure(step, 'workdir does not exist: $workDir');
    }

    // Resolve template in the command (single-string prompt).
    final rawCommand = step.prompts?.firstOrNull ?? '';
    final String resolvedCommand;
    try {
      resolvedCommand = _resolveBashCommand(rawCommand, context);
    } catch (e) {
      return _bashFailure(step, 'command substitution failed: $e');
    }

    // Execute via Process.start so timed-out commands can be terminated explicitly.
    final timeoutSeconds = step.timeoutSeconds ?? 60;
    late Process process;
    try {
      process = await SafeProcess.start(
        '/bin/sh',
        ['-c', resolvedCommand],
        env: EnvPolicy.sanitize(
          allowlist: _bashStepEnvAllowlist,
          sensitivePatterns: [...kDefaultSensitivePatterns, ..._bashStepExtraStripPatterns],
        ),
        baseEnvironment: _hostEnvironment,
        workingDirectory: workDir,
        runInShell: false,
      );
    } catch (e) {
      return _bashFailure(step, 'process execution failed: $e');
    }

    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();

    late int exitCode;
    try {
      exitCode = await process.exitCode.timeout(Duration(seconds: timeoutSeconds));
    } on TimeoutException {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
      }
      final stderr = await stderrFuture;
      return _bashFailure(step, 'timed out after ${timeoutSeconds}s', stderr: stderr);
    }

    // Capture and truncate stdout.
    final rawStdout = await stdoutFuture;
    final bool truncated = rawStdout.length > _bashStdoutMaxBytes;
    final stdout = truncated ? '${rawStdout.substring(0, _bashStdoutMaxBytes)}[truncated]' : rawStdout;
    final stderr = await stderrFuture;

    if (exitCode != 0) {
      _log.warning(
        "Workflow '${run.id}': bash step '${step.id}' exited $exitCode"
        "${stderr.isNotEmpty ? ': ${stderr.trim()}' : ''}",
      );
      return _bashFailure(step, 'exited with code $exitCode', stderr: stderr);
    }

    // Extract context outputs from stdout.
    final Map<String, dynamic> outputs;
    try {
      outputs = _extractBashOutputs(step, stdout);
    } on FormatException catch (e) {
      return _bashFailure(step, e.message, stderr: stderr);
    }

    // Record step metadata in context.
    return _ParallelStepResult(
      step: step,
      task: null,
      outputs: {
        ...outputs,
        '${step.id}.status': 'success',
        '${step.id}.exitCode': exitCode,
        '${step.id}.tokenCount': 0,
        '${step.id}.workdir': workDir,
        if (stderr.isNotEmpty) '${step.id}.stderr': stderr,
        if (truncated) '${step.id}.stdoutTruncated': true,
      },
      tokenCount: 0,
      success: true,
    );
  }

  /// Resolves the working directory for a bash step.
  ///
  /// Resolution order:
  ///   1. explicit `workdir` field (with template resolution)
  ///   2. workspace root (`<dataDir>/workspace`, created if absent)
  String _resolveBashWorkdir(WorkflowStep step, WorkflowContext context) {
    if (step.workdir != null) {
      final resolved = _templateEngine.resolve(step.workdir!, context).trim();
      if (resolved.isEmpty) {
        throw ArgumentError('workdir resolved to an empty path');
      }
      return resolved;
    }
    // Default: workspace root. Create it if absent so fresh installs work.
    final workspaceRoot = p.join(_dataDir, 'workspace');
    Directory(workspaceRoot).createSync(recursive: true);
    return workspaceRoot;
  }

  /// Resolves template references in [command], shell-escaping all
  /// `{{context.*}}` substitution values to prevent injection.
  String _resolveBashCommand(String command, WorkflowContext context) {
    return command.replaceAllMapped(RegExp(r'\{\{([^}]+)\}\}'), (match) {
      final ref = match.group(1)!.trim();
      if (ref.startsWith('context.')) {
        final key = ref.substring('context.'.length);
        final value = context[key];
        if (value == null) {
          _log.warning(
            'Bash command template reference {{$ref}} resolved to empty string '
            '(key "$key" not in context)',
          );
          return shellEscape('');
        }
        // Shell-escape context values to prevent injection.
        return shellEscape(value.toString());
      }
      // Variable references (non-context) are NOT shell-escaped — they are
      // author-controlled and expected to be safe command fragments.
      final value = context.variable(ref);
      if (value == null) {
        throw ArgumentError('Bash command references undefined variable: {{$ref}}');
      }
      return value;
    });
  }

  /// Extracts context outputs from bash [stdout] using the step's output config.
  Map<String, dynamic> _extractBashOutputs(WorkflowStep step, String stdout) {
    if (step.contextOutputs.isEmpty) return {};

    final outputs = <String, dynamic>{};
    for (final outputKey in step.contextOutputs) {
      final config = step.outputs?[outputKey];
      final format = config?.format ?? OutputFormat.text;

      switch (format) {
        case OutputFormat.json:
          if (stdout.trim().isEmpty) {
            throw FormatException('Bash step "${step.id}": empty stdout for json extraction of "$outputKey"');
          } else {
            try {
              outputs[outputKey] = extractJson(stdout);
            } on FormatException catch (e) {
              throw FormatException('Bash step "${step.id}": JSON extraction failed for "$outputKey": $e');
            }
          }
        case OutputFormat.lines:
          outputs[outputKey] = extractLines(stdout);
        case OutputFormat.text:
        case OutputFormat.path:
          outputs[outputKey] = stdout;
      }
    }
    return outputs;
  }

  /// Returns a failed [_ParallelStepResult] for a bash step.
  _ParallelStepResult _bashFailure(WorkflowStep step, String reason, {String? stderr}) {
    _log.info("Bash step '${step.id}' failed: $reason");
    return _ParallelStepResult(
      step: step,
      task: null,
      outputs: {
        '${step.id}.status': 'failed',
        '${step.id}.exitCode': -1,
        '${step.id}.tokenCount': 0,
        '${step.id}.error': reason,
        if (stderr != null && stderr.isNotEmpty) '${step.id}.stderr': stderr,
      },
      tokenCount: 0,
      success: false,
      error: reason,
    );
  }

  /// Executes a `type: approval` step — pauses the run with approval metadata.
  ///
  /// No child task is created and no tokens are consumed. Approval metadata is
  /// persisted in contextJson so the API and UI can surface it without task lookups.
  /// If [step.timeoutSeconds] is set, a timer auto-cancels the run on expiry.
  Future<void> _executeApprovalStep(
    WorkflowRun run,
    WorkflowStep step,
    WorkflowContext context, {
    required int stepIndex,
  }) async {
    final message = _templateEngine.resolve(step.prompts?.firstOrNull ?? '', context);
    final requestedAt = DateTime.now().toIso8601String();

    // Persist approval metadata — stored both in context (for downstream template access)
    // and as flat contextJson keys (for API/UI lookups without task joins).
    context['${step.id}.status'] = 'pending';
    context['${step.id}.approval.status'] = 'pending';
    context['${step.id}.approval.message'] = message;
    context['${step.id}.approval.requested_at'] = requestedAt;
    context['${step.id}.tokenCount'] = 0;

    final timeoutSeconds = step.timeoutSeconds;
    final approvalMeta = <String, dynamic>{
      '${step.id}.status': 'pending',
      '${step.id}.approval.status': 'pending',
      '${step.id}.approval.message': message,
      '${step.id}.approval.requested_at': requestedAt,
      '${step.id}.tokenCount': 0,
      // Store step index so resume can advance past the approval step.
      '_approval.pending.stepId': step.id,
      '_approval.pending.stepIndex': stepIndex,
    };

    if (timeoutSeconds != null) {
      final deadline = DateTime.now().add(Duration(seconds: timeoutSeconds)).toIso8601String();
      context['${step.id}.approval.timeout_deadline'] = deadline;
      approvalMeta['${step.id}.approval.timeout_deadline'] = deadline;
    }

    final awaitingApprovalRun = run.copyWith(
      // Advance currentStepIndex past this approval step so on resume the
      // executor starts at the next step (approval step doesn't re-execute).
      currentStepIndex: stepIndex + 1,
      status: WorkflowRunStatus.awaitingApproval,
      errorMessage: 'approval required: ${step.id}',
      contextJson: {
        for (final e in run.contextJson.entries)
          if (e.key.startsWith('_')) e.key: e.value,
        ...context.toJson(),
        // Flat approval keys accessible directly on run.contextJson without data sub-key.
        ...approvalMeta,
      },
      updatedAt: DateTime.now(),
    );
    await _persistContext(run.id, context);
    await _repository.update(awaitingApprovalRun);

    _eventBus.fire(
      WorkflowApprovalRequestedEvent(
        runId: run.id,
        stepId: step.id,
        message: message,
        timeoutSeconds: timeoutSeconds,
        timestamp: DateTime.now(),
      ),
    );
    _eventBus.fire(
      WorkflowRunStatusChangedEvent(
        runId: run.id,
        definitionName: run.definitionName,
        oldStatus: run.status,
        newStatus: WorkflowRunStatus.awaitingApproval,
        errorMessage: 'approval required: ${step.id}',
        timestamp: DateTime.now(),
      ),
    );

    // Start timeout timer if configured.
    if (timeoutSeconds != null) {
      final timerKey = '${run.id}:${step.id}';
      _approvalTimers[timerKey] = Timer(Duration(seconds: timeoutSeconds), () async {
        _approvalTimers.remove(timerKey);
        final current = await _repository.getById(run.id);
        if (current == null || current.status != WorkflowRunStatus.awaitingApproval) return;
        final updatedContext = Map<String, dynamic>.from(current.contextJson)
          ..['${step.id}.status'] = 'cancelled'
          ..['${step.id}.approval.status'] = 'timed_out'
          ..['${step.id}.approval.cancel_reason'] = 'timeout';
        final withReason = current.copyWith(contextJson: updatedContext, updatedAt: DateTime.now());
        await _repository.update(withReason);
        await _cancelRun(withReason, 'approval timeout: ${step.id}');
      });
    }
  }

  /// Cancels a workflow run (used for approval timeout).
  ///
  /// Parallel to [_pauseRun] and [_completeRun] — transitions run to cancelled
  /// and cancels any non-terminal child tasks.
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

    // Cancel any non-terminal child tasks.
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
  }

  // ── Shared helpers ──────────────────────────────────────────────────────────

  Future<void> _createWorkflowTaskTriple({
    required String taskId,
    required WorkflowRun run,
    required WorkflowStep step,
    required int stepIndex,
    required String title,
    required String description,
    required TaskType type,
    required String? provider,
    required String? projectId,
    required int? maxTokens,
    required int maxRetries,
    required Map<String, dynamic> taskConfig,
  }) async {
    final taskRepository = _taskRepository;
    final agentExecutionRepository = _agentExecutionRepository;
    final workflowStepExecutionRepository = _workflowStepExecutionRepository;
    final executionTransactor = _executionTransactor;
    if (taskRepository == null ||
        agentExecutionRepository == null ||
        workflowStepExecutionRepository == null ||
        executionTransactor == null) {
      throw StateError(
        'Workflow task spawn requires AgentExecution + WorkflowStepExecution persistence. '
        'Wire taskRepository, agentExecutionRepository, workflowStepExecutionRepository, and '
        'executionTransactor into WorkflowExecutor before executing workflows.',
      );
    }

    final timestamp = DateTime.now();
    final agentExecutionId = _uuid.v4();
    final agentExecution = AgentExecution(
      id: agentExecutionId,
      provider: _trimmedString(provider),
      model: _trimmedString(taskConfig['model']),
      workspaceDir: _resolveWorkflowWorkspaceDir(),
      budgetTokens: maxTokens,
    );
    final workflowStepExecution = _buildWorkflowStepExecutionFromConfig(
      taskId: taskId,
      agentExecutionId: agentExecutionId,
      runId: run.id,
      stepIndex: stepIndex,
      step: step,
      taskConfig: taskConfig,
    );
    final sanitizedTaskConfig = _stripWorkflowStepConfig(taskConfig);
    final queuedTask = Task(
      id: taskId,
      title: title,
      description: description,
      type: type,
      status: TaskStatus.queued,
      configJson: sanitizedTaskConfig,
      createdAt: timestamp,
      startedAt: null,
      completedAt: null,
      provider: provider,
      agentExecutionId: agentExecutionId,
      agentExecution: agentExecution,
      projectId: projectId?.trim().isEmpty ?? true ? null : projectId?.trim(),
      maxTokens: maxTokens != null && maxTokens > 0 ? maxTokens : null,
      workflowRunId: run.id,
      stepIndex: stepIndex,
      workflowStepExecution: workflowStepExecution,
      maxRetries: maxRetries > 0 ? maxRetries : 0,
    );

    await executionTransactor.transaction(() async {
      await agentExecutionRepository.create(agentExecution);
      await taskRepository.insert(queuedTask);
      await workflowStepExecutionRepository.create(workflowStepExecution);
    });

    _eventBus.fire(
      TaskStatusChangedEvent(
        taskId: taskId,
        oldStatus: TaskStatus.draft,
        newStatus: TaskStatus.queued,
        trigger: 'workflow',
        timestamp: timestamp,
      ),
    );
  }

  WorkflowStepExecution _buildWorkflowStepExecutionFromConfig({
    required String taskId,
    required String agentExecutionId,
    required String runId,
    required int stepIndex,
    required WorkflowStep step,
    required Map<String, dynamic> taskConfig,
  }) {
    final tokenBreakdown = _buildTokenBreakdownJson(taskConfig);
    return WorkflowStepExecution(
      taskId: taskId,
      agentExecutionId: agentExecutionId,
      workflowRunId: runId,
      stepIndex: stepIndex,
      stepId: step.id,
      stepType: _trimmedString(taskConfig['_workflowStepType']) ?? step.type,
      gitJson: _encodeJsonString(taskConfig['_workflowGit']),
      providerSessionId: _trimmedString(taskConfig['_continueProviderSessionId']),
      structuredSchemaJson: _encodeJsonString(taskConfig['_workflowStructuredSchema']),
      structuredOutputJson: _encodeJsonString(taskConfig['_workflowStructuredOutputPayload']),
      followUpPromptsJson: _encodeJsonString(taskConfig['_workflowFollowUpPrompts']),
      externalArtifactMount: _encodeJsonString(taskConfig['_workflow.externalArtifactMount']),
      mapIterationIndex: _intOrNull(taskConfig['_mapIterationIndex']),
      mapIterationTotal: _intOrNull(taskConfig['_mapIterationTotal']),
      stepTokenBreakdownJson: tokenBreakdown,
    );
  }

  Map<String, dynamic> _stripWorkflowStepConfig(Map<String, dynamic> taskConfig) {
    final sanitized = Map<String, dynamic>.from(taskConfig);
    for (final key in const <String>{
      '_workflowStepType',
      '_workflowGit',
      '_workflowWorkspaceDir',
      '_workflow.externalArtifactMount',
      '_workflowFollowUpPrompts',
      '_workflowStructuredSchema',
      '_workflowProviderSessionId',
      '_workflowStructuredOutputPayload',
      '_workflowStepId',
      '_workflowInputTokensNew',
      '_workflowCacheReadTokens',
      '_workflowOutputTokens',
      '_continueProviderSessionId',
      '_mapIterationIndex',
      '_mapIterationTotal',
      '_mapStepId',
      // S34: model is canonical on AgentExecution; must not persist in Task.configJson.
      'model',
    }) {
      sanitized.remove(key);
    }
    return sanitized;
  }

  String? _buildTokenBreakdownJson(Map<String, dynamic> taskConfig) {
    final inputTokensNew = _intOrNull(taskConfig['_workflowInputTokensNew']);
    final cacheReadTokens = _intOrNull(taskConfig['_workflowCacheReadTokens']);
    final outputTokens = _intOrNull(taskConfig['_workflowOutputTokens']);
    if (inputTokensNew == null && cacheReadTokens == null && outputTokens == null) {
      return null;
    }
    return jsonEncode({
      ...?switch (inputTokensNew) {
        final value? => {'inputTokensNew': value},
        null => null,
      },
      ...?switch (cacheReadTokens) {
        final value? => {'cacheReadTokens': value},
        null => null,
      },
      ...?switch (outputTokens) {
        final value? => {'outputTokens': value},
        null => null,
      },
    });
  }

  String? _encodeJsonString(Object? value) => value == null ? null : jsonEncode(value);

  String? _trimmedString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  int? _intOrNull(Object? value) {
    return switch (value) {
      final int intValue => intValue,
      final num numValue => numValue.toInt(),
      _ => null,
    };
  }

  /// Waits for a task to complete using a pre-created [completer] and [sub].
  Future<Task> _waitForTaskCompletion(
    String taskId,
    WorkflowStep step,
    Completer<Task> completer,
    StreamSubscription<TaskStatusChangedEvent> sub, {
    String? runId,
  }) async {
    // Wake the wait if the owning workflow run transitions away from `running`
    // (e.g. `WorkflowService.pause(runId)` → `WorkflowRunStatusChangedEvent`).
    // Without this, a step blocked on a task that never completes would hold
    // the executor indefinitely, and pause/cancel would observe no effect.
    StreamSubscription<WorkflowRunStatusChangedEvent>? runSub;
    if (runId != null) {
      runSub = _eventBus.on<WorkflowRunStatusChangedEvent>().where((e) => e.runId == runId).listen((event) {
        if (event.newStatus != WorkflowRunStatus.running && !completer.isCompleted) {
          completer.completeError(
            StateError(
              'Workflow run "$runId" transitioned to ${event.newStatus.name} while step "${step.name}" awaited task $taskId',
            ),
          );
        }
      });
      // Close the race: if pause fired before we subscribed, the broadcast
      // stream dropped the event. Re-check current state from the repository
      // and abort if the run is no longer running.
      final currentRun = await _repository.getById(runId);
      if (currentRun != null && currentRun.status != WorkflowRunStatus.running && !completer.isCompleted) {
        completer.completeError(
          StateError(
            'Workflow run "$runId" is ${currentRun.status.name}; step "${step.name}" wait aborted before task $taskId completed',
          ),
        );
      }
    }
    try {
      if (step.timeoutSeconds != null) {
        return await completer.future.timeout(
          Duration(seconds: step.timeoutSeconds!),
          onTimeout: () =>
              throw TimeoutException('Step "${step.name}" timed out', Duration(seconds: step.timeoutSeconds!)),
        );
      } else {
        return await completer.future;
      }
    } finally {
      await sub.cancel();
      await runSub?.cancel();
    }
  }

  /// Builds configJson for a task from a workflow step and its resolved config.
  Map<String, dynamic> _buildStepConfig(
    WorkflowRun run,
    WorkflowDefinition definition,
    WorkflowStep step,
    ResolvedStepConfig resolved,
    WorkflowContext context, {
    required String resolvedWorktreeMode,
    required String effectivePromotion,
  }) {
    final config = <String, dynamic>{};
    if (resolved.model != null) config['model'] = resolved.model;
    if (resolved.effort != null) config['effort'] = resolved.effort;
    if (resolved.maxTokens != null) config['tokenBudget'] = resolved.maxTokens;
    if (resolved.allowedTools != null) config['allowedTools'] = resolved.allowedTools;
    if (resolved.maxCostUsd != null) config['maxCostUsd'] = resolved.maxCostUsd;
    final isReadOnlyStep = _stepIsReadOnly(step, resolved);
    if (isReadOnlyStep) {
      config['readOnly'] = true;
    }
    if (_stepNeedsWorktree(definition, step, resolved, resolvedWorktreeMode: resolvedWorktreeMode)) {
      config['_workflowNeedsWorktree'] = true;
    }
    config['_workflowStepType'] = step.type;
    final branch = context.variables['BRANCH']?.trim();
    if (branch != null && branch.isNotEmpty) {
      config['_baseRef'] = branch;
    }
    final integrationBranch = (context['_workflow.git.integration_branch'] as String?)?.trim();
    if (integrationBranch != null && integrationBranch.isNotEmpty && definition.gitStrategy?.bootstrap == true) {
      config['_baseRef'] = integrationBranch;
    }
    final strategy = definition.gitStrategy;
    if (strategy != null) {
      config['_workflowGit'] = {
        'runId': run.id,
        'worktree': resolvedWorktreeMode,
        'bootstrap': strategy.bootstrap,
        'promotion': effectivePromotion,
      };
    }
    config['_workflowWorkspaceDir'] = _resolveWorkflowWorkspaceDir();
    config['reviewMode'] = switch (step.review.name) {
      'always' => 'mandatory',
      _ => 'auto-accept',
    };
    return config;
  }

  String _resolvedWorktreeModeForScope(
    WorkflowDefinition definition,
    WorkflowStep step,
    WorkflowContext context, {
    int? enclosingMaxParallel,
  }) {
    final strategy = definition.gitStrategy;
    if (strategy == null) return 'inline';
    final isMapScope = step.mapOver != null || enclosingMaxParallel != null;
    final maxParallel = isMapScope
        ? (enclosingMaxParallel ?? _resolveMaxParallel(step.maxParallel, context, step.id))
        : null;
    return strategy.effectiveWorktreeMode(maxParallel: maxParallel, isMap: isMapScope);
  }

  String _effectivePromotion(WorkflowGitStrategy? strategy, {required String resolvedWorktreeMode}) {
    final explicit = strategy?.promotion?.trim();
    if (explicit != null && explicit.isNotEmpty) {
      return explicit;
    }
    return switch (resolvedWorktreeMode) {
      'per-map-item' || 'per-task' => 'merge',
      _ => 'none',
    };
  }

  bool _stepNeedsWorktree(
    WorkflowDefinition definition,
    WorkflowStep step,
    ResolvedStepConfig resolved, {
    required String resolvedWorktreeMode,
  }) {
    if (resolvedWorktreeMode == 'per-map-item') return true;
    if (step.isForeachController || step.contextOutputs.contains('project_index')) return false;
    return _shouldBindWorkflowProject(definition, step, resolved);
  }

  bool _isLastBranchTouchingStepInScope(
    WorkflowDefinition definition,
    WorkflowStep step,
    Iterable<WorkflowStep> followingScopeSteps,
  ) {
    if (!_stepTouchesProjectBranch(definition, step)) return false;
    final currentRootId = _continueSessionRootStepId(definition, step);
    for (final candidate in followingScopeSteps) {
      if (!_stepTouchesProjectBranch(definition, candidate)) continue;
      if (_continueSessionRootStepId(definition, candidate) == currentRootId) {
        return false;
      }
    }
    return true;
  }

  bool _stepIsReadOnly(WorkflowStep step, ResolvedStepConfig resolved) {
    final allowedTools = resolved.allowedTools;
    if (allowedTools != null) {
      return !allowedTools.contains('file_write');
    }
    if (!step.typeAuthored) {
      return step.type == 'research' || step.type == 'analysis';
    }
    return false;
  }

  bool _stepEmitsArtifactPath(WorkflowStep step) =>
      step.outputs?.values.any((config) => config.format == OutputFormat.path) ?? false;

  bool _shouldBindWorkflowProject(WorkflowDefinition definition, WorkflowStep step, ResolvedStepConfig resolved) {
    if (step.project != null) return true;
    if (definition.project == null) return false;
    if (step.isMapStep) return true;
    if (step.contextOutputs.contains('project_index')) return true;
    if (_stepEmitsArtifactPath(step)) return false;
    final allowedTools = resolved.allowedTools;
    if (allowedTools != null) {
      return allowedTools.contains('file_write');
    }
    // S41: semantic labels (`analysis`, `research`, `writing`, `coding`) no
    // longer drive workflow project binding. The only remaining authored type
    // hint used here is neutral `custom`, which the migrated built-ins use for
    // mutating agent steps that do not declare an explicit tool allowlist.
    return step.type == 'custom';
  }

  bool _stepTouchesProjectBranch(WorkflowDefinition definition, WorkflowStep step) {
    if (definition.project == null && step.project == null) return false;
    final resolved = resolveStepConfig(step, definition.stepDefaults, roleDefaults: _roleDefaults);
    if (!_shouldBindWorkflowProject(definition, step, resolved)) return false;
    if (step.isForeachController || step.contextOutputs.contains('project_index')) return false;
    return !_stepIsReadOnly(step, resolved);
  }

  String _continueSessionRootStepId(WorkflowDefinition definition, WorkflowStep step) =>
      _resolveContinueSessionRootStep(definition, step)?.id ?? step.id;

  Future<String?> _promoteWorkflowTask({
    required WorkflowRun run,
    required WorkflowStep step,
    required Task task,
    required WorkflowContext context,
    required Map<String, dynamic> outputs,
    required String? projectId,
    required String promotionStrategy,
  }) async {
    if (task.type != TaskType.coding || promotionStrategy == 'none') {
      return null;
    }

    final promote = _turnAdapter?.promoteWorkflowBranch;
    if (promote == null) {
      outputs['${step.id}.promotion'] = 'failed';
      return 'promotion failed: host promotion callback is not configured';
    }

    final promotionProjectId = projectId?.trim();
    if (promotionProjectId == null || promotionProjectId.isEmpty) {
      outputs['${step.id}.promotion'] = 'failed';
      return 'promotion failed: step has no project binding';
    }

    final branch = (task.worktreeJson?['branch'] as String?)?.trim();
    if (branch == null || branch.isEmpty) {
      outputs['${step.id}.promotion'] = 'failed';
      return 'promotion failed: task worktree branch is unavailable';
    }

    final integrationBranch = (context['_workflow.git.integration_branch'] as String?)?.trim();
    if (integrationBranch == null || integrationBranch.isEmpty) {
      outputs['${step.id}.promotion'] = 'failed';
      return 'promotion failed: integration branch is not initialized';
    }

    final promotionResult = await promote(
      runId: run.id,
      projectId: promotionProjectId,
      branch: branch,
      integrationBranch: integrationBranch,
      strategy: promotionStrategy,
    );

    switch (promotionResult) {
      case WorkflowGitPromotionSuccess(:final commitSha):
        outputs['${step.id}.promotion'] = 'success';
        outputs['${step.id}.promotion_sha'] = commitSha;
        return null;
      case WorkflowGitPromotionConflict(:final conflictingFiles, :final details):
        outputs['${step.id}.promotion'] = 'conflict';
        outputs['${step.id}.promotion_details'] = details;
        final summary = conflictingFiles.isEmpty ? 'merge conflict' : conflictingFiles.join(', ');
        return 'promotion-conflict: $summary';
      case WorkflowGitPromotionError(:final message):
        outputs['${step.id}.promotion'] = 'failed';
        return 'promotion failed: $message';
    }
  }

  Map<String, dynamic> _normalizeWorkflowOutputs(
    WorkflowRun run,
    WorkflowStep step,
    Map<String, dynamic> outputs,
    WorkflowContext context,
  ) {
    if (!outputs.containsKey('story_specs')) {
      return outputs;
    }

    final rawStorySpecs = outputs['story_specs'];
    if (rawStorySpecs is! Map<String, dynamic>) {
      return outputs;
    }
    final rawItems = rawStorySpecs['items'];
    if (rawItems is! List) {
      return outputs;
    }

    final planPath = (outputs['plan'] as String?)?.trim();
    final planDir = (planPath == null || planPath.isEmpty) ? '' : p.dirname(planPath);
    final projectIndex = context['project_index'];
    final projectRoot = switch (projectIndex) {
      final Map<dynamic, dynamic> map => map['project_root'] as String?,
      _ => null,
    };

    final seenSpecPaths = <String, int>{};
    final duplicateSpecPaths = <String>{};
    final missingSpecPaths = <String>[];
    final normalizedItems = <Map<String, dynamic>>[];

    for (final item in rawItems) {
      final itemMap = switch (item) {
        final Map<String, dynamic> typed => Map<String, dynamic>.from(typed),
        final Map<dynamic, dynamic> dynamicMap => dynamicMap.map((key, value) => MapEntry('$key', value)),
        _ => <String, dynamic>{},
      };
      final rawSpecPath = (itemMap['spec_path'] as String?)?.trim();
      if (rawSpecPath != null && rawSpecPath.isNotEmpty) {
        final normalizedSpecPath = _normalizeStorySpecPath(rawSpecPath, planDir);
        itemMap['spec_path'] = normalizedSpecPath;
        final priorCount = seenSpecPaths.update(normalizedSpecPath, (count) => count + 1, ifAbsent: () => 1);
        if (priorCount > 1) {
          duplicateSpecPaths.add(normalizedSpecPath);
        }
        if (projectRoot != null && projectRoot.isNotEmpty) {
          final candidate = File(p.join(projectRoot, normalizedSpecPath));
          if (!candidate.existsSync()) {
            missingSpecPaths.add(normalizedSpecPath);
          }
        }
      }
      normalizedItems.add(itemMap);
    }

    if (duplicateSpecPaths.isNotEmpty) {
      _log.warning(
        "Workflow '${run.id}': step '${step.id}' produced duplicate story_specs.spec_path values: "
        '${duplicateSpecPaths.toList()..sort()}',
      );
    }
    if (missingSpecPaths.isNotEmpty) {
      _log.warning(
        "Workflow '${run.id}': step '${step.id}' produced story_specs.spec_path values that do not exist on disk: "
        '${missingSpecPaths.toList()..sort()}',
      );
    }

    return {
      ...outputs,
      'story_specs': {...rawStorySpecs, 'items': normalizedItems},
    };
  }

  String _normalizeStorySpecPath(String specPath, String planDir) {
    if (specPath.isEmpty) return specPath;
    if (p.isAbsolute(specPath)) return p.normalize(specPath);
    if (planDir.isEmpty || planDir == '.') return p.normalize(specPath);
    return p.normalize(p.join(planDir, specPath));
  }

  bool _isPromotionAwareScope(
    WorkflowGitStrategy? strategy, {
    required String resolvedWorktreeMode,
    required bool hasCodingSteps,
  }) {
    if (!hasCodingSteps) return false;
    return resolvedWorktreeMode == 'per-map-item' &&
        _effectivePromotion(strategy, resolvedWorktreeMode: resolvedWorktreeMode) != 'none';
  }

  bool _requiresPerMapItemBootstrap(WorkflowDefinition definition, WorkflowContext context) {
    final strategy = definition.gitStrategy;
    if (strategy == null) return false;
    for (final step in definition.steps.where((candidate) => candidate.mapOver != null)) {
      int? maxParallel;
      try {
        maxParallel = _resolveMaxParallel(step.maxParallel, context, step.id);
      } on ArgumentError {
        maxParallel = 2;
      }
      final resolvedMode = strategy.effectiveWorktreeMode(maxParallel: maxParallel, isMap: true);
      if (resolvedMode == 'per-map-item') {
        return true;
      }
    }
    return false;
  }

  /// Returns true if the workflow-level budget has been exceeded.
  bool _workflowBudgetExceeded(WorkflowRun run, WorkflowDefinition definition) {
    if (definition.maxTokens == null) return false;
    return run.totalTokens >= definition.maxTokens!;
  }

  /// Returns the workflow workspace directory used for task behavior injection.
  ///
  /// Custom workflow workspaces are supplied by the turn adapter. When no
  /// custom workspace is configured, materializes the built-in workflow
  /// workspace under `<dataDir>/workflow-workspace`.
  String _resolveWorkflowWorkspaceDir() {
    final cached = _workflowWorkspaceDirCache;
    if (cached != null) return cached;

    final defaultDir = p.join(_dataDir, 'workflow-workspace');
    final configuredDir = _turnAdapter?.workflowWorkspaceDir?.trim();
    final resolvedDir = (configuredDir == null || configuredDir.isEmpty) ? defaultDir : configuredDir;

    if (resolvedDir == defaultDir) {
      final dir = Directory(resolvedDir);
      final agentsPath = p.join(resolvedDir, 'AGENTS.md');
      dir.createSync(recursive: true);
      final file = File(agentsPath);
      if (!file.existsSync() || file.readAsStringSync() != builtInWorkflowAgentsMd) {
        file.writeAsStringSync(builtInWorkflowAgentsMd);
      }
    }

    _workflowWorkspaceDirCache = resolvedDir;
    return resolvedDir;
  }

  /// Fires a warning event when the workflow reaches 80% of its token budget.
  ///
  /// Deduplicated via `_budget.warningFired` in [run.contextJson] — fires once per run.
  /// Returns updated [run] if the flag was set, otherwise returns [run] unchanged.
  Future<WorkflowRun> _checkWorkflowBudgetWarning(WorkflowRun run, WorkflowDefinition definition) async {
    if (definition.maxTokens == null) return run;
    if (run.contextJson['_budget.warningFired'] == true) return run;
    final threshold = (definition.maxTokens! * 0.8).toInt();
    if (run.totalTokens < threshold) return run;

    _eventBus.fire(
      WorkflowBudgetWarningEvent(
        runId: run.id,
        definitionName: run.definitionName,
        consumedPercent: run.totalTokens / definition.maxTokens!,
        consumed: run.totalTokens,
        limit: definition.maxTokens!,
        timestamp: DateTime.now(),
      ),
    );
    _log.info(
      "Workflow '${run.id}': budget warning — "
      '${run.totalTokens}/${definition.maxTokens} tokens '
      '(${(run.totalTokens / definition.maxTokens! * 100).toStringAsFixed(0)}%)',
    );

    // Persist dedupe flag.
    run = run.copyWith(contextJson: {...run.contextJson, '_budget.warningFired': true}, updatedAt: DateTime.now());
    await _repository.update(run);
    return run;
  }

  /// Reads the step's cumulative token count from session KV or task metadata.
  ///
  /// For [continueSession] steps, subtracts the baseline stored in
  /// [Task.configJson]['_sessionBaselineTokens'] so workflow totals only reflect
  /// new turns, not the full shared-session history.
  Future<int> _readStepTokenCount(Task task) async {
    if (task.sessionId == null) return 0;
    try {
      final total = await _readSessionTokens(task.sessionId!);
      final baseline = (task.configJson['_sessionBaselineTokens'] as num?)?.toInt() ?? 0;
      return (total - baseline).clamp(0, double.maxFinite).toInt();
    } catch (_) {
      return 0;
    }
  }

  /// Reads the raw cumulative token total for [sessionId] from KV store.
  Future<int> _readSessionTokens(String sessionId) async {
    try {
      final raw = await _kvService.get('session_cost:$sessionId');
      if (raw == null) return 0;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return (json['total_tokens'] as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  String? _resolveProjectId(
    WorkflowDefinition definition,
    WorkflowStep step,
    WorkflowContext context, {
    required ResolvedStepConfig resolved,
  }) {
    final explicitProject = _resolveProjectTemplate(step.project, context);
    if (explicitProject != null) return explicitProject;
    if (!_shouldBindWorkflowProject(definition, step, resolved)) {
      return null;
    }
    return _resolveProjectTemplate(definition.project, context);
  }

  String? _resolveProjectIdWithMap(
    WorkflowDefinition definition,
    WorkflowStep step,
    WorkflowContext context,
    MapContext mapContext, {
    required ResolvedStepConfig resolved,
  }) {
    final explicitProject = _resolveProjectTemplateWithMap(step.project, context, mapContext);
    if (explicitProject != null) return explicitProject;
    if (!_shouldBindWorkflowProject(definition, step, resolved)) {
      return null;
    }
    return _resolveProjectTemplateWithMap(definition.project, context, mapContext);
  }

  String? _resolveProjectTemplate(String? template, WorkflowContext context) {
    if (template == null) return null;
    final resolved = _templateEngine.resolve(template, context).trim();
    return resolved.isEmpty ? null : resolved;
  }

  String? _resolveProjectTemplateWithMap(String? template, WorkflowContext context, MapContext mapContext) {
    if (template == null) return null;
    final resolved = _templateEngine.resolveWithMap(template, context, mapContext).trim();
    return resolved.isEmpty ? null : resolved;
  }

  /// Resolves the effective provider for a continued session step.
  ///
  /// Session continuity requires the same provider family (e.g. both `codex`).
  /// If the current step's resolved provider matches the root step's family,
  /// the root's provider is used (the session thread belongs to it). If the
  /// families differ, the root's provider is used with a warning – the step
  /// cannot resume a thread from a different provider.
  ///
  /// The current step's **model** is preserved regardless – models can switch
  /// between turns within the same provider session.
  String? _resolveContinueSessionProvider(
    WorkflowDefinition definition,
    WorkflowStep step,
    WorkflowStep rootStep,
    ResolvedStepConfig resolved,
  ) {
    final rootResolved = resolveStepConfig(rootStep, definition.stepDefaults, roleDefaults: _roleDefaults);
    final rootProvider = rootResolved.provider;
    final stepProvider = resolved.provider;

    if (stepProvider != null && rootProvider != null) {
      final rootFamily = ProviderIdentity.family(rootProvider);
      final stepFamily = ProviderIdentity.family(stepProvider);
      if (rootFamily != stepFamily) {
        _log.warning(
          'Step "${step.id}" uses continueSession but its resolved provider "$stepProvider" '
          '(family: $stepFamily) differs from root step "${rootStep.id}" provider "$rootProvider" '
          '(family: $rootFamily). Falling back to root provider "$rootProvider" for session continuity.',
        );
      }
    }

    return rootProvider;
  }

  String? _resolveContinueSessionRootProviderSessionId(
    WorkflowDefinition definition,
    WorkflowStep step,
    WorkflowContext context,
  ) {
    final rootStep = _resolveContinueSessionRootStep(definition, step);
    if (rootStep == null) return null;
    final raw = context['${rootStep.id}.providerSessionId'];
    return raw is String && raw.isNotEmpty ? raw : null;
  }

  List<String> _buildOneShotFollowUpPrompts(
    WorkflowStep step,
    WorkflowContext context,
    Map<String, OutputConfig>? effectiveOutputs, {
    required List<String> contextOutputs,
    MapContext? mapCtx,
  }) {
    final prompts = step.prompts;
    if (prompts == null || prompts.length < 2) return const [];

    final followUps = <String>[];
    for (var i = 1; i < prompts.length; i++) {
      final isLast = i == prompts.length - 1;
      final resolvedPrompt = _templateEngine.resolveWithMap(prompts[i], context, mapCtx);
      final built = isLast
          ? _skillPromptBuilder.build(
              skill: null,
              resolvedPrompt: resolvedPrompt,
              outputs: effectiveOutputs,
              contextOutputs: contextOutputs,
              emitStepOutcomeProtocol: !step.emitsOwnOutcome,
            )
          : resolvedPrompt;
      followUps.add(built);
    }
    return followUps;
  }

  Map<String, dynamic>? _buildStructuredOutputEnvelopeSchema(WorkflowStep step) {
    final outputs = _effectiveOutputsFor(step);
    if (outputs == null || outputs.isEmpty) return null;

    final properties = <String, dynamic>{};
    final required = <String>[];

    for (final entry in outputs.entries) {
      final config = entry.value;
      final schema = switch (config.format) {
        OutputFormat.text || OutputFormat.path => const {'type': 'string'},
        OutputFormat.lines => const {
          'type': 'array',
          'items': {'type': 'string'},
        },
        OutputFormat.json => config.inlineSchema ?? schemaPresets[config.presetName]?.schema,
      };
      if (schema == null) continue;
      properties[entry.key] = schema;
      required.add(entry.key);
    }

    if (properties.isEmpty) return null;
    return {'type': 'object', 'additionalProperties': false, 'required': required, 'properties': properties};
  }

  WorkflowStep? _resolveContinueSessionRootStep(WorkflowDefinition definition, WorkflowStep step) {
    final visited = <String>{step.id};
    var current = step;

    while (current.continueSession != null) {
      final targetStepId = _resolveContinueSessionTargetStepId(definition, current);
      if (targetStepId == null || !visited.add(targetStepId)) {
        return null;
      }
      final targetStep = definition.steps.where((candidate) => candidate.id == targetStepId).firstOrNull;
      if (targetStep == null) return null;
      if (targetStep.continueSession == null) return targetStep;
      current = targetStep;
    }

    return null;
  }

  String? _resolveContinueSessionRootSessionId(
    WorkflowDefinition definition,
    WorkflowStep step,
    WorkflowContext context,
  ) {
    final rootStep = _resolveContinueSessionRootStep(definition, step);
    if (rootStep == null) return null;
    final raw = context['${rootStep.id}.sessionId'];
    return raw is String && raw.isNotEmpty ? raw : null;
  }

  String? _resolveContinueSessionTargetStepId(WorkflowDefinition definition, WorkflowStep step) {
    final ref = step.continueSession;
    if (ref == null) return null;
    if (ref == '@previous') {
      final idx = definition.steps.indexWhere((candidate) => candidate.id == step.id);
      return idx > 0 ? definition.steps[idx - 1].id : null;
    }
    return ref;
  }

  void dispose() {
    for (final timer in _approvalTimers.values) {
      timer.cancel();
    }
    _approvalTimers.clear();
  }

  /// Persists [context] to `<dataDir>/workflows/runs/<runId>/context.json` atomically.
  Future<void> _persistContext(String runId, WorkflowContext context) async {
    final dir = Directory(p.join(_dataDir, 'workflows', 'runs', runId));
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, 'context.json'));
    await atomicWriteJson(file, context.toJson());
  }

  // ── Map step execution ─────────────────────────────────────────────────────

  /// Resolves the `maxParallel` field from `step.maxParallel` at runtime.
  ///
  /// - `null` → default 1 (sequential)
  /// - `int` → use directly
  /// - `"unlimited"` → `null` (no cap)
  /// - template string (e.g. `"{{MAX_PARALLEL}}"`) → resolve via [context] then parse
  ///
  /// Throws [ArgumentError] if the resolved value cannot be parsed as an integer.
  int? _resolveMaxParallel(Object? raw, WorkflowContext context, String stepId) {
    if (raw == null) return 1; // Default: sequential.
    if (raw is int) return raw;
    if (raw is! String) return 1;

    // Resolve template references if present.
    final resolved = raw.contains('{{') ? _templateEngine.resolve(raw, context) : raw;

    if (resolved.toLowerCase() == 'unlimited') return null;
    final parsed = int.tryParse(resolved.trim());
    if (parsed != null) return parsed;
    throw ArgumentError(
      "Map step '$stepId': maxParallel '$raw' resolved to '$resolved' "
      'which is not an integer or "unlimited".',
    );
  }

  /// Builds a structured coding task result from a completed [task].
  ///
  /// Returns a Map with `text`, `task_id`, `diff`, and `worktree` fields.
  /// `diff` and `worktree` may be null if not available.
  Future<Map<String, dynamic>> _buildCodingResult(Task task, Map<String, dynamic> outputs) async {
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
  /// failure). Returns a [_MapStepResult] on success or failure.
  Future<_MapStepResult?> _executeMapStep(
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
      return _MapStepResult(
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
        _log.info(
          'Map step \'${step.id}\': auto-unwrapped Map key \'${map.keys.first}\' '
          'to List (${(map.values.first as List).length} items)',
        );
        return map.values.first as List<dynamic>;
      }(),
      final Map<Object?, Object?> map when map.length == 1 && map.values.first is List => () {
        final normalized = map.map((key, value) => MapEntry(key.toString(), value));
        _log.info(
          'Map step \'${step.id}\': auto-unwrapped Map key \'${normalized.keys.first}\' '
          'to List (${(normalized.values.first as List).length} items)',
        );
        return normalized.values.first as List<dynamic>;
      }(),
      _ => null,
    };
    if (resolvedCollection == null) {
      return _MapStepResult(
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
      return _MapStepResult(
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
      return _MapStepResult(results: const [], totalTokens: 0, success: false, error: e.message.toString());
    }

    // 4. Empty collection → succeed immediately.
    if (collection.isEmpty) {
      _log.warning(
        "Workflow '${run.id}': map step '${step.id}' has empty collection — "
        'succeeding with empty result array',
      );
      return const _MapStepResult(results: [], totalTokens: 0, success: true);
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
        return _MapStepResult(
          results: const [],
          totalTokens: 0,
          success: false,
          error: "Map step '${step.id}': ${e.message}",
        );
      }
      if (promotionAware) {
        final unknownDeps = depGraph.unknownDependencyIds().toList()..sort();
        if (unknownDeps.isNotEmpty) {
          return _MapStepResult(
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
        _log.warning(
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
      return _MapStepResult(
        results: List<dynamic>.from(mapCtx.results),
        totalTokens: totalTokens,
        success: false,
        error: hasPromotionConflict
            ? "promotion-conflict: map step '${step.id}' has unresolved promotion conflicts"
            : "Map step '${step.id}': $failCount iteration(s) failed",
      );
    }

    return _MapStepResult(results: List<dynamic>.from(mapCtx.results), totalTokens: totalTokens, success: true);
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

  // ── Foreach step execution ──────────────────────────────────────────────────

  /// Executes a foreach step: iterates over a collection and runs an ordered sequence
  /// of child steps per item. Supports bounded concurrency across iterations.
  ///
  /// Returns null if the executor has already paused the run.
  /// Returns a [_MapStepResult] on success or failure.
  Future<_MapStepResult?> _executeForeachStep(
    WorkflowRun run,
    WorkflowDefinition definition,
    WorkflowStep controllerStep,
    List<String> childStepIds,
    WorkflowContext context, {
    required Map<String, WorkflowStep> stepById,
    required int stepIndex,
    WorkflowExecutionCursor? resumeCursor,
  }) async {
    // 1. Resolve collection from context.
    final rawCollection = context[controllerStep.mapOver!];
    if (rawCollection == null) {
      return _MapStepResult(
        results: const [],
        totalTokens: 0,
        success: false,
        error: "Foreach step '${controllerStep.id}': context key '${controllerStep.mapOver}' is null or missing",
      );
    }
    // Auto-unwrap: if the value is a Map containing a single key whose value
    // is a List, use that List. LLMs sometimes wrap arrays in an object like
    // {"stories": [{...}, {...}]} instead of returning the array directly.
    final resolvedCollection = switch (rawCollection) {
      final List<dynamic> list => list,
      final Map<String, dynamic> map when map.length == 1 && map.values.first is List => () {
        _log.info(
          'Foreach step \'${controllerStep.id}\': auto-unwrapped Map key \'${map.keys.first}\' '
          'to List (${(map.values.first as List).length} items)',
        );
        return map.values.first as List<dynamic>;
      }(),
      final Map<Object?, Object?> map when map.length == 1 && map.values.first is List => () {
        final normalized = map.map((key, value) => MapEntry(key.toString(), value));
        _log.info(
          'Foreach step \'${controllerStep.id}\': auto-unwrapped Map key \'${normalized.keys.first}\' '
          'to List (${(normalized.values.first as List).length} items)',
        );
        return normalized.values.first as List<dynamic>;
      }(),
      _ => null,
    };
    if (resolvedCollection == null) {
      return _MapStepResult(
        results: const [],
        totalTokens: 0,
        success: false,
        error:
            "Foreach step '${controllerStep.id}': context key '${controllerStep.mapOver}' is not a List "
            '(got ${rawCollection.runtimeType})',
      );
    }
    final collection = resolvedCollection;

    // 2. Check maxItems.
    if (collection.length > controllerStep.maxItems) {
      return _MapStepResult(
        results: const [],
        totalTokens: 0,
        success: false,
        error:
            "Foreach step '${controllerStep.id}': collection has ${collection.length} items "
            'which exceeds maxItems (${controllerStep.maxItems}). '
            'Consider decomposing into smaller batches.',
      );
    }

    // 3. Empty collection — succeed immediately.
    if (collection.isEmpty) {
      _log.warning(
        "Workflow '${run.id}': foreach step '${controllerStep.id}' has empty collection — "
        'succeeding with empty result array',
      );
      return const _MapStepResult(results: [], totalTokens: 0, success: true);
    }

    // 4. Resolve maxParallel (default 1 = sequential).
    final int? maxParallel;
    try {
      maxParallel = _resolveMaxParallel(controllerStep.maxParallel, context, controllerStep.id);
    } on ArgumentError catch (e) {
      return _MapStepResult(results: const [], totalTokens: 0, success: false, error: e.message.toString());
    }

    // 5. Resolve child steps.
    final childSteps = childStepIds.map((id) => stepById[id]).nonNulls.toList(growable: false);
    if (childSteps.length != childStepIds.length) {
      return _MapStepResult(
        results: const [],
        totalTokens: 0,
        success: false,
        error: "Foreach step '${controllerStep.id}': one or more child steps are missing from the definition",
      );
    }

    // 6. gitStrategy context.
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

    // 7. Create MapStepContext.
    final mapCtx = MapStepContext(collection: collection, maxParallel: maxParallel, maxItems: controllerStep.maxItems);
    _restoreForeachProgress(mapCtx, resumeCursor, collectionLength: collection.length);

    // 8. Persist initial progress.
    await _persistForeachProgress(run, controllerStep, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);

    // 9. Bounded concurrency dispatch loop.
    final inFlight = <int, Future<void>>{};
    final settledIndices = mapCtx.completedIndices;
    final pending = Queue<int>.from(
      List.generate(collection.length, (i) => i).where((i) => !settledIndices.contains(i)),
    );
    var totalTokens = 0;

    while (pending.isNotEmpty || inFlight.isNotEmpty) {
      if (mapCtx.budgetExhausted) {
        while (pending.isNotEmpty) {
          mapCtx.recordCancelled(pending.removeFirst(), 'Cancelled: budget exhausted');
        }
        await _persistForeachProgress(
          run,
          controllerStep,
          context,
          mapCtx,
          stepIndex: stepIndex,
          promotedIds: promotedIds,
        );
        break;
      }

      final poolAvailable = _turnAdapter?.availableRunnerCount?.call();
      final concurrencyCap = mapCtx.effectiveConcurrency(poolAvailable);
      while (inFlight.length < concurrencyCap && pending.isNotEmpty) {
        final iterIndex = pending.removeFirst();
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
        final effectiveProjectId = _resolveProjectIdWithMap(
          definition,
          controllerStep,
          context,
          mapContext,
          resolved: controllerResolved,
        );
        mapCtx.inFlightCount++;

        inFlight[iterIndex] =
            _dispatchForeachIteration(
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
            ).then((_) {
              inFlight.remove(iterIndex);
            });
      }

      if (inFlight.isEmpty && pending.isNotEmpty) {
        _log.warning(
          "Workflow '${run.id}': foreach step '${controllerStep.id}' — "
          '${pending.length} items stalled; cancelling.',
        );
        while (pending.isNotEmpty) {
          mapCtx.recordCancelled(pending.removeFirst(), 'Cancelled: dispatch stall');
        }
        await _persistForeachProgress(
          run,
          controllerStep,
          context,
          mapCtx,
          stepIndex: stepIndex,
          promotedIds: promotedIds,
        );
        break;
      }

      if (inFlight.isEmpty) break;

      await Future.any(inFlight.values);

      final refreshedRun = await _repository.getById(run.id) ?? run;
      run = refreshedRun;
      if (_workflowBudgetExceeded(run, definition)) {
        mapCtx.budgetExhausted = true;
      }

      await Future<void>.delayed(Duration.zero);
    }

    if (inFlight.isNotEmpty) {
      await Future.wait(inFlight.values, eagerError: false);
    }

    // 10. Accumulate total tokens from all child step token keys.
    for (var i = 0; i < collection.length; i++) {
      for (final childStep in childSteps) {
        final t = context['${childStep.id}[$i].tokenCount'];
        if (t is int) totalTokens += t;
      }
    }

    // 11. Fire MapStepCompletedEvent.
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

    // 12. Return result.
    if (mapCtx.hasFailures) {
      return _MapStepResult(
        results: List<dynamic>.from(mapCtx.results),
        totalTokens: totalTokens,
        success: false,
        error: "Foreach step '${controllerStep.id}': ${mapCtx.failedIndices.length} iteration(s) failed",
      );
    }

    return _MapStepResult(results: List<dynamic>.from(mapCtx.results), totalTokens: totalTokens, success: true);
  }

  /// Executes a single foreach iteration: runs each child step sequentially in a
  /// per-iteration context overlay. Records result in [mapCtx] and fires events.
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
  }) async {
    // Build per-iteration context overlay: starts with global context data + map variables.
    // Child steps can see each other's outputs within the iteration via this overlay.
    final iterData = Map<String, dynamic>.from(context.data);
    iterData['map.item'] = mapContext.item;
    iterData['map.index'] = mapContext.index;
    iterData['map.length'] = mapContext.length;
    final iterContext = WorkflowContext(data: iterData, variables: context.variables);

    int iterTokens = 0;
    Map<String, dynamic> iterResult = {};
    String? firstTaskId;

    // Run each child step sequentially.
    for (var childIndex = 0; childIndex < childSteps.length; childIndex++) {
      final childStep = childSteps[childIndex];
      final childStepIndex = definition.steps.indexOf(childStep);

      if (_shouldSkipDueToEntryGate(childStep, iterContext, run.id)) {
        continue;
      }

      final result = await _executeStep(
        run,
        definition,
        childStep,
        iterContext,
        stepIndex: childStepIndex,
        mapCtx: mapContext,
        enclosingMaxParallel: controllerMaxParallel,
      );

      if (result == null) {
        // _executeStep paused the run (task creation failure / approval / timeout).
        mapCtx.recordFailure(iterIndex, "Foreach child step '${childStep.id}' failed to create task", null);
        await _persistForeachProgress(
          run,
          controllerStep,
          context,
          mapCtx,
          stepIndex: stepIndex,
          promotedIds: promotedIds,
        );
        mapCtx.inFlightCount--;
        _eventBus.fire(
          MapIterationCompletedEvent(
            runId: run.id,
            stepId: controllerStep.id,
            iterationIndex: iterIndex,
            totalIterations: mapCtx.collection.length,
            itemId: mapCtx.itemId(iterIndex),
            taskId: firstTaskId ?? '',
            success: false,
            tokenCount: iterTokens,
            timestamp: DateTime.now(),
          ),
        );
        return;
      }

      if (childIndex == 0) firstTaskId = result.task?.id;
      final tokenCount = result.tokenCount;
      iterTokens += tokenCount;

      // Write indexed token count to global context for budget tracking.
      context['${childStep.id}[$iterIndex].tokenCount'] = tokenCount;

      if (!result.success) {
        // Propagate failure outputs to both iter context and global indexed keys.
        _mergeStepResultIntoContext(iterContext, result, fallbackStatus: 'failed');
        for (final entry in result.outputs.entries) {
          context['${childStep.id}[$iterIndex].${entry.key}'] = entry.value;
        }
        context['${childStep.id}[$iterIndex].status'] = iterContext['${childStep.id}.status'];
        if (result.outcome != null) {
          context['step.${childStep.id}[$iterIndex].outcome'] = result.outcome!;
        }
        if (result.outcomeReason != null && result.outcomeReason!.isNotEmpty) {
          context['step.${childStep.id}[$iterIndex].outcome.reason'] = result.outcomeReason!;
        }

        mapCtx.recordFailure(iterIndex, "Foreach child step '${childStep.id}' failed", result.task?.id);
        await _persistForeachProgress(
          run,
          controllerStep,
          context,
          mapCtx,
          stepIndex: stepIndex,
          promotedIds: promotedIds,
        );
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
            tokenCount: tokenCount,
            timestamp: DateTime.now(),
          ),
        );
        if (result.awaitingApproval) {
          await _transitionStepAwaitingApproval(
            run,
            childStep,
            context,
            stepIndex: childStepIndex,
            reason: result.outcomeReason ?? "Foreach child step '${childStep.id}' requires input",
          );
        }
        _eventBus.fire(
          MapIterationCompletedEvent(
            runId: run.id,
            stepId: controllerStep.id,
            iterationIndex: iterIndex,
            totalIterations: mapCtx.collection.length,
            itemId: mapCtx.itemId(iterIndex),
            taskId: firstTaskId ?? '',
            success: false,
            tokenCount: iterTokens,
            timestamp: DateTime.now(),
          ),
        );
        return;
      }

      // Child step succeeded — merge outputs into iteration context and global indexed keys.
      // Sibling child steps read each other's outputs via their declared context
      // keys (bare keys in the iteration overlay); step-prefixed aliases must be
      // declared explicitly via `contextOutputs: [<stepId>.<key>]`.
      _mergeStepResultIntoContext(iterContext, result, fallbackStatus: result.task?.status.name ?? 'completed');

      for (final entry in result.outputs.entries) {
        context['${childStep.id}[$iterIndex].${entry.key}'] = entry.value;
      }
      context['${childStep.id}[$iterIndex].status'] = iterContext['${childStep.id}.status'];
      context['${childStep.id}[$iterIndex].tokenCount'] = tokenCount;
      if (result.outcome != null) {
        context['step.${childStep.id}[$iterIndex].outcome'] = result.outcome!;
      }
      if (result.outcomeReason != null && result.outcomeReason!.isNotEmpty) {
        context['step.${childStep.id}[$iterIndex].outcome.reason'] = result.outcomeReason!;
      }

      // Accumulate per-iteration outputs for the aggregate result.
      iterResult[childStep.id] = Map<String, dynamic>.from(result.outputs);

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
        ),
      );
    }

    // All child steps succeeded — handle worktree promotion before recording result.
    if (promotionAware) {
      // Find the child step that actually produced the promoted branch.
      final branchStep = childSteps.firstWhere(
        (step) => ((iterContext['${step.id}.branch'] as String?)?.trim().isNotEmpty ?? false),
        orElse: () => childSteps.first,
      );
      final storyBranch = (iterContext['${branchStep.id}.branch'] as String?)?.trim();
      final promote = _turnAdapter?.promoteWorkflowBranch;
      final storyId = mapCtx.itemId(iterIndex);

      if (promote == null) {
        mapCtx.recordFailure(iterIndex, 'promotion failed: host promotion callback is not configured', firstTaskId);
        await _persistForeachProgress(
          run,
          controllerStep,
          context,
          mapCtx,
          stepIndex: stepIndex,
          promotedIds: promotedIds,
        );
        mapCtx.inFlightCount--;
        _eventBus.fire(
          MapIterationCompletedEvent(
            runId: run.id,
            stepId: controllerStep.id,
            iterationIndex: iterIndex,
            totalIterations: mapCtx.collection.length,
            itemId: storyId,
            taskId: firstTaskId ?? '',
            success: false,
            tokenCount: iterTokens,
            timestamp: DateTime.now(),
          ),
        );
        return;
      }
      if (projectId == null || projectId.isEmpty) {
        mapCtx.recordFailure(iterIndex, 'promotion failed: foreach iteration has no project binding', firstTaskId);
        await _persistForeachProgress(
          run,
          controllerStep,
          context,
          mapCtx,
          stepIndex: stepIndex,
          promotedIds: promotedIds,
        );
        mapCtx.inFlightCount--;
        _eventBus.fire(
          MapIterationCompletedEvent(
            runId: run.id,
            stepId: controllerStep.id,
            iterationIndex: iterIndex,
            totalIterations: mapCtx.collection.length,
            itemId: storyId,
            taskId: firstTaskId ?? '',
            success: false,
            tokenCount: iterTokens,
            timestamp: DateTime.now(),
          ),
        );
        return;
      }
      if (storyBranch == null || storyBranch.isEmpty) {
        mapCtx.recordFailure(iterIndex, 'promotion failed: task worktree branch is unavailable', firstTaskId);
        await _persistForeachProgress(
          run,
          controllerStep,
          context,
          mapCtx,
          stepIndex: stepIndex,
          promotedIds: promotedIds,
        );
        mapCtx.inFlightCount--;
        _eventBus.fire(
          MapIterationCompletedEvent(
            runId: run.id,
            stepId: controllerStep.id,
            iterationIndex: iterIndex,
            totalIterations: mapCtx.collection.length,
            itemId: storyId,
            taskId: firstTaskId ?? '',
            success: false,
            tokenCount: iterTokens,
            timestamp: DateTime.now(),
          ),
        );
        return;
      }
      if (integrationBranch == null || integrationBranch.isEmpty) {
        mapCtx.recordFailure(iterIndex, 'promotion failed: integration branch is not initialized', firstTaskId);
        await _persistForeachProgress(
          run,
          controllerStep,
          context,
          mapCtx,
          stepIndex: stepIndex,
          promotedIds: promotedIds,
        );
        mapCtx.inFlightCount--;
        _eventBus.fire(
          MapIterationCompletedEvent(
            runId: run.id,
            stepId: controllerStep.id,
            iterationIndex: iterIndex,
            totalIterations: mapCtx.collection.length,
            itemId: storyId,
            taskId: firstTaskId ?? '',
            success: false,
            tokenCount: iterTokens,
            timestamp: DateTime.now(),
          ),
        );
        return;
      }

      final promotionResult = await promote(
        runId: run.id,
        projectId: projectId,
        branch: storyBranch,
        integrationBranch: integrationBranch,
        strategy: promotionStrategy,
        storyId: storyId,
      );
      switch (promotionResult) {
        case WorkflowGitPromotionSuccess(:final commitSha):
          if (storyId != null && storyId.isNotEmpty) promotedIds.add(storyId);
          context['${controllerStep.id}[$iterIndex].promotion'] = 'success';
          context['${controllerStep.id}[$iterIndex].promotion_sha'] = commitSha;
        case WorkflowGitPromotionConflict(:final conflictingFiles, :final details):
          final conflictMsg =
              'promotion-conflict: ${conflictingFiles.isEmpty ? 'merge conflict' : conflictingFiles.join(', ')}';
          context['${controllerStep.id}[$iterIndex].promotion'] = 'conflict';
          context['${controllerStep.id}[$iterIndex].promotion_details'] = details;
          mapCtx.recordFailure(iterIndex, conflictMsg, firstTaskId);
          await _persistForeachProgress(
            run,
            controllerStep,
            context,
            mapCtx,
            stepIndex: stepIndex,
            promotedIds: promotedIds,
          );
          mapCtx.inFlightCount--;
          _eventBus.fire(
            MapIterationCompletedEvent(
              runId: run.id,
              stepId: controllerStep.id,
              iterationIndex: iterIndex,
              totalIterations: mapCtx.collection.length,
              itemId: storyId,
              taskId: firstTaskId ?? '',
              success: false,
              tokenCount: iterTokens,
              timestamp: DateTime.now(),
            ),
          );
          return;
        case WorkflowGitPromotionError(:final message):
          context['${controllerStep.id}[$iterIndex].promotion'] = 'failed';
          mapCtx.recordFailure(iterIndex, 'promotion failed: $message', firstTaskId);
          await _persistForeachProgress(
            run,
            controllerStep,
            context,
            mapCtx,
            stepIndex: stepIndex,
            promotedIds: promotedIds,
          );
          mapCtx.inFlightCount--;
          _eventBus.fire(
            MapIterationCompletedEvent(
              runId: run.id,
              stepId: controllerStep.id,
              iterationIndex: iterIndex,
              totalIterations: mapCtx.collection.length,
              itemId: storyId,
              taskId: firstTaskId ?? '',
              success: false,
              tokenCount: iterTokens,
              timestamp: DateTime.now(),
            ),
          );
          return;
      }
    }

    // Record successful iteration aggregate result.
    mapCtx.recordResult(iterIndex, iterResult);
    await _persistForeachProgress(run, controllerStep, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
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

  /// Restores foreach progress from a persisted cursor into [mapCtx].
  void _restoreForeachProgress(
    MapStepContext mapCtx,
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
    }
  }

  /// Persists foreach cursor and progress markers into the run record.
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
    );

    final updatedRun = refreshedRun.copyWith(
      executionCursor: cursor,
      contextJson: {
        for (final e in refreshedRun.contextJson.entries)
          if (e.key.startsWith('_') && !e.key.startsWith('_foreach.current')) e.key: e.value,
        ...context.toJson(),
        '_foreach.current.stepId': step.id,
        '_foreach.current.total': mapCtx.collection.length,
        '_foreach.current.completedIndices': cursor.completedIndices,
        '_foreach.current.failedIndices': cursor.failedIndices,
        '_foreach.current.cancelledIndices': cursor.cancelledIndices,
        '_map.${step.id}.promotedIds': context['_map.${step.id}.promotedIds'],
      },
      updatedAt: DateTime.now(),
    );

    await _repository.update(updatedRun);
  }

  /// Executes a single map iteration: creates a task, awaits completion,
  /// extracts outputs, records result in [mapCtx], fires [MapIterationCompletedEvent].
  Future<void> _dispatchIteration({
    required WorkflowRun run,
    required WorkflowDefinition definition,
    required WorkflowStep step,
    required int stepIndex,
    required int iterIndex,
    required String iterPrompt,
    required String iterTitle,
    required Map<String, dynamic> taskConfig,
    required String? projectId,
    required ResolvedStepConfig resolved,
    required MapStepContext mapCtx,
    required WorkflowContext context,
    required bool promotionAware,
    required String? integrationBranch,
    required String promotionStrategy,
    required Set<String> promotedIds,
  }) async {
    final taskId = _uuid.v4();

    // Subscribe before create to avoid race condition.
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
      final mapTaskConfig = {
        ...taskConfig,
        '_mapStepId': step.id,
        '_mapIterationIndex': iterIndex,
        '_mapIterationTotal': mapCtx.collection.length,
      };
      await _createWorkflowTaskTriple(
        taskId: taskId,
        run: run,
        step: step,
        stepIndex: stepIndex,
        title: iterTitle,
        description: iterPrompt,
        type: TaskType.coding,
        provider: resolved.provider,
        projectId: projectId,
        maxTokens: resolved.maxTokens,
        maxRetries: resolved.maxRetries ?? 0,
        taskConfig: mapTaskConfig,
      );
    } catch (e, st) {
      await sub.cancel();
      _log.severe(
        "Workflow '${run.id}': map step '${step.id}' iteration $iterIndex "
        'failed to create task: $e',
        e,
        st,
      );
      mapCtx.recordFailure(iterIndex, 'Failed to create task: $e', null);
      mapCtx.inFlightCount--;
      _eventBus.fire(
        MapIterationCompletedEvent(
          runId: run.id,
          stepId: step.id,
          iterationIndex: iterIndex,
          totalIterations: mapCtx.collection.length,
          itemId: mapCtx.itemId(iterIndex),
          taskId: taskId,
          success: false,
          tokenCount: 0,
          timestamp: DateTime.now(),
        ),
      );
      await _persistMapProgress(run, step, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
      return;
    }

    late Task finalTask;
    try {
      finalTask = await _waitForTaskCompletion(taskId, step, completer, sub, runId: run.id);
    } on TimeoutException {
      _log.warning(
        "Workflow '${run.id}': map step '${step.id}' iteration $iterIndex "
        'timed out after ${step.timeoutSeconds}s',
      );
      mapCtx.recordFailure(iterIndex, 'Timed out after ${step.timeoutSeconds}s', taskId);
      mapCtx.inFlightCount--;
      _eventBus.fire(
        MapIterationCompletedEvent(
          runId: run.id,
          stepId: step.id,
          iterationIndex: iterIndex,
          totalIterations: mapCtx.collection.length,
          itemId: mapCtx.itemId(iterIndex),
          taskId: taskId,
          success: false,
          tokenCount: 0,
          timestamp: DateTime.now(),
        ),
      );
      await _persistMapProgress(run, step, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
      return;
    } catch (e, st) {
      _log.severe(
        "Workflow '${run.id}': map step '${step.id}' iteration $iterIndex "
        'wait failed: $e',
        e,
        st,
      );
      mapCtx.recordFailure(iterIndex, 'Unexpected error: $e', taskId);
      mapCtx.inFlightCount--;
      _eventBus.fire(
        MapIterationCompletedEvent(
          runId: run.id,
          stepId: step.id,
          iterationIndex: iterIndex,
          totalIterations: mapCtx.collection.length,
          itemId: mapCtx.itemId(iterIndex),
          taskId: taskId,
          success: false,
          tokenCount: 0,
          timestamp: DateTime.now(),
        ),
      );
      await _persistMapProgress(run, step, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
      return;
    }

    final taskFailed = finalTask.status == TaskStatus.failed || finalTask.status == TaskStatus.cancelled;

    int tokenCount = 0;
    if (!taskFailed) {
      tokenCount = await _readStepTokenCount(finalTask);
      Map<String, dynamic> outputs = {};
      void persistIterationOutputs() {
        for (final entry in outputs.entries) {
          context['${step.id}[$iterIndex].${entry.key}'] = entry.value;
        }
        context['${step.id}[$iterIndex].tokenCount'] = tokenCount;
      }

      void emitIterationFailure() {
        _eventBus.fire(
          MapIterationCompletedEvent(
            runId: run.id,
            stepId: step.id,
            iterationIndex: iterIndex,
            totalIterations: mapCtx.collection.length,
            itemId: mapCtx.itemId(iterIndex),
            taskId: taskId,
            success: false,
            tokenCount: tokenCount,
            timestamp: DateTime.now(),
          ),
        );
      }

      try {
        outputs = await _contextExtractor.extract(step, finalTask, effectiveOutputs: _effectiveOutputsFor(step));
      } catch (e, st) {
        _log.warning(
          "Workflow '${run.id}': context extraction failed for map step '${step.id}' "
          'iteration $iterIndex: $e',
          e,
          st,
        );
      }

      // Build result value.
      dynamic resultValue;
      if (finalTask.configJson['_workflowNeedsWorktree'] == true || finalTask.worktreeJson != null) {
        resultValue = await _buildCodingResult(finalTask, outputs);
      } else if (outputs.length == 1) {
        resultValue = outputs.values.first;
      } else {
        resultValue = outputs;
      }

      if (promotionAware) {
        final storyBranch = (finalTask.worktreeJson?['branch'] as String?)?.trim();
        final promote = _turnAdapter?.promoteWorkflowBranch;
        final branch = storyBranch;
        final promotionProjectId = projectId?.trim();
        final storyId = mapCtx.itemId(iterIndex);
        if (promote == null) {
          persistIterationOutputs();
          mapCtx.recordFailure(iterIndex, 'promotion failed: host promotion callback is not configured', taskId);
          await _persistMapProgress(run, step, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
          mapCtx.inFlightCount--;
          emitIterationFailure();
          return;
        }
        if (promotionProjectId == null || promotionProjectId.isEmpty) {
          persistIterationOutputs();
          mapCtx.recordFailure(iterIndex, 'promotion failed: map iteration has no project binding', taskId);
          await _persistMapProgress(run, step, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
          mapCtx.inFlightCount--;
          emitIterationFailure();
          return;
        }
        if (branch == null || branch.isEmpty) {
          persistIterationOutputs();
          mapCtx.recordFailure(iterIndex, 'promotion failed: task worktree branch is unavailable', taskId);
          await _persistMapProgress(run, step, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
          mapCtx.inFlightCount--;
          emitIterationFailure();
          return;
        }
        if (integrationBranch == null || integrationBranch.isEmpty) {
          persistIterationOutputs();
          mapCtx.recordFailure(iterIndex, 'promotion failed: integration branch is not initialized', taskId);
          await _persistMapProgress(run, step, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
          mapCtx.inFlightCount--;
          emitIterationFailure();
          return;
        }

        final promotionResult = await promote(
          runId: run.id,
          projectId: promotionProjectId,
          branch: branch,
          integrationBranch: integrationBranch,
          strategy: promotionStrategy,
          storyId: storyId,
        );
        switch (promotionResult) {
          case WorkflowGitPromotionSuccess(:final commitSha):
            if (storyId != null && storyId.isNotEmpty) {
              promotedIds.add(storyId);
            }
            context['${step.id}[$iterIndex].promotion'] = 'success';
            context['${step.id}[$iterIndex].promotion_sha'] = commitSha;
          case WorkflowGitPromotionConflict(:final conflictingFiles, :final details):
            final conflictMessage =
                'promotion-conflict: ${conflictingFiles.isEmpty ? 'merge conflict' : conflictingFiles.join(', ')}';
            context['${step.id}[$iterIndex].promotion'] = 'conflict';
            context['${step.id}[$iterIndex].promotion_details'] = details;
            persistIterationOutputs();
            mapCtx.recordFailure(iterIndex, conflictMessage, taskId);
            await _persistMapProgress(run, step, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
            mapCtx.inFlightCount--;
            emitIterationFailure();
            return;
          case WorkflowGitPromotionError(:final message):
            context['${step.id}[$iterIndex].promotion'] = 'failed';
            persistIterationOutputs();
            mapCtx.recordFailure(iterIndex, 'promotion failed: $message', taskId);
            await _persistMapProgress(run, step, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);
            mapCtx.inFlightCount--;
            emitIterationFailure();
            return;
        }
      }

      // Persist per-iteration outputs (extraction results, token counts, status).
      persistIterationOutputs();
      mapCtx.recordResult(iterIndex, resultValue);
    } else {
      final reason = finalTask.configJson['failReason'] as String?;
      final msg = reason ?? finalTask.status.name;
      mapCtx.recordFailure(iterIndex, msg, taskId);
    }

    await _persistMapProgress(run, step, context, mapCtx, stepIndex: stepIndex, promotedIds: promotedIds);

    mapCtx.inFlightCount--;

    _eventBus.fire(
      MapIterationCompletedEvent(
        runId: run.id,
        stepId: step.id,
        iterationIndex: iterIndex,
        totalIterations: mapCtx.collection.length,
        itemId: mapCtx.itemId(iterIndex),
        taskId: taskId,
        success: !taskFailed,
        tokenCount: tokenCount,
        timestamp: DateTime.now(),
      ),
    );
  }

  Future<String?> _initializeWorkflowGit(
    WorkflowRun run,
    WorkflowDefinition definition,
    WorkflowContext context,
  ) async {
    final strategy = definition.gitStrategy;
    if (strategy == null || strategy.bootstrap != true) return null;
    final adapter = _turnAdapter;
    final bootstrap = adapter?.bootstrapWorkflowGit;
    if (bootstrap == null) return null;

    final projectId = _workflowProjectId(run, context);
    if (projectId == null || projectId.isEmpty) return null;
    final baseRef = (context.variables['BRANCH']?.trim().isNotEmpty ?? false)
        ? context.variables['BRANCH']!.trim()
        : '';

    try {
      final result = await bootstrap(
        runId: run.id,
        projectId: projectId,
        baseRef: baseRef,
        perMapItem: _requiresPerMapItemBootstrap(definition, context),
      );
      context['_workflow.git.integration_branch'] = result.integrationBranch;
      if (result.note != null && result.note!.isNotEmpty) {
        context['_workflow.git.note'] = result.note!;
      }
      await _persistContext(run.id, context);
      final refreshedRun = await _repository.getById(run.id) ?? run;
      await _repository.update(
        refreshedRun.copyWith(
          contextJson: {
            for (final e in refreshedRun.contextJson.entries)
              if (e.key.startsWith('_')) e.key: e.value,
            ...context.toJson(),
          },
          updatedAt: DateTime.now(),
        ),
      );
      return null;
    } catch (e) {
      return 'workflow git bootstrap failed: $e';
    }
  }

  String? _workflowProjectId(WorkflowRun run, WorkflowContext context) {
    final fromContext = context.variables['PROJECT']?.trim();
    if (fromContext != null && fromContext.isNotEmpty) return fromContext;
    final fromRun = run.variablesJson['PROJECT']?.trim();
    if (fromRun != null && fromRun.isNotEmpty) return fromRun;
    return null;
  }

  /// Transitions the workflow run to failed and fires status changed event.
  Future<void> _failRun(WorkflowRun run, String reason) async {
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
  }

  /// Transitions the workflow run to completed and fires status changed event.
  Future<void> _completeRun(WorkflowRun run, WorkflowDefinition definition, WorkflowContext context) async {
    final publishStrategy = definition.gitStrategy?.publish;
    if (publishStrategy?.enabled == true) {
      final publishError = await _runDeterministicPublish(run, definition, context);
      if (publishError != null) {
        await _failRun(run, publishError);
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
    await _cleanupWorkflowGit(completed, preserveWorktrees: false);
    _log.info("Workflow '${run.definitionName}' (${run.id}) completed successfully");
  }

  Future<String?> _runDeterministicPublish(
    WorkflowRun run,
    WorkflowDefinition definition,
    WorkflowContext context,
  ) async {
    final adapter = _turnAdapter;
    final publish = adapter?.publishWorkflowBranch;
    if (publish == null) {
      return 'workflow publish is enabled but host publish callback is not configured';
    }

    final projectId = _workflowProjectId(run, context);
    if (projectId == null || projectId.isEmpty) {
      return 'workflow publish requires PROJECT to be set';
    }

    final branch = (context['_workflow.git.integration_branch'] as String?)?.trim().isNotEmpty == true
        ? (context['_workflow.git.integration_branch'] as String).trim()
        : ((context.variables['BRANCH']?.trim().isNotEmpty ?? false) ? context.variables['BRANCH']!.trim() : '');
    if (branch.isEmpty) {
      return 'workflow publish could not resolve a branch to publish';
    }

    _log.info("Workflow '${run.id}': publishing branch '$branch' for project '$projectId'");
    try {
      final result = await publish(runId: run.id, projectId: projectId, branch: branch);
      context['publish.status'] = result.status;
      context['publish.branch'] = result.branch;
      context['publish.remote'] = result.remote;
      context['publish.pr_url'] = result.prUrl;
      if (result.error != null && result.error!.isNotEmpty) {
        context['publish.error'] = result.error!;
      }
      await _persistContext(run.id, context);
      final refreshedRun = await _repository.getById(run.id) ?? run;
      await _repository.update(
        refreshedRun.copyWith(
          contextJson: {
            for (final e in refreshedRun.contextJson.entries)
              if (e.key.startsWith('_')) e.key: e.value,
            ...context.toJson(),
          },
          updatedAt: DateTime.now(),
        ),
      );
      if (result.status == 'failed') {
        _log.warning("Workflow '${run.id}': publish failed for branch '$branch': ${result.error ?? 'unknown error'}");
        return 'publish failed: ${result.error ?? 'unknown error'}';
      }
      _log.info(
        "Workflow '${run.id}': publish succeeded — branch '${result.branch}' pushed to '${result.remote}'"
        '${result.prUrl.isNotEmpty ? ', PR: ${result.prUrl}' : ''}',
      );
      return null;
    } catch (e, st) {
      _log.severe("Workflow '${run.id}': publish threw exception for branch '$branch'", e, st);
      return 'publish failed: $e';
    }
  }

  Future<void> _cleanupWorkflowGit(WorkflowRun run, {required bool preserveWorktrees}) async {
    final cleanup = _turnAdapter?.cleanupWorkflowGit;
    if (cleanup == null) return;
    final projectId = run.variablesJson['PROJECT']?.trim();
    if (projectId == null || projectId.isEmpty) return;
    try {
      await cleanup(runId: run.id, projectId: projectId, status: run.status.name, preserveWorktrees: preserveWorktrees);
    } catch (e, st) {
      _log.warning("Workflow '${run.id}' cleanup callback failed: $e", e, st);
    }
  }
}

class _ResolvedArtifactProject {
  final String projectId;
  final String dir;
  final bool exists;
  const _ResolvedArtifactProject({required this.projectId, required this.dir, required this.exists});
}
