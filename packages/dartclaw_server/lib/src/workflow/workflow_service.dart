import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        EventBus,
        KvService,
        MessageService,
        Task,
        TaskStatus,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowRunStatusChangedEvent,
        atomicWriteJson;
import 'package:dartclaw_storage/dartclaw_storage.dart' show SqliteWorkflowRunRepository;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../task/task_service.dart';
import '../turn_manager.dart' show TurnManager;
import 'context_extractor.dart';
import 'gate_evaluator.dart';
import 'workflow_executor.dart';

/// Public API facade for workflow lifecycle management.
///
/// Owns the [SqliteWorkflowRunRepository] and delegates execution to
/// [WorkflowExecutor]. Provides start, pause, resume, cancel, get, list.
class WorkflowService {
  static final _log = Logger('WorkflowService');

  final SqliteWorkflowRunRepository _repository;
  final TaskService _taskService;
  final MessageService _messageService;
  final TurnManager? _turnManager;
  final EventBus _eventBus;
  final KvService _kvService;
  final String _dataDir;
  final Uuid _uuid;

  // Cancellation tokens per run ID.
  final _cancelFlags = <String, bool>{};

  // Active executor futures per run ID.
  final _activeExecutors = <String, Future<void>>{};

  WorkflowService({
    required SqliteWorkflowRunRepository repository,
    required TaskService taskService,
    required MessageService messageService,
    TurnManager? turnManager,
    required EventBus eventBus,
    required KvService kvService,
    required String dataDir,
    Uuid? uuid,
  }) : _repository = repository,
       _taskService = taskService,
       _messageService = messageService,
       _turnManager = turnManager,
       _eventBus = eventBus,
       _kvService = kvService,
       _dataDir = dataDir,
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
      throw StateError(
        'Cannot pause workflow in ${run.status.name} state (only running workflows can be paused)',
      );
    }

    _cancelFlags[runId] = true;

    final paused = run.copyWith(
      status: WorkflowRunStatus.paused,
      updatedAt: DateTime.now(),
    );
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
  /// Detects loop and parallel-failure state from [run.contextJson] and resumes
  /// accordingly. Otherwise re-runs from [run.currentStepIndex].
  Future<WorkflowRun> resume(String runId) async {
    final run = await _requireRun(runId);
    if (run.status != WorkflowRunStatus.paused) {
      throw StateError(
        'Cannot resume workflow in ${run.status.name} state (only paused workflows can be resumed)',
      );
    }

    // Load definition from snapshot.
    final definition = WorkflowDefinition.fromJson(run.definitionJson);

    // Load context from disk.
    final context = await _loadContext(runId) ?? WorkflowContext.fromJson(run.contextJson);

    // Determine resume point.
    final currentLoopId = run.contextJson['_loop.current.id'] as String?;
    final currentLoopIteration =
        (run.contextJson['_loop.current.iteration'] as num?)?.toInt();
    final currentLoopStepId = run.contextJson['_loop.current.stepId'] as String?;

    int? startLoopIndex;
    int? startLoopIteration;
    String? startLoopStepId;
    int resumeStepIndex = run.currentStepIndex;

    if (currentLoopId != null) {
      // Was mid-loop — resume from that loop and iteration.
      final loopIndex = definition.loops.indexWhere((l) => l.id == currentLoopId);
      if (loopIndex >= 0) {
        _log.info(
          "Resuming workflow '${run.definitionName}' ($runId): "
          "loop '$currentLoopId' at iteration ${currentLoopIteration ?? 1}"
          "${currentLoopStepId != null ? ', step $currentLoopStepId' : ''}",
        );
        // Skip the linear pass — it was already completed.
        resumeStepIndex = definition.steps.length;
        startLoopIndex = loopIndex;
        startLoopIteration = currentLoopIteration ?? 1;
        startLoopStepId = currentLoopStepId;
      }
    }

    // Transition to running.
    final running = run.copyWith(
      status: WorkflowRunStatus.running,
      errorMessage: null,
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

    _spawnExecutor(
      running,
      definition,
      context,
      startFromStepIndex: resumeStepIndex,
      startFromLoopIndex: startLoopIndex,
      startFromLoopIteration: startLoopIteration,
      startFromLoopStepId: startLoopStepId,
    );

    return running;
  }

  /// Cancels a workflow. Force-cancels running child tasks via task transition.
  Future<void> cancel(String runId) async {
    final run = await _repository.getById(runId);
    if (run == null || run.status.terminal) return;

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
    // Running tasks: transition to cancelled triggers TurnRunner.cancelTurn()
    // (stdin close + SIGTERM). Immediate — no grace period.
    final allTasks = await _taskService.list();
    final workflowTasks = allTasks.where((t) => t.workflowRunId == runId && !t.status.terminal);
    for (final task in workflowTasks) {
      try {
        await _taskService.transition(task.id, TaskStatus.cancelled, trigger: 'workflow-cancel');
      } on StateError {
        // Task may have transitioned concurrently — best-effort.
      } catch (e) {
        _log.warning('Failed to cancel workflow task ${task.id}: $e');
      }
    }
  }

  /// Returns the workflow run with [runId], or null if not found.
  Future<WorkflowRun?> get(String runId) => _repository.getById(runId);

  /// Lists workflow runs with optional filters.
  Future<List<WorkflowRun>> list({
    WorkflowRunStatus? status,
    String? definitionName,
  }) => _repository.list(status: status, definitionName: definitionName);

  /// Detects and resumes incomplete workflow runs after server restart.
  ///
  /// Only resumes runs with status `running`. Paused runs require explicit user action.
  Future<void> recoverIncompleteRuns() async {
    final incompleteRuns = await _repository.list(status: WorkflowRunStatus.running);
    if (incompleteRuns.isEmpty) return;

    _log.info('Found ${incompleteRuns.length} incomplete workflow run(s) — recovering...');

    for (final run in incompleteRuns) {
      try {
        await _recoverRun(run);
      } catch (e, st) {
        _log.severe('Failed to recover workflow run ${run.id}', e, st);
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

    // Check if run was mid-loop.
    final currentLoopId = run.contextJson['_loop.current.id'] as String?;
    if (currentLoopId != null) {
      final currentIteration =
          (run.contextJson['_loop.current.iteration'] as num?)?.toInt() ?? 1;
      final loopIndex = definition.loops.indexWhere((l) => l.id == currentLoopId);
      if (loopIndex >= 0) {
        _log.info(
          "Recovering workflow '${definition.name}' (${run.id}): "
          "resuming loop '$currentLoopId' at iteration $currentIteration",
        );
        _cancelFlags.remove(run.id);
        _spawnExecutor(
          run,
          definition,
          context,
          // Skip linear pass (already done); resume from this loop.
          startFromStepIndex: definition.steps.length,
          startFromLoopIndex: loopIndex,
          startFromLoopIteration: currentIteration,
        );
        return;
      }
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

    _log.info(
      "Recovering workflow '${definition.name}' (${run.id}) from step $resumeStepIndex",
    );

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
      if (task.workflowRunId != null &&
          _activeExecutors.containsKey(task.workflowRunId) &&
          !task.status.terminal) {
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
  }

  void _spawnExecutor(
    WorkflowRun run,
    WorkflowDefinition definition,
    WorkflowContext context, {
    int startFromStepIndex = 0,
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
      ),
      messageService: _messageService,
      turnManager: _turnManager,
      dataDir: _dataDir,
    );

    Future<void> executeFn() async {
      try {
        await executor.execute(
          run,
          definition,
          context,
          startFromStepIndex: startFromStepIndex,
          startFromLoopIndex: startFromLoopIndex,
          startFromLoopIteration: startFromLoopIteration,
          startFromLoopStepId: startFromLoopStepId,
          isCancelled: () => _cancelFlags[run.id] ?? false,
        );
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

  Future<void> _persistContext(String runId, WorkflowContext context) async {
    final dir = Directory(p.join(_dataDir, 'workflows', runId));
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, 'context.json'));
    await atomicWriteJson(file, context.toJson());
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
}
