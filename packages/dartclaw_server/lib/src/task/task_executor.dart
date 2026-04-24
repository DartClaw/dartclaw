import 'dart:async';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../behavior/behavior_file_service.dart';
import '../container/container_dispatcher.dart';
import '../harness_pool.dart';
import '../turn_manager.dart';
import '../turn_runner.dart';
import 'agent_observer.dart';
import 'artifact_collector.dart';
import 'goal_service.dart';
import 'task_budget_policy.dart';
import 'task_config_view.dart';
import 'task_event_recorder.dart';
import 'task_file_guard.dart';
import 'task_project_ref.dart';
import 'task_read_only_guard.dart';
import 'task_runner_pool_coordinator.dart';
import 'task_service.dart';
import 'workflow_cli_runner.dart';
import 'workflow_one_shot_runner.dart';
import 'workflow_worktree_binder.dart';
import 'worktree_manager.dart';

part 'task_executor_helpers.dart';

/// Executes queued tasks against the harness pool.
///
/// When `pool.maxConcurrentTasks > 0`, acquires a task runner from the pool.
/// When `pool.maxConcurrentTasks == 0` (single-harness mode), falls back to
/// using the primary runner directly when it is idle (S06 behavior).
class TaskExecutor {
  TaskExecutor({
    required TaskService tasks,
    GoalService? goals,
    required SessionService sessions,
    required MessageService messages,
    required TurnManager turns,
    required ArtifactCollector artifactCollector,
    WorktreeManager? worktreeManager,
    TaskFileGuard? taskFileGuard,
    AgentObserver? observer,
    TurnTraceService? traceService,
    TaskEventRecorder? eventRecorder,
    WorkflowCliRunner? workflowCliRunner,
    WorkflowStepExecutionRepository? workflowStepExecutionRepository,
    SqliteWorkflowRunRepository? workflowRunRepository,
    Future<void> Function()? onSpawnNeeded,
    Future<void> Function(String taskId)? onAutoAccept,
    ProjectService? projectService,
    String? workspaceDir,
    int? maxMemoryBytes,
    String? compactInstructions,
    String identifierPreservation = 'strict',
    String? identifierInstructions,
    KvService? kvService,
    TaskBudgetConfig? budgetConfig,
    EventBus? eventBus,
    String? dataDir,
    this.pollInterval = const Duration(seconds: 2),
  }) : _tasks = tasks,
       _goals = goals,
       _sessions = sessions,
       _messages = messages,
       _turns = turns,
       _pool = turns.pool,
       _artifactCollector = artifactCollector,
       _worktreeManager = worktreeManager,
       _taskFileGuard = taskFileGuard,
       _observer = observer,
       _traceService = traceService,
       _eventRecorder = eventRecorder,
       _workflowCliRunner = workflowCliRunner,
       _workflowStepExecutionRepository = workflowStepExecutionRepository,
       _workflowRunRepository = workflowRunRepository,
       _onSpawnNeeded = onSpawnNeeded,
       _onAutoAccept = onAutoAccept,
       _projectService = projectService,
       _workspaceDir = workspaceDir,
       _maxMemoryBytes = maxMemoryBytes,
       _compactInstructions = compactInstructions,
       _identifierPreservation = identifierPreservation,
       _identifierInstructions = identifierInstructions,
       _kv = kvService,
       _budgetConfig = budgetConfig,
       _eventBus = eventBus,
       _dataDir = dataDir;

  static final _log = Logger('TaskExecutor');
  static const _uuid = Uuid();

  final TaskService _tasks;
  final GoalService? _goals;
  final SessionService _sessions;
  final MessageService _messages;
  final TurnManager _turns;
  final HarnessPool _pool;
  final ArtifactCollector _artifactCollector;
  final WorktreeManager? _worktreeManager;
  final TaskFileGuard? _taskFileGuard;
  final AgentObserver? _observer;
  final TurnTraceService? _traceService;
  final TaskEventRecorder? _eventRecorder;
  final WorkflowCliRunner? _workflowCliRunner;
  final WorkflowStepExecutionRepository? _workflowStepExecutionRepository;
  final SqliteWorkflowRunRepository? _workflowRunRepository;
  final Future<void> Function()? _onSpawnNeeded;
  final Future<void> Function(String taskId)? _onAutoAccept;
  final ProjectService? _projectService;
  final String? _workspaceDir;
  final int? _maxMemoryBytes;
  final String? _compactInstructions;
  final String _identifierPreservation;
  final String? _identifierInstructions;
  final KvService? _kv;
  final TaskBudgetConfig? _budgetConfig;
  final EventBus? _eventBus;
  final String? _dataDir;
  final Duration pollInterval;
  late final TaskRunnerPoolCoordinator _runnerPoolCoordinator = TaskRunnerPoolCoordinator(
    pool: _pool,
    onSpawnNeeded: _onSpawnNeeded,
    log: _log,
  );
  late final TaskFailureHandler _failureHandler = TaskFailureHandler(
    tasks: _tasks,
    eventRecorder: _eventRecorder,
    log: _log,
  );
  late final TaskBudgetPolicy _budgetPolicy = TaskBudgetPolicy(
    tasks: _tasks,
    kv: _kv,
    budgetConfig: _budgetConfig,
    eventBus: _eventBus,
    dataDir: _dataDir,
    failTask: _failureHandler.markFailedOrRetry,
    log: _log,
  );
  late final WorkflowWorktreeBinder _worktreeBinder = WorkflowWorktreeBinder(
    worktreeManager: _worktreeManager,
    workflowRunRepository: _workflowRunRepository,
    failTask: _failureHandler.markFailedOrRetry,
  );
  late final WorkflowOneShotRunner _workflowOneShotRunner = WorkflowOneShotRunner(
    runner: _workflowCliRunner,
    workflowStepExecutionRepository: _workflowStepExecutionRepository,
    messages: _messages,
    kv: _kv,
    budgetPolicy: _budgetPolicy,
    tasks: _tasks,
    eventRecorder: _eventRecorder,
    log: _log,
  );

  Timer? _timer;
  Future<bool>? _inFlightPoll;

  void hydrateWorkflowSharedWorktreeBinding(WorkflowWorktreeBinding binding, {required String workflowRunId}) {
    _worktreeBinder.hydrateWorkflowSharedWorktreeBinding(binding, workflowRunId: workflowRunId);
  }

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(pollInterval, (_) {
      unawaited(pollOnce());
    });
    unawaited(pollOnce());
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _inFlightPoll;
  }

  Future<bool> pollOnce() {
    final inFlight = _inFlightPoll;
    if (inFlight != null) return inFlight;

    late final Future<bool> future;
    future = _pollOnceInner().whenComplete(() {
      if (identical(_inFlightPoll, future)) {
        _inFlightPoll = null;
      }
    });
    _inFlightPoll = future;
    return future;
  }

  Future<bool> _pollOnceInner() async {
    // Pool mode: dispatch as many queued tasks as there are compatible idle runners.
    if (_pool.maxConcurrentTasks > 0) {
      final queued = await _tasks.list(status: TaskStatus.queued);
      if (queued.isEmpty) return false;

      _runnerPoolCoordinator.triggerSpawnIfNeeded();

      queued.sort((a, b) {
        final createdAtCompare = a.createdAt.compareTo(b.createdAt);
        if (createdAtCompare != 0) return createdAtCompare;
        return a.id.compareTo(b.id);
      });

      var didWork = false;
      for (final task in queued) {
        final disposition = await _prepareQueuedTask(task);
        if (disposition == _QueuedTaskDisposition.waiting) {
          continue;
        }
        if (disposition == _QueuedTaskDisposition.handled) {
          didWork = true;
          continue;
        }

        final profile = resolveProfile(task.type);
        final runner = _runnerPoolCoordinator.acquireRunnerForTask(task, profile);
        if (runner == null) {
          continue;
        }
        _runnerPoolCoordinator.clearWaitLog(task.id);

        final runnerIndex = _pool.indexOf(runner);
        final runningTask = await _checkout(task);
        if (runningTask == null) {
          _pool.release(runner);
          continue;
        }

        didWork = true;
        _observer?.markBusy(runnerIndex, taskId: runningTask.id);
        unawaited(_runPoolTask(runningTask, runner, runnerIndex: runnerIndex));
      }
      return didWork;
    }

    // Single-harness fallback: use primary runner directly when idle.
    if (_turns.activeSessionIds.isNotEmpty) {
      return false;
    }

    final queued = await _tasks.list(status: TaskStatus.queued);
    if (queued.isEmpty) return false;

    queued.sort((a, b) {
      final createdAtCompare = a.createdAt.compareTo(b.createdAt);
      if (createdAtCompare != 0) return createdAtCompare;
      return a.id.compareTo(b.id);
    });

    var didWork = false;
    for (final task in queued) {
      final disposition = await _prepareQueuedTask(task);
      if (disposition == _QueuedTaskDisposition.waiting) {
        continue;
      }
      if (disposition == _QueuedTaskDisposition.handled) {
        didWork = true;
        continue;
      }

      _observer?.markBusy(0, taskId: task.id);
      final runningTask = await _checkout(task);
      if (runningTask == null) {
        _observer?.markIdle(0);
        continue;
      }

      try {
        await _execute(runningTask);
        return true;
      } finally {
        _observer?.markIdle(0);
      }
    }

    return didWork;
  }

  /// Shared task execution logic for both pool-mode and single-harness paths.
  Future<void> _executeCore(
    Task runningTask, {
    required int runnerIndex,
    String? provider,
    String? runnerProfileId,
    required Future<String> Function(
      String sessionId, {
      String? directory,
      String? model,
      String? effort,
      BehaviorFileService? behaviorOverride,
      PromptScope? promptScope,
    })
    reserveTurn,
    required void Function(
      String sessionId,
      String turnId,
      List<Map<String, dynamic>> messages, {
      String? source,
      String agentName,
    })
    executeTurn,
    required Future<TurnOutcome> Function(String sessionId, String turnId) waitForOutcome,
    void Function(List<String>?)? setTaskToolFilter,
    void Function(bool)? setTaskReadOnly,
  }) async {
    var task = await _hydrateWorkflowStepExecution(runningTask);
    _log.info(
      'Task execution start: ${task.id} "${task.title}" '
      'type=${task.type.name}, provider=${provider ?? "default"}, '
      'profile=${runnerProfileId ?? "none"}',
    );
    WorktreeInfo? worktreeInfo;
    Project? project;
    GitStatusSnapshot? readOnlyProjectStatusBeforeTurn;
    try {
      // Resolve project for this task.
      final projectService = _projectService;
      if (projectService != null) {
        final projectId = taskProjectId(task);
        if (projectId != null) {
          project = await projectService.get(projectId);
          if (project == null) {
            await _failureHandler.markFailedOrRetry(
              task,
              errorSummary: 'Project "$projectId" not found',
              retryable: false,
            );
            return;
          }
          if (project.status == ProjectStatus.error) {
            await _failureHandler.markFailedOrRetry(
              task,
              errorSummary: project.errorMessage?.trim().isNotEmpty == true
                  ? 'Project "${project.name}" failed to clone: ${project.errorMessage!.trim()}'
                  : 'Project "${project.name}" failed to clone',
              retryable: false,
            );
            return;
          }
          if (project.status == ProjectStatus.cloning) {
            await _failureHandler.markFailedOrRetry(
              task,
              errorSummary: 'Project "${project.name}" is still cloning',
              retryable: false,
            );
            return;
          }
        } else {
          project = await projectService.getDefaultProject();
        }
        final explicitBaseRef = _taskBaseRef(task);
        final effectiveBaseRef = await _resolveEffectiveBaseRef(task, project, explicitBaseRef: explicitBaseRef);
        final workflowOwnedBranchTask = await _worktreeBinder.workflowOwnedWorktreeKey(task) != null;
        final workflowOwnedLocalBaseRef = _isWorkflowOwnedLocalRef(effectiveBaseRef);
        final worktreeBaseRef = await _worktreeBaseRefFor(task, project, effectiveBaseRef);
        final strictGitValidation =
            _isWorkflowOrchestrated(task) && !workflowOwnedBranchTask && !workflowOwnedLocalBaseRef;
        final freshnessRef = (workflowOwnedBranchTask || workflowOwnedLocalBaseRef)
            ? null
            : _freshnessRefFor(project, effectiveBaseRef);
        if (strictGitValidation || freshnessRef != null) {
          try {
            await projectService.ensureFresh(project, ref: freshnessRef, strict: strictGitValidation);
          } catch (e) {
            await _failureHandler.markFailedOrRetry(
              task,
              errorSummary: 'Git reference validation failed for project "${project.name}": $e',
              retryable: false,
            );
            return;
          }
        } else if (workflowOwnedLocalBaseRef) {
          _log.fine(
            'Task ${task.id}: skipping freshness fetch for local workflow-owned ref "$effectiveBaseRef" '
            'in project "${project.name}"',
          );
        }
        if (worktreeBaseRef != null && worktreeBaseRef.isNotEmpty) {
          final nextConfig = Map<String, dynamic>.from(task.configJson)..['_baseRef'] = worktreeBaseRef;
          task = await _tasks.updateFields(task.id, configJson: nextConfig);
        }
      }

      final usesInlineWorkflowCheckout = await _worktreeBinder.usesInlineProjectCheckout(task);
      if (_taskNeedsWorktree(task) && usesInlineWorkflowCheckout && project != null) {
        final inlineBaseRef = _taskBaseRef(task);
        if (inlineBaseRef != null && inlineBaseRef.isNotEmpty) {
          final prepared = await _worktreeBinder.ensureInlineWorkflowBranchCheckedOut(task, project, inlineBaseRef);
          if (!prepared) {
            return;
          }
        }
      }

      // Worktree setup for coding tasks
      if (_taskNeedsWorktree(task) && _worktreeManager != null && !usesInlineWorkflowCheckout) {
        final workflowWorktreeKey = await _worktreeBinder.workflowOwnedWorktreeKey(task);
        final workflowWorktreeTaskId = await _worktreeBinder.workflowOwnedWorktreeTaskId(task);
        final requiresStoryBranch = await _worktreeBinder.workflowMapIterationOwnsBranch(task);
        if (workflowWorktreeKey != null && workflowWorktreeTaskId != null) {
          worktreeInfo = await _worktreeBinder.resolveWorkflowSharedWorktree(
            task,
            workflowWorktreeKey: workflowWorktreeKey,
            workflowWorktreeTaskId: workflowWorktreeTaskId,
            project: project,
            createBranch: requiresStoryBranch,
            baseRef: _taskBaseRef(task),
          );
        } else {
          // Pass project only when it's not the implicit _local project.
          final worktreeProject = (project != null && project.id != '_local') ? project : null;
          worktreeInfo = await _worktreeManager.create(
            task.id,
            project: worktreeProject,
            baseRef: _taskBaseRef(task),
            existingWorktreeJson: task.worktreeJson,
          );
        }
        _taskFileGuard?.register(task.id, worktreeInfo.path);
        task = await _tasks.updateFields(task.id, worktreeJson: worktreeInfo.toJson());

        // Apply workflow externalArtifactMount (per-story file copy) when the
        // enclosing workflow resolved a source file for this map iteration.
        final mountJson = _worktreeBinder.externalArtifactMount(task);
        if (mountJson != null) {
          final fromProjectDir = mountJson['fromProjectDir'] as String?;
          final relativeSource = mountJson['source'] as String?;
          final mountMode = (mountJson['mode'] as String?) ?? 'per-story-copy';
          if (fromProjectDir != null &&
              relativeSource != null &&
              fromProjectDir.isNotEmpty &&
              relativeSource.isNotEmpty) {
            try {
              await _worktreeManager.applyExternalArtifactMount(
                worktree: worktreeInfo,
                fromProjectDir: fromProjectDir,
                relativeSourcePath: relativeSource,
                mode: mountMode,
              );
            } on WorktreeException catch (e) {
              _log.warning('externalArtifactMount failed for task ${task.id}: $e');
            }
          }
        }
      }

      final requiredInputPath = TaskConfigView(task, log: _log).requiredInputPath;
      if (requiredInputPath != null) {
        final effectiveWorktreePath = worktreeInfo?.path;
        final fallbackProjectPath = (project != null && project.id != '_local') ? project.localPath : null;
        final rootPath = (effectiveWorktreePath?.isNotEmpty ?? false) ? effectiveWorktreePath : fallbackProjectPath;
        final exists = rootPath != null && File(p.join(rootPath, requiredInputPath)).existsSync();
        if (!exists) {
          final rootLabel = rootPath == null || rootPath.isEmpty ? 'task worktree' : rootPath;
          await _failureHandler.markFailedOrRetry(
            task,
            errorSummary: 'artifact-propagation: required input path "$requiredInputPath" is missing in "$rootLabel"',
            retryable: false,
          );
          return;
        }
      }

      readOnlyProjectStatusBeforeTurn = await _captureReadOnlyProjectStatus(task, project);

      // continueSession: reuse the root session from the preceding agent step.
      final continueSessionId = TaskConfigView(task, log: _log).continueSessionId;
      final Session session;
      if (continueSessionId != null) {
        final existing = await _sessions.getSession(continueSessionId);
        if (existing == null || existing.type == SessionType.archive) {
          await _failureHandler.markFailedOrRetry(
            task,
            errorSummary:
                'continueSession: session "$continueSessionId" not found or archived. '
                'Ensure the preceding step completed successfully before this step runs.',
            retryable: false,
          );
          return;
        }
        session = existing;
      } else {
        session = await _sessions.getOrCreateByKey(
          SessionKey.taskSession(taskId: runningTask.id),
          type: SessionType.task,
        );
      }

      if (task.sessionId != session.id) {
        task = await _tasks.updateFields(task.id, sessionId: session.id);
      }

      // Pre-turn budget check — fail-safe open policy.
      final goalForBudget = task.goalId != null ? await _goals?.get(task.goalId!) : null;
      final (budgetVerdict, budgetWarningMessage) = await _budgetPolicy.checkBudget(
        task,
        session.id,
        goal: goalForBudget,
      );
      if (budgetVerdict == BudgetVerdict.exceeded) return;

      final pendingMessage = await _composePendingMessage(task, session.id, workingDirectory: worktreeInfo?.path);
      if (pendingMessage == null) {
        _log.warning('Task ${task.id} had no message to execute; marking failed');
        await _failureHandler.markFailedOrRetry(task, errorSummary: 'Task had no executable prompt', retryable: false);
        return;
      }
      final modelOverride = _modelOverride(task);
      final effortOverride = _effortOverride(task);
      final tokenBudget = _tokenBudget(task);
      final projectDirForTask = (project != null && project.id != '_local') ? project.localPath : null;

      if (budgetWarningMessage != null) {
        await _messages.insertMessage(sessionId: session.id, role: 'system', content: budgetWarningMessage);
      }

      if (_isWorkflowOrchestrated(task)) {
        final outcome = await _workflowOneShotRunner.execute(
          task,
          sessionId: session.id,
          pendingMessage: pendingMessage,
          provider: provider ?? task.provider ?? 'claude',
          profileId: runnerProfileId ?? resolveProfile(task.type),
          workingDirectory: worktreeInfo?.path ?? projectDirForTask,
          modelOverride: modelOverride,
          effortOverride: effortOverride,
          sandboxOverride: _isReadOnlyTask(task) ? 'read-only' : null,
        );
        _observer?.recordTurn(
          runnerIndex,
          inputTokens: outcome.inputTokens,
          outputTokens: outcome.outputTokens,
          isError: outcome.status != TurnStatus.completed,
          turnDuration: outcome.turnDuration,
          cacheReadTokens: outcome.cacheReadTokens,
          cacheWriteTokens: outcome.cacheWriteTokens,
          toolCalls: outcome.toolCalls,
        );
        if (outcome.status != TurnStatus.completed) {
          await _failureHandler.markFailedOrRetry(
            task,
            errorSummary: outcome.errorMessage ?? 'Workflow one-shot execution failed',
          );
          return;
        }
        final refreshedTask = await _tasks.get(task.id) ?? task;
        final readOnlyMutationSummary = await _readOnlyMutationSummary(
          refreshedTask,
          project,
          readOnlyProjectStatusBeforeTurn,
        );
        if (readOnlyMutationSummary != null) {
          _log.warning('Task ${task.id}: $readOnlyMutationSummary');
          await _failureHandler.markFailedOrRetry(task, errorSummary: readOnlyMutationSummary, retryable: false);
          return;
        }
        final artifacts = await _artifactCollector.collect(refreshedTask);
        for (final artifact in artifacts) {
          _eventRecorder?.recordArtifactCreated(task.id, name: artifact.name, kind: artifact.kind.name);
        }
        final postStatus = _resolvePostCompletionStatus(refreshedTask);
        await _tasks.transition(task.id, postStatus, trigger: 'system');
        final onAutoAccept = _onAutoAccept;
        if (onAutoAccept != null && postStatus == TaskStatus.review && !_isWorkflowOrchestrated(task)) {
          await onAutoAccept(task.id);
        }
        return;
      }

      await _messages.insertMessage(sessionId: session.id, role: 'user', content: pendingMessage);

      final clearedConfig = _clearPushBackComment(task.configJson);
      if (clearedConfig != null) {
        task = await _tasks.updateFields(task.id, configJson: clearedConfig);
      }

      final sessionMessages = await _messages.getMessages(session.id);
      final turnMessages = sessionMessages
          .map(
            (message) => <String, dynamic>{
              'id': message.id,
              'sessionId': message.sessionId,
              'role': message.role,
              'content': message.content,
              'cursor': message.cursor,
              'metadata': message.metadata,
              'createdAt': message.createdAt.toIso8601String(),
            },
          )
          .toList(growable: false);

      final turnDirectory = worktreeInfo?.path ?? projectDirForTask;

      // Create task-scoped BehaviorFileService for workflow tasks first.
      BehaviorFileService? taskBehavior;
      final workflowWorkspaceDir = _worktreeBinder.workflowWorkspaceDir(task);
      final workspaceDir = _workspaceDir;
      if (workflowWorkspaceDir != null && workflowWorkspaceDir.trim().isNotEmpty) {
        taskBehavior = BehaviorFileService(
          workspaceDir: workflowWorkspaceDir,
          projectDir: projectDirForTask,
          maxMemoryBytes: _maxMemoryBytes,
          compactInstructions: _compactInstructions,
          identifierPreservation: _identifierPreservation,
          identifierInstructions: _identifierInstructions,
        );
      } else if (projectDirForTask != null && workspaceDir != null) {
        taskBehavior = BehaviorFileService(
          workspaceDir: workspaceDir,
          projectDir: projectDirForTask,
          maxMemoryBytes: _maxMemoryBytes,
          compactInstructions: _compactInstructions,
          identifierPreservation: _identifierPreservation,
          identifierInstructions: _identifierInstructions,
        );
      }

      setTaskToolFilter?.call(_allowedTools(task));
      setTaskReadOnly?.call(_isReadOnlyTask(task));

      // Determine prompt scope for this task turn.
      // Restricted profile gets tools-only; all other tasks get the lean task
      // scope (no user/memory noise).
      final PromptScope promptScope;
      if (workflowWorkspaceDir != null && workflowWorkspaceDir.trim().isNotEmpty) {
        promptScope = PromptScope.task;
      } else if (runnerProfileId == 'restricted') {
        promptScope = PromptScope.restricted;
      } else {
        promptScope = PromptScope.task;
      }

      final turnId = await reserveTurn(
        session.id,
        directory: turnDirectory,
        model: modelOverride,
        effort: effortOverride,
        behaviorOverride: taskBehavior,
        promptScope: promptScope,
      );
      executeTurn(session.id, turnId, turnMessages, source: 'task', agentName: 'task');
      final outcome = await waitForOutcome(session.id, turnId);
      _observer?.recordTurn(
        runnerIndex,
        inputTokens: outcome.inputTokens,
        outputTokens: outcome.outputTokens,
        isError: outcome.status != TurnStatus.completed,
        turnDuration: outcome.turnDuration,
        cacheReadTokens: outcome.cacheReadTokens,
        cacheWriteTokens: outcome.cacheWriteTokens,
        toolCalls: outcome.toolCalls,
      );

      // S08: Record synchronous token update + tool call events (NF04 durability).
      // Must execute before S07's fire-and-forget trace write.
      final recorder = _eventRecorder;
      if (recorder != null) {
        recorder.recordTokenUpdate(
          task.id,
          inputTokens: outcome.inputTokens,
          outputTokens: outcome.outputTokens,
          cacheReadTokens: outcome.cacheReadTokens,
          cacheWriteTokens: outcome.cacheWriteTokens,
        );
        for (final tc in outcome.toolCalls) {
          recorder.recordToolCalled(
            task.id,
            name: tc.name,
            success: tc.success,
            durationMs: tc.durationMs,
            errorType: tc.errorType,
            context: tc.context,
          );
        }
      }

      final traceService = _traceService;
      if (traceService != null) {
        unawaited(
          _persistTrace(
            traceService,
            outcome: outcome,
            taskId: task.id,
            runnerId: runnerIndex,
            model: modelOverride,
            provider: provider,
          ),
        );
      }

      if (outcome.status == TurnStatus.completed) {
        final readOnlyMutationSummary = await _readOnlyMutationSummary(task, project, readOnlyProjectStatusBeforeTurn);
        if (readOnlyMutationSummary != null) {
          _log.warning('Task ${task.id}: $readOnlyMutationSummary');
          await _failureHandler.markFailedOrRetry(task, errorSummary: readOnlyMutationSummary, retryable: false);
          return;
        }
        final refreshed = await _tasks.get(task.id) ?? task;
        if (refreshed.status == TaskStatus.cancelled) {
          return;
        }
        final artifacts = await _artifactCollector.collect(refreshed);
        for (final artifact in artifacts) {
          _eventRecorder?.recordArtifactCreated(task.id, name: artifact.name, kind: artifact.kind.name);
        }
        if (tokenBudget != null && outcome.totalTokens > tokenBudget) {
          _log.warning('Task ${task.id} exceeded token budget ($tokenBudget < ${outcome.totalTokens}); marking failed');
          await _failureHandler.markFailedOrRetry(
            task,
            errorSummary: 'Token budget exceeded: used ${outcome.totalTokens} tokens against a limit of $tokenBudget',
            retryable: false,
          );
          return;
        }
        final postStatus = _resolvePostCompletionStatus(task);
        await _tasks.transition(task.id, postStatus, trigger: 'system');
        final onAutoAccept = _onAutoAccept;
        if (onAutoAccept != null && postStatus == TaskStatus.review) {
          if (_isWorkflowOrchestrated(task)) {
            _log.fine(
              'Task ${task.id}: skipping task-level auto-accept because workflow git promotion '
              'owns publish/merge for this task',
            );
            return;
          }
          _log.info('Auto-accepting completed task ${task.id} after review transition');
          try {
            await onAutoAccept(task.id);
          } catch (error, stackTrace) {
            _log.warning('Auto-accept failed for task ${task.id}: $error', error, stackTrace);
            if (_isWorkflowOrchestrated(task)) {
              await _failureHandler.markFailedOrRetry(
                task,
                errorSummary: _failureHandler.sanitizeErrorSummary(error.toString()),
                retryable: false,
              );
            }
          }
        }
        return;
      }

      // Mid-turn loop detection (tool fingerprinting) sets loopDetection on outcome.
      if (outcome.loopDetection != null) {
        _log.warning('Loop detected during task ${task.id}: ${outcome.loopDetection!.message}');
        await _failureHandler.markFailedOrRetry(
          task,
          errorSummary: 'Loop detected: ${outcome.loopDetection!.message}',
          retryable: false,
        );
        return;
      }

      await _failureHandler.markFailedOrRetry(
        task,
        errorSummary: outcome.errorMessage ?? _defaultTurnFailureSummary(outcome.status),
      );
      return;
    } on LoopDetectedException catch (e) {
      // Pre-turn loop detection (turn chain depth or token velocity).
      _log.warning('Loop detected during task ${task.id}: ${e.message}');
      await _failureHandler.markFailedOrRetry(task, errorSummary: 'Loop detected: ${e.message}', retryable: false);
      return;
    } catch (error, stackTrace) {
      if (error is GitNotFoundException || error is WorktreeException) {
        _log.warning('Worktree setup failed for task ${task.id}: $error');
      } else {
        _log.warning('Task execution failed for ${task.id}: $error', error, stackTrace);
      }
      await _failureHandler.markFailedOrRetry(
        task,
        errorSummary: _failureHandler.sanitizeErrorSummary(error.toString()),
      );
      return;
    } finally {
      // Clear per-task tool filter to prevent stale state on the next task.
      setTaskToolFilter?.call(null);
      setTaskReadOnly?.call(false);
    }
  }
}

enum _QueuedTaskDisposition { ready, waiting, handled }
