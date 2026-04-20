import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        AgentExecutionRepository,
        EventBus,
        ExecutionRepositoryTransactor,
        KvService,
        MessageService,
        TaskRepository,
        Task,
        TaskStatus,
        WorkflowStepExecutionRepository,
        WorkflowExecutionCursor,
        WorkflowExecutionCursorNodeType,
        WorkflowApprovalResolvedEvent,
        WorkflowDefinition,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowRunStatusChangedEvent,
        WorkflowWorktreeBinding,
        WorkflowTaskService,
        atomicWriteJson;
import 'package:dartclaw_storage/dartclaw_storage.dart' show SqliteWorkflowRunRepository;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'workflow_context.dart';
import 'context_extractor.dart';
import 'gate_evaluator.dart';
import 'skill_registry.dart';
import 'step_config_resolver.dart';
import 'workflow_executor.dart';
import 'workflow_turn_adapter.dart';

/// Public API facade for workflow lifecycle management.
///
/// Owns the [SqliteWorkflowRunRepository] and delegates execution to
/// [WorkflowExecutor]. Provides start, pause, resume, cancel, get, list.
class WorkflowService {
  static final _log = Logger('WorkflowService');

  final SqliteWorkflowRunRepository _repository;
  final WorkflowTaskService _taskService;
  final MessageService _messageService;
  final WorkflowTurnAdapter? _turnAdapter;
  final EventBus _eventBus;
  final KvService _kvService;
  final String _dataDir;
  final Uuid _uuid;
  final WorkflowRoleDefaults _roleDefaults;
  final WorkflowStepOutputTransformer? _outputTransformer;
  final StructuredOutputFallbackRecorder? _structuredOutputFallbackRecorder;
  final SkillRegistry? _skillRegistry;
  final TaskRepository? _taskRepository;
  final AgentExecutionRepository? _agentExecutionRepository;
  final WorkflowStepExecutionRepository? _workflowStepExecutionRepository;
  final ExecutionRepositoryTransactor? _executionRepositoryTransactor;
  final FutureOr<void> Function(WorkflowWorktreeBinding binding, {required String workflowRunId})?
  _hydrateWorkflowWorktreeBinding;
  final Map<String, String>? _hostEnvironment;
  final List<String>? _bashStepEnvAllowlist;
  final List<String>? _bashStepExtraStripPatterns;

  // Cancellation tokens per run ID.
  final _cancelFlags = <String, bool>{};

  // Active executor futures per run ID.
  final _activeExecutors = <String, Future<void>>{};

  // Approval timeout timers keyed by "<runId>:<stepId>".
  final _approvalTimeoutTimers = <String, Timer>{};

  WorkflowService({
    required SqliteWorkflowRunRepository repository,
    required WorkflowTaskService taskService,
    required MessageService messageService,
    WorkflowTurnAdapter? turnAdapter,
    required EventBus eventBus,
    required KvService kvService,
    required String dataDir,
    WorkflowRoleDefaults? roleDefaults,
    WorkflowStepOutputTransformer? outputTransformer,
    StructuredOutputFallbackRecorder? structuredOutputFallbackRecorder,
    SkillRegistry? skillRegistry,
    TaskRepository? taskRepository,
    AgentExecutionRepository? agentExecutionRepository,
    WorkflowStepExecutionRepository? workflowStepExecutionRepository,
    ExecutionRepositoryTransactor? executionRepositoryTransactor,
    FutureOr<void> Function(WorkflowWorktreeBinding binding, {required String workflowRunId})?
    hydrateWorkflowWorktreeBinding,
    Map<String, String>? hostEnvironment,
    List<String>? bashStepEnvAllowlist,
    List<String>? bashStepExtraStripPatterns,
    Uuid? uuid,
  }) : _repository = repository,
       _taskService = taskService,
       _messageService = messageService,
       _turnAdapter = turnAdapter,
       _eventBus = eventBus,
       _kvService = kvService,
       _dataDir = dataDir,
       _roleDefaults = roleDefaults ?? const WorkflowRoleDefaults(),
       _outputTransformer = outputTransformer,
       _structuredOutputFallbackRecorder = structuredOutputFallbackRecorder,
       _skillRegistry = skillRegistry,
       _taskRepository = taskRepository,
       _agentExecutionRepository = agentExecutionRepository,
       _workflowStepExecutionRepository = workflowStepExecutionRepository,
       _executionRepositoryTransactor = executionRepositoryTransactor,
       _hydrateWorkflowWorktreeBinding = hydrateWorkflowWorktreeBinding,
       _hostEnvironment = hostEnvironment,
       _bashStepEnvAllowlist = bashStepEnvAllowlist,
       _bashStepExtraStripPatterns = bashStepExtraStripPatterns,
       _uuid = uuid ?? const Uuid();

  /// Starts a new workflow run from a parsed definition.
  ///
  /// Validates required variables, creates the run, and spawns the executor
  /// in the background. Returns the created [WorkflowRun].
  Future<WorkflowRun> start(
    WorkflowDefinition definition,
    Map<String, String> variables, {
    String? projectId,
    bool headless = false,
  }) async {
    // Validate required variables.
    for (final entry in definition.variables.entries) {
      if (entry.value.required && !variables.containsKey(entry.key)) {
        throw ArgumentError('Required variable "${entry.key}" not provided');
      }
    }

    // Apply defaults for optional variables.
    final resolvedVariables = <String, String>{
      for (final entry in definition.variables.entries)
        if (entry.value.defaultValue != null) entry.key: entry.value.defaultValue!,
      ...variables,
    };
    final trimmedProjectId = projectId?.trim();
    if (trimmedProjectId != null &&
        trimmedProjectId.isNotEmpty &&
        definition.variables.containsKey('PROJECT') &&
        !resolvedVariables.containsKey('PROJECT')) {
      resolvedVariables['PROJECT'] = trimmedProjectId;
    }

    final resolver = _turnAdapter?.resolveStartContext;
    if (resolver != null) {
      final resolution = await resolver(definition, resolvedVariables, projectId: trimmedProjectId);
      final resolvedProjectId = resolution.projectId?.trim();
      if (resolvedProjectId != null && resolvedProjectId.isNotEmpty) {
        if (definition.variables.containsKey('PROJECT')) {
          resolvedVariables['PROJECT'] = resolvedProjectId;
        }
      }
      final resolvedBranch = resolution.branch?.trim();
      if (resolvedBranch != null && resolvedBranch.isNotEmpty && definition.variables.containsKey('BRANCH')) {
        resolvedVariables['BRANCH'] = resolvedBranch;
      }
    }

    final now = DateTime.now();
    final runId = _uuid.v4();
    final context = WorkflowContext(variables: resolvedVariables);

    // Apply headless mode: override all step review modes to auto-accept.
    final effectiveDefinition = headless ? _applyHeadlessMode(definition) : definition;

    // Create run in pending status.
    var run = WorkflowRun(
      id: runId,
      definitionName: definition.name,
      status: WorkflowRunStatus.pending,
      variablesJson: resolvedVariables,
      startedAt: now,
      updatedAt: now,
      definitionJson: effectiveDefinition.toJson(),
    );
    await _repository.insert(run);

    // Transition to running.
    run = run.copyWith(status: WorkflowRunStatus.running, updatedAt: DateTime.now());
    await _repository.update(run);

    // Persist initial (empty) context.
    await _persistContext(runId, context);

    // Fire status changed event.
    _fireStatusChanged(
      runId: runId,
      definitionName: definition.name,
      oldStatus: WorkflowRunStatus.pending,
      newStatus: WorkflowRunStatus.running,
    );

    // Spawn executor in background.
    _spawnExecutor(run, effectiveDefinition, context);

    return run;
  }

  /// Pauses a running workflow.
  ///
  /// Sets the cancellation flag so the executor stops before the next step.
  Future<WorkflowRun> pause(String runId) async {
    final run = await _requireRun(runId);
    if (run.status != WorkflowRunStatus.running) {
      throw StateError('Cannot pause workflow in ${run.status.name} state (only running workflows can be paused)');
    }

    _cancelFlags[runId] = true;

    final paused = run.copyWith(status: WorkflowRunStatus.paused, updatedAt: DateTime.now());
    await _repository.update(paused);
    _fireStatusChanged(
      runId: runId,
      definitionName: run.definitionName,
      oldStatus: run.status,
      newStatus: WorkflowRunStatus.paused,
    );
    return paused;
  }

  /// Resumes a paused workflow.
  ///
  /// Detects loop, parallel-failure, and approval-pause state from [run.contextJson]
  /// and resumes accordingly. Otherwise re-runs from [run.currentStepIndex].
  ///
  /// When resuming an approval-paused run, records the approval as accepted and fires
  /// [WorkflowApprovalResolvedEvent].
  Future<WorkflowRun> resume(String runId) async {
    var run = await _requireRun(runId);
    if (run.status != WorkflowRunStatus.paused && run.status != WorkflowRunStatus.awaitingApproval) {
      throw StateError(
        'Cannot resume workflow in ${run.status.name} state '
        '(only paused or awaitingApproval workflows can be resumed)',
      );
    }

    // Record approval outcome if this was an approval-paused run.
    final pendingApprovalStepId = run.contextJson['_approval.pending.stepId'] as String?;
    if (pendingApprovalStepId != null) {
      _clearApprovalTimeoutTimer(runId, pendingApprovalStepId);
      final resolvedAt = DateTime.now().toIso8601String();
      final context = await _loadContext(runId) ?? WorkflowContext.fromJson(run.contextJson);
      context['$pendingApprovalStepId.status'] = 'accepted';
      context['$pendingApprovalStepId.approval.status'] = 'approved';
      context['$pendingApprovalStepId.approval.resolved_at'] = resolvedAt;
      await _persistContext(runId, context);
      final updatedContext = _snapshotContextJson(
        run.contextJson,
        context,
        removeFlatKeys: const {'_approval.pending.stepId', '_approval.pending.stepIndex'},
        extraFlat: {
          '$pendingApprovalStepId.status': 'accepted',
          '$pendingApprovalStepId.approval.status': 'approved',
          '$pendingApprovalStepId.approval.resolved_at': resolvedAt,
        },
      );
      run = run.copyWith(contextJson: updatedContext, updatedAt: DateTime.now());
      await _repository.update(run);
      _eventBus.fire(
        WorkflowApprovalResolvedEvent(
          runId: runId,
          stepId: pendingApprovalStepId,
          approved: true,
          timestamp: DateTime.now(),
        ),
      );
    }

    // Load definition from snapshot.
    final definition = WorkflowDefinition.fromJson(run.definitionJson);

    // Load context from disk.
    final context = await _loadContext(runId) ?? WorkflowContext.fromJson(run.contextJson);

    final executionCursor = _resumeCursor(run, definition);
    final resumeStepIndex = executionCursor?.stepIndex ?? run.currentStepIndex;
    _logResumeCursor(run, executionCursor, action: 'Resuming');
    await _rehydrateWorkflowWorktreeBinding(run);

    // Transition to running.
    final running = run.copyWith(status: WorkflowRunStatus.running, errorMessage: null, updatedAt: DateTime.now());
    await _repository.update(running);
    _cancelFlags.remove(runId);

    _fireStatusChanged(
      runId: runId,
      definitionName: run.definitionName,
      oldStatus: run.status,
      newStatus: WorkflowRunStatus.running,
    );

    _spawnExecutor(running, definition, context, startFromStepIndex: resumeStepIndex, startCursor: executionCursor);

    return running;
  }

  /// Retries a failed workflow from its persisted resume cursor.
  Future<WorkflowRun> retry(String runId) async {
    var run = await _requireRun(runId);
    if (run.status != WorkflowRunStatus.failed) {
      throw StateError('Cannot retry workflow in ${run.status.name} state (only failed workflows can be retried)');
    }

    final definition = WorkflowDefinition.fromJson(run.definitionJson);
    final context = await _loadContext(runId) ?? WorkflowContext.fromJson(run.contextJson);
    final executionCursor = _resumeCursor(run, definition);
    final retryStepIndex = executionCursor?.stepIndex ?? run.currentStepIndex;
    _logResumeCursor(run, executionCursor, action: 'Retrying');
    await _rehydrateWorkflowWorktreeBinding(run);

    final failingStepId = _stepIdForRetry(run, definition, executionCursor);
    if (failingStepId != null) {
      context.remove('$failingStepId.status');
      context.remove('step.$failingStepId.outcome');
      context.remove('step.$failingStepId.outcome.reason');
    }
    await _persistContext(runId, context);

    final running = run.copyWith(
      status: WorkflowRunStatus.running,
      errorMessage: null,
      completedAt: null,
      contextJson: _snapshotContextJson(
        run.contextJson,
        context,
        removeFlatKeys: {
          if (failingStepId != null) '$failingStepId.status',
          if (failingStepId != null) 'step.$failingStepId.outcome',
          if (failingStepId != null) 'step.$failingStepId.outcome.reason',
        },
      ),
      updatedAt: DateTime.now(),
    );
    await _repository.update(running);
    _cancelFlags.remove(runId);

    _fireStatusChanged(
      runId: runId,
      definitionName: run.definitionName,
      oldStatus: run.status,
      newStatus: WorkflowRunStatus.running,
    );

    _spawnExecutor(running, definition, context, startFromStepIndex: retryStepIndex, startCursor: executionCursor);
    return running;
  }

  /// Cancels a workflow. Force-cancels running child tasks via task transition.
  ///
  /// When cancelling an approval-paused run, [feedback] is stored as rejection
  /// feedback and [WorkflowApprovalResolvedEvent] is fired with `approved: false`.
  Future<void> cancel(String runId, {String? feedback}) async {
    var run = await _repository.getById(runId);
    if (run == null || run.status.terminal) return;

    // Record approval rejection if this was an approval-paused run.
    final pendingApprovalStepId = run.contextJson['_approval.pending.stepId'] as String?;
    if (pendingApprovalStepId != null) {
      _clearApprovalTimeoutTimer(runId, pendingApprovalStepId);
      final resolvedAt = DateTime.now().toIso8601String();
      final context = await _loadContext(runId) ?? WorkflowContext.fromJson(run.contextJson);
      context['$pendingApprovalStepId.status'] = 'rejected';
      context['$pendingApprovalStepId.approval.status'] = 'rejected';
      context['$pendingApprovalStepId.approval.resolved_at'] = resolvedAt;
      if (feedback != null) {
        context['$pendingApprovalStepId.approval.feedback'] = feedback;
      }
      await _persistContext(runId, context);
      final updatedContext = _snapshotContextJson(
        run.contextJson,
        context,
        removeFlatKeys: const {'_approval.pending.stepId', '_approval.pending.stepIndex'},
        extraFlat: {
          '$pendingApprovalStepId.status': 'rejected',
          '$pendingApprovalStepId.approval.status': 'rejected',
          '$pendingApprovalStepId.approval.resolved_at': resolvedAt,
          '$pendingApprovalStepId.approval.feedback': ?feedback,
        },
      );
      run = run.copyWith(contextJson: updatedContext, updatedAt: DateTime.now());
      await _repository.update(run);
      _eventBus.fire(
        WorkflowApprovalResolvedEvent(
          runId: runId,
          stepId: pendingApprovalStepId,
          approved: false,
          feedback: feedback,
          timestamp: DateTime.now(),
        ),
      );
    }

    // Signal executor to stop.
    _cancelFlags[runId] = true;

    // Transition workflow to cancelled.
    final cancelled = run.copyWith(
      status: WorkflowRunStatus.cancelled,
      completedAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    await _repository.update(cancelled);
    _fireStatusChanged(
      runId: runId,
      definitionName: run.definitionName,
      oldStatus: run.status,
      newStatus: WorkflowRunStatus.cancelled,
    );

    // Cancel all non-terminal child tasks.
    // Host-side wiring is responsible for reacting to running->cancelled task
    // transitions and terminating any active turn bound to the task session.
    final allTasks = await _taskService.list();
    final workflowTasks = allTasks.where(
      (t) => t.workflowRunId == runId && (t.status == TaskStatus.queued || t.status == TaskStatus.running),
    );
    for (final task in workflowTasks) {
      try {
        await _taskService.transition(task.id, TaskStatus.cancelled, trigger: 'workflow-cancel');
      } on StateError {
        // Task may have transitioned concurrently — best-effort.
      } catch (e) {
        _log.warning('Failed to cancel workflow task ${task.id}: $e');
      }
    }
    await _invokeWorkflowGitCleanup(cancelled, preserveWorktrees: false);
  }

  /// Returns the workflow run with [runId], or null if not found.
  Future<WorkflowRun?> get(String runId) => _repository.getById(runId);

  /// Lists workflow runs with optional filters.
  Future<List<WorkflowRun>> list({WorkflowRunStatus? status, String? definitionName}) =>
      _repository.list(status: status, definitionName: definitionName);

  /// Detects and resumes incomplete workflow runs after server restart.
  ///
  /// Only resumes runs with status `running`. Paused runs require explicit user action.
  Future<void> recoverIncompleteRuns() async {
    final incompleteRuns = await _repository.list(status: WorkflowRunStatus.running);
    if (incompleteRuns.isNotEmpty) {
      _log.info('Found ${incompleteRuns.length} incomplete workflow run(s) — recovering...');

      for (final run in incompleteRuns) {
        try {
          await _recoverRun(run);
        } catch (e, st) {
          _log.severe('Failed to recover workflow run ${run.id}', e, st);
        }
      }
    }

    final heldRuns = [
      ...await _repository.list(status: WorkflowRunStatus.paused),
      ...await _repository.list(status: WorkflowRunStatus.awaitingApproval),
    ];
    for (final run in heldRuns) {
      try {
        await _rehydrateApprovalTimeout(run);
      } catch (e, st) {
        _log.severe('Failed to rehydrate approval timeout for workflow run ${run.id}', e, st);
      }
    }
  }

  /// Recovers a single incomplete run.
  Future<void> _recoverRun(WorkflowRun run) async {
    // Load definition from snapshot.
    WorkflowDefinition definition;
    try {
      definition = WorkflowDefinition.fromJson(run.definitionJson);
    } catch (e) {
      _log.warning('Cannot recover workflow ${run.id}: failed to parse definition JSON: $e');
      return;
    }

    // Load context from disk (fall back to SQLite snapshot).
    final context = await _loadContext(run.id) ?? WorkflowContext.fromJson(run.contextJson);
    await _rehydrateWorkflowWorktreeBinding(run);

    final executionCursor = _resumeCursor(run, definition);
    if (executionCursor != null) {
      _logResumeCursor(run, executionCursor, action: 'Recovering');
      _cancelFlags.remove(run.id);
      _spawnExecutor(
        run,
        definition,
        context,
        startFromStepIndex: executionCursor.stepIndex,
        startCursor: executionCursor,
      );
      return;
    }

    // Standard recovery: find the last completed step.
    final allTasks = await _taskService.list();
    final workflowTasks = allTasks.where((t) => t.workflowRunId == run.id).toList();

    int resumeStepIndex = run.currentStepIndex;

    // Find interrupted (non-terminal, in-progress) task — re-run from that step.
    Task? interruptedTask;
    for (final t in workflowTasks) {
      if (!t.status.terminal && t.stepIndex != null) {
        interruptedTask = t;
        break;
      }
    }

    // If no interrupted task, find the highest completed step index.
    if (interruptedTask == null) {
      for (final t in workflowTasks) {
        if (t.status.terminal && t.stepIndex != null) {
          if (interruptedTask == null || t.stepIndex! > interruptedTask.stepIndex!) {
            interruptedTask = t;
          }
        }
      }
      // Resume from the step after the last completed one.
      if (interruptedTask?.stepIndex != null) {
        resumeStepIndex = interruptedTask!.stepIndex! + 1;
      }
    } else {
      // Re-run the interrupted step.
      resumeStepIndex = interruptedTask.stepIndex!;
    }

    _log.info("Recovering workflow '${definition.name}' (${run.id}) from step $resumeStepIndex");

    _cancelFlags.remove(run.id);
    _spawnExecutor(run, definition, context, startFromStepIndex: resumeStepIndex);
  }

  /// Shuts down all active executors gracefully.
  Future<void> dispose() async {
    // Signal all active runs to stop.
    for (final runId in _activeExecutors.keys) {
      _cancelFlags[runId] = true;
    }

    // Cancel in-flight child tasks to unblock executors waiting on task completion.
    final allTasks = await _taskService.list();
    for (final task in allTasks) {
      if (task.workflowRunId != null && _activeExecutors.containsKey(task.workflowRunId) && !task.status.terminal) {
        try {
          if (task.status == TaskStatus.queued) {
            await _taskService.transition(task.id, TaskStatus.running, trigger: 'dispose');
          }
          await _taskService.transition(task.id, TaskStatus.cancelled, trigger: 'dispose');
        } on StateError {
          // Ignore — already transitioned concurrently.
        } catch (e) {
          _log.warning('Failed to cancel task ${task.id} during dispose: $e');
        }
      }
    }

    // Wait for active executors to finish.
    await Future.wait(_activeExecutors.values);
    _activeExecutors.clear();
    _cancelFlags.clear();
    for (final timer in _approvalTimeoutTimers.values) {
      timer.cancel();
    }
    _approvalTimeoutTimers.clear();
  }

  WorkflowExecutionCursor? _resumeCursor(WorkflowRun run, WorkflowDefinition definition) {
    final cursor = run.executionCursor;
    if (cursor != null) {
      return cursor;
    }

    final currentLoopId = run.contextJson['_loop.current.id'] as String?;
    if (currentLoopId == null) return null;
    final currentIteration = (run.contextJson['_loop.current.iteration'] as num?)?.toInt() ?? 1;
    final currentLoopStepId = run.contextJson['_loop.current.stepId'] as String?;
    final loop = definition.loops.where((candidate) => candidate.id == currentLoopId).firstOrNull;
    if (loop == null) return null;
    final fallbackStepId = currentLoopStepId ?? loop.steps.first;
    final stepIndex = definition.steps.indexWhere((step) => step.id == fallbackStepId);
    if (stepIndex < 0) return null;
    return WorkflowExecutionCursor.loop(
      loopId: currentLoopId,
      stepIndex: stepIndex,
      iteration: currentIteration,
      stepId: currentLoopStepId,
    );
  }

  void _logResumeCursor(WorkflowRun run, WorkflowExecutionCursor? cursor, {required String action}) {
    if (cursor == null) return;
    switch (cursor.nodeType) {
      case WorkflowExecutionCursorNodeType.loop:
        _log.info(
          "$action workflow '${run.definitionName}' (${run.id}): "
          "loop '${cursor.nodeId}' at iteration ${cursor.iteration ?? 1}"
          "${cursor.stepId != null ? ', step ${cursor.stepId}' : ''}",
        );
      case WorkflowExecutionCursorNodeType.map:
        _log.info(
          "$action workflow '${run.definitionName}' (${run.id}): "
          "map step '${cursor.nodeId}' with ${cursor.completedIndices.length}/"
          '${cursor.totalItems ?? cursor.resultSlots.length} settled iteration(s)',
        );
      case WorkflowExecutionCursorNodeType.foreach:
        _log.info(
          "$action workflow '${run.definitionName}' (${run.id}): "
          "foreach step '${cursor.nodeId}' with ${cursor.completedIndices.length}/"
          '${cursor.totalItems ?? cursor.resultSlots.length} completed iteration(s)',
        );
    }
  }

  void _spawnExecutor(
    WorkflowRun run,
    WorkflowDefinition definition,
    WorkflowContext context, {
    int startFromStepIndex = 0,
    WorkflowExecutionCursor? startCursor,
    int? startFromLoopIndex,
    int? startFromLoopIteration,
    String? startFromLoopStepId,
  }) {
    final executor = WorkflowExecutor(
      taskService: _taskService,
      eventBus: _eventBus,
      kvService: _kvService,
      repository: _repository,
      gateEvaluator: GateEvaluator(),
      contextExtractor: ContextExtractor(
        taskService: _taskService,
        messageService: _messageService,
        dataDir: _dataDir,
        workflowStepExecutionRepository: _workflowStepExecutionRepository,
        structuredOutputFallbackRecorder: _structuredOutputFallbackRecorder,
      ),
      messageService: _messageService,
      turnAdapter: _turnAdapter,
      outputTransformer: _outputTransformer,
      dataDir: _dataDir,
      roleDefaults: _roleDefaults,
      skillRegistry: _skillRegistry,
      taskRepository: _taskRepository,
      agentExecutionRepository: _agentExecutionRepository,
      workflowStepExecutionRepository: _workflowStepExecutionRepository,
      executionTransactor: _executionRepositoryTransactor,
      hostEnvironment: _hostEnvironment,
      bashStepEnvAllowlist: _bashStepEnvAllowlist,
      bashStepExtraStripPatterns: _bashStepExtraStripPatterns,
    );

    Future<void> executeFn() async {
      try {
        await executor.execute(
          run,
          definition,
          context,
          startFromStepIndex: startFromStepIndex,
          startCursor: startCursor,
          startFromLoopIndex: startFromLoopIndex,
          startFromLoopIteration: startFromLoopIteration,
          startFromLoopStepId: startFromLoopStepId,
          isCancelled: () => _cancelFlags[run.id] ?? false,
        );
        final current = await _repository.getById(run.id);
        if (current != null && current.status == WorkflowRunStatus.awaitingApproval) {
          await _rehydrateApprovalTimeout(current);
        }
      } catch (e, st) {
        _log.severe("Workflow '${run.id}' executor failed unexpectedly", e, st);
        // Transition to failed so the run doesn't remain stuck in 'running'.
        try {
          final current = await _repository.getById(run.id);
          if (current != null && !current.status.terminal) {
            final failed = current.copyWith(
              status: WorkflowRunStatus.failed,
              errorMessage: 'Unexpected executor error: $e',
              completedAt: DateTime.now(),
              updatedAt: DateTime.now(),
            );
            await _repository.update(failed);
            await _invokeWorkflowGitCleanup(failed, preserveWorktrees: false);
            _fireStatusChanged(
              runId: run.id,
              definitionName: run.definitionName,
              oldStatus: current.status,
              newStatus: WorkflowRunStatus.failed,
              errorMessage: failed.errorMessage,
            );
          }
        } catch (persistError) {
          _log.severe("Failed to persist failed status for '${run.id}'", persistError);
        }
      } finally {
        executor.dispose();
        _activeExecutors.remove(run.id); // ignore: unawaited_futures
      }
    }

    final future = executeFn();
    _activeExecutors[run.id] = future;
  }

  Future<WorkflowRun> _requireRun(String runId) async {
    final run = await _repository.getById(runId);
    if (run == null) throw ArgumentError('Workflow run not found: $runId');
    return run;
  }

  Future<void> _rehydrateWorkflowWorktreeBinding(WorkflowRun run) async {
    final bindings = run.workflowWorktrees.isNotEmpty
        ? run.workflowWorktrees
        : await _repository.getWorktreeBindings(run.id);
    for (final binding in bindings) {
      if (binding.workflowRunId != run.id) {
        throw StateError(
          'Workflow worktree binding run ID mismatch: '
          'persisted ${binding.workflowRunId}, requested ${run.id}',
        );
      }
    }
    final hydrate = _hydrateWorkflowWorktreeBinding;
    if (hydrate == null) return;
    for (final binding in bindings) {
      await hydrate(binding, workflowRunId: run.id);
    }
  }

  String? _stepIdForRetry(WorkflowRun run, WorkflowDefinition definition, WorkflowExecutionCursor? executionCursor) {
    if (executionCursor?.stepId case final String stepId?) {
      return stepId;
    }
    final stepIndex = executionCursor?.stepIndex ?? run.currentStepIndex;
    if (stepIndex < 0 || stepIndex >= definition.steps.length) return null;
    return definition.steps[stepIndex].id;
  }

  Future<void> _persistContext(String runId, WorkflowContext context) async {
    final dir = Directory(p.join(_dataDir, 'workflows', runId));
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, 'context.json'));
    await atomicWriteJson(file, context.toJson());
  }

  Future<void> _invokeWorkflowGitCleanup(WorkflowRun run, {required bool preserveWorktrees}) async {
    final cleanup = _turnAdapter?.cleanupWorkflowGit;
    if (cleanup == null) return;
    final projectId = run.variablesJson['PROJECT']?.trim();
    if (projectId == null || projectId.isEmpty) return;
    try {
      await cleanup(runId: run.id, projectId: projectId, status: run.status.name, preserveWorktrees: preserveWorktrees);
    } catch (e, st) {
      _log.warning("Workflow '${run.id}' cleanup callback failed", e, st);
    }
  }

  Future<WorkflowContext?> _loadContext(String runId) async {
    final file = File(p.join(_dataDir, 'workflows', runId, 'context.json'));
    if (!file.existsSync()) return null;
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return WorkflowContext.fromJson(json);
    } catch (e) {
      _log.warning('Failed to load context for workflow $runId: $e');
      return null;
    }
  }

  void _fireStatusChanged({
    required String runId,
    required String definitionName,
    required WorkflowRunStatus oldStatus,
    required WorkflowRunStatus newStatus,
    String? errorMessage,
  }) {
    _eventBus.fire(
      WorkflowRunStatusChangedEvent(
        runId: runId,
        definitionName: definitionName,
        oldStatus: oldStatus,
        newStatus: newStatus,
        errorMessage: errorMessage,
        timestamp: DateTime.now(),
      ),
    );
  }

  /// Applies headless mode by overriding all step review modes to auto-accept.
  WorkflowDefinition _applyHeadlessMode(WorkflowDefinition definition) {
    // Reconstruct from JSON with modified steps.
    final json = definition.toJson();
    final steps = (json['steps'] as List).map((s) {
      final step = Map<String, dynamic>.from(s as Map);
      step['review'] = 'never';
      return step;
    }).toList();
    json['steps'] = steps;
    return WorkflowDefinition.fromJson(json);
  }

  Future<void> _rehydrateApprovalTimeout(WorkflowRun run) async {
    final pendingApprovalStepId = run.contextJson['_approval.pending.stepId'] as String?;
    if (pendingApprovalStepId == null) return;

    final deadlineRaw = run.contextJson['$pendingApprovalStepId.approval.timeout_deadline'] as String?;
    if (deadlineRaw == null) return;
    final deadline = DateTime.tryParse(deadlineRaw);
    if (deadline == null) return;

    if (!deadline.isAfter(DateTime.now())) {
      await _expireApprovalTimeout(run, pendingApprovalStepId);
      return;
    }

    _scheduleApprovalTimeout(run.id, pendingApprovalStepId, deadline);
  }

  void _scheduleApprovalTimeout(String runId, String stepId, DateTime deadline) {
    final key = '$runId:$stepId';
    _approvalTimeoutTimers[key]?.cancel();
    _approvalTimeoutTimers[key] = Timer(deadline.difference(DateTime.now()), () async {
      _approvalTimeoutTimers.remove(key);
      final run = await _repository.getById(runId);
      if (run == null) return;
      await _expireApprovalTimeout(run, stepId);
    });
  }

  void _clearApprovalTimeoutTimer(String runId, String stepId) {
    final key = '$runId:$stepId';
    _approvalTimeoutTimers.remove(key)?.cancel();
  }

  Future<void> _expireApprovalTimeout(WorkflowRun run, String stepId) async {
    if (run.status != WorkflowRunStatus.awaitingApproval && run.status != WorkflowRunStatus.paused) return;
    if (run.contextJson['_approval.pending.stepId'] != stepId) return;

    _clearApprovalTimeoutTimer(run.id, stepId);
    final context = await _loadContext(run.id) ?? WorkflowContext.fromJson(run.contextJson);
    context['$stepId.status'] = 'cancelled';
    context['$stepId.approval.status'] = 'timed_out';
    context['$stepId.approval.cancel_reason'] = 'timeout';
    await _persistContext(run.id, context);

    final cancelled = run.copyWith(
      status: WorkflowRunStatus.cancelled,
      completedAt: DateTime.now(),
      updatedAt: DateTime.now(),
      contextJson: _snapshotContextJson(
        run.contextJson,
        context,
        removeFlatKeys: const {'_approval.pending.stepId', '_approval.pending.stepIndex'},
        extraFlat: {
          '$stepId.status': 'cancelled',
          '$stepId.approval.status': 'timed_out',
          '$stepId.approval.cancel_reason': 'timeout',
        },
      ),
    );
    await _repository.update(cancelled);
    _fireStatusChanged(
      runId: run.id,
      definitionName: run.definitionName,
      oldStatus: run.status,
      newStatus: WorkflowRunStatus.cancelled,
      errorMessage: 'approval timeout: $stepId',
    );
  }

  Map<String, dynamic> _snapshotContextJson(
    Map<String, dynamic> existing,
    WorkflowContext context, {
    Set<String> removeFlatKeys = const {},
    Map<String, dynamic> extraFlat = const {},
  }) {
    return {
      for (final entry in existing.entries)
        if (entry.key != 'data' && entry.key != 'variables' && !removeFlatKeys.contains(entry.key))
          entry.key: entry.value,
      ...context.toJson(),
      ...extraFlat,
    };
  }
}
