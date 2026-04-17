import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowTaskConfig;
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
import 'task_event_recorder.dart';
import 'task_file_guard.dart';
import 'task_project_ref.dart';
import 'task_service.dart';
import 'workflow_cli_runner.dart';
import 'worktree_manager.dart';

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

  Timer? _timer;
  Future<bool>? _inFlightPoll;
  bool _isSpawning = false;
  final Map<String, WorktreeInfo> _workflowSharedWorktrees = {};
  final Set<String> _runnerWaitLoggedTaskIds = <String>{};

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

      // Lazy pool growth: spawn a runner if tasks are waiting but none available.
      if (_pool.availableCount == 0 && _pool.spawnableCount > 0 && !_isSpawning) {
        _triggerSpawn();
      }

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
        final runner = _acquirePoolRunnerForTask(task, profile);
        if (runner == null) {
          continue;
        }
        _runnerWaitLoggedTaskIds.remove(task.id);

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

  Future<void> _runPoolTask(Task runningTask, TurnRunner runner, {required int runnerIndex}) async {
    try {
      await _executeWithRunner(runningTask, runner, runnerIndex: runnerIndex);
    } finally {
      _observer?.markIdle(runnerIndex);
      _pool.release(runner);
    }
  }

  Future<Task?> _checkout(Task queuedTask) async {
    try {
      return await _tasks.transition(queuedTask.id, TaskStatus.running, trigger: 'system');
    } on StateError {
      return null;
    }
  }

  Future<_QueuedTaskDisposition> _prepareQueuedTask(Task task) async {
    final projectService = _projectService;
    if (projectService == null) {
      return _QueuedTaskDisposition.ready;
    }

    final projectId = taskProjectId(task);
    if (projectId == null) {
      return _QueuedTaskDisposition.ready;
    }

    final project = await projectService.get(projectId);
    if (project == null) {
      await _markFailedOrRetry(task, errorSummary: 'Project "$projectId" not found', retryable: false);
      return _QueuedTaskDisposition.handled;
    }

    if (project.status == ProjectStatus.cloning) {
      return _QueuedTaskDisposition.waiting;
    }

    if (project.status == ProjectStatus.error) {
      final detail = project.errorMessage?.trim();
      final summary = (detail == null || detail.isEmpty)
          ? 'Project "${project.name}" failed to clone'
          : 'Project "${project.name}" failed to clone: $detail';
      await _markFailedOrRetry(task, errorSummary: summary, retryable: false);
      return _QueuedTaskDisposition.handled;
    }

    return _QueuedTaskDisposition.ready;
  }

  /// Pool-mode execution: uses a specific acquired [runner].
  Future<void> _executeWithRunner(Task runningTask, TurnRunner runner, {required int runnerIndex}) async {
    return _executeCore(
      runningTask,
      runnerIndex: runnerIndex,
      provider: runner.providerId,
      runnerProfileId: runner.profileId,
      reserveTurn:
          (
            sessionId, {
            String? directory,
            String? model,
            String? effort,
            BehaviorFileService? behaviorOverride,
            PromptScope? promptScope,
          }) => runner.reserveTurn(
            sessionId,
            agentName: 'task',
            directory: directory,
            model: model,
            effort: effort,
            behaviorOverride: behaviorOverride,
            promptScope: promptScope,
          ),
      executeTurn: runner.executeTurn,
      waitForOutcome: runner.waitForOutcome,
      setTaskToolFilter: runner.setTaskToolFilter,
      setTaskReadOnly: runner.setTaskReadOnly,
    );
  }

  /// Single-harness fallback execution: uses TurnManager (primary runner).
  Future<void> _execute(Task runningTask) async {
    return _executeCore(
      runningTask,
      runnerIndex: 0,
      runnerProfileId: resolveProfile(runningTask.type),
      reserveTurn:
          (
            sessionId, {
            String? directory,
            String? model,
            String? effort,
            BehaviorFileService? behaviorOverride,
            PromptScope? promptScope,
          }) => _reserveSharedTurn(
            sessionId,
            directory: directory,
            model: model,
            effort: effort,
            behaviorOverride: behaviorOverride,
            promptScope: promptScope,
          ),
      executeTurn: _turns.executeTurn,
      waitForOutcome: _turns.waitForOutcome,
      setTaskToolFilter: _turns.setTaskToolFilter,
      setTaskReadOnly: _turns.setTaskReadOnly,
    );
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
    var task = runningTask;
    _log.info(
      'Task execution start: ${task.id} "${task.title}" '
      'type=${task.type.name}, provider=${provider ?? "default"}, '
      'profile=${runnerProfileId ?? "none"}',
    );
    WorktreeInfo? worktreeInfo;
    Project? project;
    Set<String>? readOnlyProjectStatusBeforeTurn;
    try {
      // Resolve project for this task.
      final projectService = _projectService;
      if (projectService != null) {
        final projectId = taskProjectId(task);
        if (projectId != null) {
          project = await projectService.get(projectId);
          if (project == null) {
            await _markFailedOrRetry(task, errorSummary: 'Project "$projectId" not found', retryable: false);
            return;
          }
          if (project.status == ProjectStatus.error) {
            await _markFailedOrRetry(
              task,
              errorSummary: project.errorMessage?.trim().isNotEmpty == true
                  ? 'Project "${project.name}" failed to clone: ${project.errorMessage!.trim()}'
                  : 'Project "${project.name}" failed to clone',
              retryable: false,
            );
            return;
          }
          if (project.status == ProjectStatus.cloning) {
            await _markFailedOrRetry(
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
        final workflowOwnedBranchTask = _workflowOwnedWorktreeKey(task) != null;
        final workflowOwnedLocalBaseRef = _isWorkflowOwnedLocalRef(effectiveBaseRef);
        final worktreeBaseRef = _worktreeBaseRefFor(task, project, effectiveBaseRef);
        final strictGitValidation =
            task.workflowRunId != null && !workflowOwnedBranchTask && !workflowOwnedLocalBaseRef;
        final freshnessRef = (workflowOwnedBranchTask || workflowOwnedLocalBaseRef)
            ? null
            : _freshnessRefFor(project, effectiveBaseRef);
        if (strictGitValidation || freshnessRef != null) {
          try {
            await projectService.ensureFresh(project, ref: freshnessRef, strict: strictGitValidation);
          } catch (e) {
            await _markFailedOrRetry(
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

      readOnlyProjectStatusBeforeTurn = await _captureReadOnlyProjectStatus(task, project);

      // Worktree setup for coding tasks
      if (task.type == TaskType.coding && _worktreeManager != null) {
        final workflowWorktreeKey = _workflowOwnedWorktreeKey(task);
        final workflowWorktreeTaskId = _workflowOwnedWorktreeTaskId(task);
        final requiresStoryBranch = _workflowMapIterationOwnsBranch(task);
        if (workflowWorktreeKey != null && workflowWorktreeTaskId != null) {
          final existing = _workflowSharedWorktrees[workflowWorktreeKey];
          if (existing != null) {
            worktreeInfo = existing;
          } else {
            // Pass project only when it's not the implicit _local project.
            final worktreeProject = (project != null && project.id != '_local') ? project : null;
            worktreeInfo = await _worktreeManager.create(
              workflowWorktreeTaskId,
              project: worktreeProject,
              baseRef: _taskBaseRef(task),
              createBranch: requiresStoryBranch,
            );
            _workflowSharedWorktrees[workflowWorktreeKey] = worktreeInfo;
          }
        } else {
          // Pass project only when it's not the implicit _local project.
          final worktreeProject = (project != null && project.id != '_local') ? project : null;
          worktreeInfo = await _worktreeManager.create(task.id, project: worktreeProject, baseRef: _taskBaseRef(task));
        }
        _taskFileGuard?.register(task.id, worktreeInfo.path);
        task = await _tasks.updateFields(task.id, worktreeJson: worktreeInfo.toJson());
      }

      // continueSession: reuse the root session from the preceding agent step.
      final continueSessionId = task.configJson['_continueSessionId'] as String?;
      final Session session;
      if (continueSessionId != null) {
        final existing = await _sessions.getSession(continueSessionId);
        if (existing == null || existing.type == SessionType.archive) {
          await _markFailedOrRetry(
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
      final (budgetVerdict, budgetWarningMessage) = await _checkBudget(task, session.id, goal: goalForBudget);
      if (budgetVerdict == _BudgetVerdict.exceeded) return;

      final pendingMessage = await _composePendingMessage(task, session.id, workingDirectory: worktreeInfo?.path);
      if (pendingMessage == null) {
        _log.warning('Task ${task.id} had no message to execute; marking failed');
        await _markFailedOrRetry(task, errorSummary: 'Task had no executable prompt', retryable: false);
        return;
      }
      final modelOverride = _modelOverride(task);
      final effortOverride = _effortOverride(task);
      final tokenBudget = _tokenBudget(task);
      final projectDirForTask = (project != null && project.id != '_local') ? project.localPath : null;

      if (budgetWarningMessage != null) {
        await _messages.insertMessage(sessionId: session.id, role: 'system', content: budgetWarningMessage);
      }

      if (task.workflowRunId != null) {
        final outcome = await _executeWorkflowOneShotTask(
          task,
          sessionId: session.id,
          pendingMessage: pendingMessage,
          provider: provider ?? task.provider ?? 'claude',
          profileId: runnerProfileId ?? resolveProfile(task.type),
          workingDirectory: worktreeInfo?.path ?? projectDirForTask,
          modelOverride: modelOverride,
          effortOverride: effortOverride,
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
          await _markFailedOrRetry(task, errorSummary: outcome.errorMessage ?? 'Workflow one-shot execution failed');
          return;
        }
        final refreshedTask = await _tasks.get(task.id) ?? task;
        final artifacts = await _artifactCollector.collect(refreshedTask);
        for (final artifact in artifacts) {
          _eventRecorder?.recordArtifactCreated(task.id, name: artifact.name, kind: artifact.kind.name);
        }
        final postStatus = _resolvePostCompletionStatus(task);
        await _tasks.transition(task.id, postStatus, trigger: 'system');
        final onAutoAccept = _onAutoAccept;
        if (onAutoAccept != null && postStatus == TaskStatus.review && !_skipAutoAcceptForWorkflowTask(task)) {
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
      final workflowWorkspaceDir = task.configJson['_workflowWorkspaceDir'] as String?;
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
          await _markFailedOrRetry(task, errorSummary: readOnlyMutationSummary, retryable: false);
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
          await _markFailedOrRetry(
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
          if (_skipAutoAcceptForWorkflowTask(task)) {
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
            if (task.workflowRunId != null) {
              await _markFailedOrRetry(task, errorSummary: _sanitizeErrorSummary(error.toString()), retryable: false);
            }
          }
        }
        return;
      }

      // Mid-turn loop detection (tool fingerprinting) sets loopDetection on outcome.
      if (outcome.loopDetection != null) {
        _log.warning('Loop detected during task ${task.id}: ${outcome.loopDetection!.message}');
        await _markFailedOrRetry(
          task,
          errorSummary: 'Loop detected: ${outcome.loopDetection!.message}',
          retryable: false,
        );
        return;
      }

      await _markFailedOrRetry(task, errorSummary: outcome.errorMessage ?? _defaultTurnFailureSummary(outcome.status));
      return;
    } on LoopDetectedException catch (e) {
      // Pre-turn loop detection (turn chain depth or token velocity).
      _log.warning('Loop detected during task ${task.id}: ${e.message}');
      await _markFailedOrRetry(task, errorSummary: 'Loop detected: ${e.message}', retryable: false);
      return;
    } catch (error, stackTrace) {
      if (error is GitNotFoundException || error is WorktreeException) {
        _log.warning('Worktree setup failed for task ${task.id}: $error');
      } else {
        _log.warning('Task execution failed for ${task.id}: $error', error, stackTrace);
      }
      await _markFailedOrRetry(task, errorSummary: _sanitizeErrorSummary(error.toString()));
      return;
    } finally {
      // Clear per-task tool filter to prevent stale state on the next task.
      setTaskToolFilter?.call(null);
      setTaskReadOnly?.call(false);
    }
  }

  Future<String> _reserveSharedTurn(
    String sessionId, {
    String? directory,
    String? model,
    String? effort,
    BehaviorFileService? behaviorOverride,
    PromptScope? promptScope,
  }) async {
    while (true) {
      try {
        return await _turns.reserveTurn(
          sessionId,
          agentName: 'task',
          directory: directory,
          model: model,
          effort: effort,
          behaviorOverride: behaviorOverride,
          promptScope: promptScope,
        );
      } on BusyTurnException {
        await Future<void>.delayed(pollInterval);
      }
    }
  }

  Future<TurnOutcome> _executeWorkflowOneShotTask(
    Task task, {
    required String sessionId,
    required String pendingMessage,
    required String provider,
    required String profileId,
    required String? workingDirectory,
    required String? modelOverride,
    required String? effortOverride,
  }) async {
    final runner = _workflowCliRunner;
    if (runner == null) {
      throw StateError('Workflow one-shot execution requested but no runner is configured');
    }

    final cwd = workingDirectory ?? Directory.current.path;
    final followUps = WorkflowTaskConfig.readFollowUpPrompts(task.configJson);
    final structuredSchema = WorkflowTaskConfig.readStructuredSchema(task.configJson);

    String? providerSessionId = WorkflowTaskConfig.readContinueProviderSessionId(task.configJson);
    final appendSystemPrompt = switch (task.configJson['appendSystemPrompt']) {
      final String value when value.trim().isNotEmpty => value,
      _ => null,
    };
    final startedAt = DateTime.now();
    var inputTokens = 0;
    var outputTokens = 0;
    var cacheReadTokens = 0;
    var cacheWriteTokens = 0;

    final prompts = <String>[pendingMessage, ...followUps];
    for (final prompt in prompts) {
      final (budgetVerdict, budgetWarningMessage) = await _checkBudget(task, sessionId);
      if (budgetVerdict == _BudgetVerdict.exceeded) {
        return TurnOutcome(
          turnId: 'workflow-oneshot-budget',
          sessionId: sessionId,
          status: TurnStatus.failed,
          errorMessage: 'Workflow one-shot task exceeded its token budget',
          completedAt: DateTime.now(),
        );
      }
      if (budgetWarningMessage != null) {
        await _messages.insertMessage(sessionId: sessionId, role: 'system', content: budgetWarningMessage);
      }

      await _messages.insertMessage(sessionId: sessionId, role: 'user', content: prompt);
      final turnResult = await runner.executeTurn(
        provider: provider,
        prompt: prompt,
        workingDirectory: cwd,
        profileId: profileId,
        providerSessionId: providerSessionId,
        model: modelOverride,
        effort: effortOverride,
        appendSystemPrompt: appendSystemPrompt,
      );
      providerSessionId = turnResult.providerSessionId.isEmpty ? providerSessionId : turnResult.providerSessionId;
      inputTokens += turnResult.inputTokens;
      outputTokens += turnResult.outputTokens;
      cacheReadTokens += turnResult.cacheReadTokens;
      cacheWriteTokens += turnResult.cacheWriteTokens;
      await _trackWorkflowSessionUsage(
        sessionId,
        provider: provider,
        inputTokens: turnResult.inputTokens,
        outputTokens: turnResult.outputTokens,
        cacheReadTokens: turnResult.cacheReadTokens,
        cacheWriteTokens: turnResult.cacheWriteTokens,
        totalCostUsd: turnResult.totalCostUsd,
      );
      final assistantText = turnResult.structuredOutput != null
          ? jsonEncode(turnResult.structuredOutput)
          : turnResult.responseText;
      await _messages.insertMessage(sessionId: sessionId, role: 'assistant', content: assistantText);
    }

    Map<String, dynamic>? structuredPayload;
    if (structuredSchema != null) {
      final extractionPrompt =
          'Based on your work above, produce the structured output. '
          'Output ONLY the JSON object. Do NOT use any tools.';
      await _messages.insertMessage(sessionId: sessionId, role: 'user', content: extractionPrompt);
      final turnResult = await runner.executeTurn(
        provider: provider,
        prompt: extractionPrompt,
        workingDirectory: cwd,
        profileId: profileId,
        providerSessionId: providerSessionId,
        model: modelOverride,
        effort: effortOverride,
        maxTurns: provider == 'claude' ? 5 : null,
        jsonSchema: structuredSchema,
        appendSystemPrompt: appendSystemPrompt,
      );
      providerSessionId = turnResult.providerSessionId.isEmpty ? providerSessionId : turnResult.providerSessionId;
      inputTokens += turnResult.inputTokens;
      outputTokens += turnResult.outputTokens;
      cacheReadTokens += turnResult.cacheReadTokens;
      cacheWriteTokens += turnResult.cacheWriteTokens;
      await _trackWorkflowSessionUsage(
        sessionId,
        provider: provider,
        inputTokens: turnResult.inputTokens,
        outputTokens: turnResult.outputTokens,
        cacheReadTokens: turnResult.cacheReadTokens,
        cacheWriteTokens: turnResult.cacheWriteTokens,
        totalCostUsd: turnResult.totalCostUsd,
      );
      structuredPayload = turnResult.structuredOutput;
      await _messages.insertMessage(
        sessionId: sessionId,
        role: 'assistant',
        content: structuredPayload != null ? jsonEncode(structuredPayload) : turnResult.responseText,
      );
    }

    final nextConfig = Map<String, dynamic>.from(task.configJson);
    if (providerSessionId != null && providerSessionId.isNotEmpty) {
      WorkflowTaskConfig.writeProviderSessionId(nextConfig, providerSessionId);
    }
    if (structuredPayload != null) {
      WorkflowTaskConfig.writeStructuredOutputPayload(nextConfig, structuredPayload);
    }
    await _tasks.updateFields(task.id, configJson: nextConfig);

    return TurnOutcome(
      turnId: 'workflow-oneshot-${task.id}',
      sessionId: sessionId,
      status: TurnStatus.completed,
      responseText: structuredPayload != null ? jsonEncode(structuredPayload) : null,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cacheReadTokens: cacheReadTokens,
      cacheWriteTokens: cacheWriteTokens,
      turnDuration: DateTime.now().difference(startedAt),
      completedAt: DateTime.now(),
    );
  }

  Future<void> _trackWorkflowSessionUsage(
    String sessionId, {
    required String provider,
    required int inputTokens,
    required int outputTokens,
    required int cacheReadTokens,
    required int cacheWriteTokens,
    required double? totalCostUsd,
  }) async {
    final kv = _kv;
    if (kv == null) return;

    final key = 'session_cost:$sessionId';
    final existing = await kv.get(key);
    final costData = existing != null
        ? jsonDecode(existing) as Map<String, dynamic>
        : <String, dynamic>{
            'input_tokens': 0,
            'output_tokens': 0,
            'cache_read_tokens': 0,
            'cache_write_tokens': 0,
            'total_tokens': 0,
            'estimated_cost_usd': 0.0,
            'turn_count': 0,
            'provider': provider,
          };
    costData['input_tokens'] = ((costData['input_tokens'] as num?)?.toInt() ?? 0) + inputTokens;
    costData['output_tokens'] = ((costData['output_tokens'] as num?)?.toInt() ?? 0) + outputTokens;
    costData['cache_read_tokens'] = ((costData['cache_read_tokens'] as num?)?.toInt() ?? 0) + cacheReadTokens;
    costData['cache_write_tokens'] = ((costData['cache_write_tokens'] as num?)?.toInt() ?? 0) + cacheWriteTokens;
    costData['total_tokens'] = ((costData['total_tokens'] as num?)?.toInt() ?? 0) + inputTokens + outputTokens;
    costData['estimated_cost_usd'] = (costData['estimated_cost_usd'] as num?)?.toDouble() ?? 0.0;
    costData['estimated_cost_usd'] = (costData['estimated_cost_usd'] as double) + (totalCostUsd ?? 0.0);
    costData['turn_count'] = ((costData['turn_count'] as num?)?.toInt() ?? 0) + 1;
    costData['provider'] = costData['provider'] ?? provider;
    await kv.set(key, jsonEncode(costData));
  }

  TurnRunner? _acquirePoolRunnerForTask(Task task, String profile) {
    final provider = task.provider;
    if (provider != null) {
      if (!_pool.hasTaskRunnerForProvider(provider)) {
        final provisioning = _isSpawning || _pool.spawnableCount > 0;
        _logRunnerWaitOnce(
          task,
          provisioning
              ? 'Task ${task.id} (${task.title}) is queued while provisioning a task runner for provider '
                    '"$provider". Available providers: ${_pool.taskProviders.join(', ')}'
              : 'Task ${task.id} (${task.title}) is queued but no task runner is configured for provider '
                    '"$provider". Available providers: ${_pool.taskProviders.join(', ')}',
          level: provisioning ? Level.INFO : Level.WARNING,
        );
        return null;
      }

      final exactMatch = _pool.tryAcquireForProviderAndProfile(provider, profile);
      if (exactMatch != null) {
        return exactMatch;
      }

      // When container isolation is disabled, the task pool only exposes the
      // workspace profile. Research tasks still resolve to the logical
      // restricted profile, so fall back to the workspace runner for the
      // selected provider instead of leaving the task queued forever.
      if (profile != 'workspace' && _pool.taskProfiles.length == 1 && _pool.taskProfiles.contains('workspace')) {
        final workspaceFallback = _pool.tryAcquireForProvider(provider);
        if (workspaceFallback != null) {
          if (_runnerWaitLoggedTaskIds.add(task.id)) {
            _log.info(
              'Task ${task.id} (${task.title}) requested profile "$profile" for provider "$provider", '
              'but only workspace task runners are available. Falling back to the workspace runner.',
            );
          }
          return workspaceFallback;
        }
      }

      _logRunnerWaitOnce(
        task,
        'Task ${task.id} (${task.title}) is queued waiting for an idle task runner for provider '
        '"$provider" in profile "$profile". Available profiles: ${_pool.taskProfiles.join(', ')}',
      );
      return null;
    }
    if (_pool.hasTaskRunnerForProfile(profile)) {
      return _pool.tryAcquireForProfile(profile);
    }
    if (_pool.taskProfiles.length <= 1) {
      return _pool.tryAcquire();
    }
    return null;
  }

  void _logRunnerWaitOnce(Task task, String message, {Level level = Level.WARNING}) {
    if (_runnerWaitLoggedTaskIds.add(task.id)) {
      _log.log(level, message);
    }
  }

  void _triggerSpawn() {
    final callback = _onSpawnNeeded;
    if (callback == null) return;
    _isSpawning = true;
    unawaited(
      callback().whenComplete(() {
        _isSpawning = false;
      }),
    );
  }

  Future<String?> _composePendingMessage(Task task, String sessionId, {String? workingDirectory}) async {
    final goalContext = await _goalContextFor(task);
    final pushBackComment = task.configJson['pushBackComment'];
    if (pushBackComment is String && pushBackComment.trim().isNotEmpty) {
      return _pushBackPrompt(pushBackComment.trim(), goalContext: goalContext, workingDirectory: workingDirectory);
    }

    return _initialPrompt(task, goalContext: goalContext, workingDirectory: workingDirectory);
  }

  String _initialPrompt(Task task, {String? goalContext, String? workingDirectory}) {
    final buffer = StringBuffer();

    // Inject retry context when this is a retry attempt.
    if (task.retryCount > 0) {
      final lastError = task.configJson['lastError'] as String?;
      buffer
        ..writeln('## Retry Context')
        ..writeln()
        ..writeln('Previous attempt failed: ${lastError ?? "unknown error"}')
        ..writeln('This is retry ${task.retryCount} of ${task.maxRetries}.')
        ..writeln('Approach the task differently — avoid the strategy that caused the previous failure.')
        ..writeln();
    }

    buffer
      ..writeln('## Task: ${task.title}')
      ..writeln()
      ..writeln(task.description.trim());

    if (workingDirectory != null && workingDirectory.trim().isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('### Working Directory')
        ..writeln('Use the reserved task worktree as the only workspace for this task.');
    }

    if (goalContext != null && goalContext.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(goalContext);
    }

    final acceptanceCriteria = task.acceptanceCriteria?.trim();
    if (acceptanceCriteria != null && acceptanceCriteria.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('### Acceptance Criteria')
        ..writeln(acceptanceCriteria);
    }

    return buffer.toString().trimRight();
  }

  Future<String?> _goalContextFor(Task task) async {
    final goalId = task.goalId;
    if (goalId == null || goalId.isEmpty) return null;
    return _goals?.resolveGoalContext(goalId);
  }

  String _pushBackPrompt(String comment, {String? goalContext, String? workingDirectory}) {
    final lines = <String>[
      '## Push-back Feedback',
      '',
      'The previous output was reviewed and pushed back with the following feedback:',
      '',
      comment,
    ];

    if (workingDirectory != null && workingDirectory.trim().isNotEmpty) {
      lines
        ..add('')
        ..add('### Working Directory')
        ..add('Continue using `$workingDirectory` as the only workspace for this task.');
    }

    if (goalContext != null && goalContext.isNotEmpty) {
      lines
        ..add('')
        ..add(goalContext);
    }

    lines
      ..add('')
      ..add('Please address the feedback and try again.');
    return lines.join('\n');
  }

  Map<String, dynamic>? _clearPushBackComment(Map<String, dynamic> configJson) {
    if (!configJson.containsKey('pushBackComment')) return null;
    final next = Map<String, dynamic>.from(configJson)..remove('pushBackComment');
    return next;
  }

  String? _workflowOwnedWorktreeKey(Task task) {
    final workflowRunId = task.workflowRunId;
    if (workflowRunId == null || workflowRunId.isEmpty) return null;
    final workflowGit = task.configJson['_workflowGit'];
    if (workflowGit is! Map) return null;
    final strategy = workflowGit['worktree'] as String?;
    if (strategy == 'shared') return workflowRunId;
    if (strategy == 'per-map-item') {
      final iterIndex = task.configJson['_mapIterationIndex'];
      if (iterIndex is int) return '$workflowRunId:map:$iterIndex';
      // Post-map serial coding steps must operate on the workflow-owned integration branch.
      return workflowRunId;
    }
    return null;
  }

  String? _workflowOwnedWorktreeTaskId(Task task) {
    final workflowRunId = task.workflowRunId;
    if (workflowRunId == null || workflowRunId.isEmpty) return null;
    final workflowGit = task.configJson['_workflowGit'];
    if (workflowGit is! Map) return null;
    final strategy = workflowGit['worktree'] as String?;
    if (strategy == 'shared') return 'wf-$workflowRunId';
    if (strategy == 'per-map-item') {
      final iterIndex = task.configJson['_mapIterationIndex'];
      if (iterIndex is int) return 'wf-$workflowRunId-map-$iterIndex';
      return 'wf-$workflowRunId';
    }
    return null;
  }

  bool _workflowMapIterationOwnsBranch(Task task) {
    final workflowGit = task.configJson['_workflowGit'];
    if (workflowGit is! Map) return false;
    if (workflowGit['worktree'] != 'per-map-item') return false;
    return task.configJson['_mapIterationIndex'] is int;
  }

  List<String>? _allowedTools(Task task) {
    final raw = task.configJson['allowedTools'];
    if (raw is! List) return null;
    try {
      return raw.cast<String>().toList(growable: false);
    } catch (e) {
      _log.warning('Task ${task.id}: malformed allowedTools in configJson, ignoring: $e');
      return null;
    }
  }

  bool _isReadOnlyTask(Task task) => task.configJson['readOnly'] == true;

  bool _skipAutoAcceptForWorkflowTask(Task task) =>
      task.workflowRunId != null && task.configJson['_workflowGit'] is Map;

  String? _reviewMode(Task task) {
    final raw = task.configJson['reviewMode'];
    if (raw is! String) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    if (!const {'auto-accept', 'mandatory', 'coding-only'}.contains(trimmed)) {
      _log.warning('Task ${task.id}: unknown reviewMode "$trimmed", using default');
      return null;
    }
    return trimmed;
  }

  TaskStatus _resolvePostCompletionStatus(Task task) {
    final mode = _reviewMode(task);
    return switch (mode) {
      'auto-accept' => TaskStatus.accepted,
      'mandatory' => TaskStatus.review,
      'coding-only' => _isCodingReviewStep(task) ? TaskStatus.review : TaskStatus.accepted,
      _ => TaskStatus.review, // null = current default (all tasks go to review)
    };
  }

  bool _isCodingReviewStep(Task task) {
    if (task.workflowRunId == null) {
      return task.type == TaskType.coding;
    }
    return task.configJson['_workflowStepType'] == 'coding';
  }

  String? _modelOverride(Task task) {
    final raw = task.configJson['model'];
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  String? _effortOverride(Task task) {
    final raw = task.configJson['effort'];
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  int? _tokenBudget(Task task) {
    // Prefer first-class maxTokens field over configJson entries.
    if (task.maxTokens != null && task.maxTokens! > 0) return task.maxTokens;
    final primary = task.configJson['tokenBudget'];
    if (primary != null) {
      if (primary is int && primary > 0) return primary;
      if (primary is num) {
        final intValue = primary.toInt();
        return intValue > 0 ? intValue : null;
      }
      return null;
    }
    final legacy = task.configJson['budget'];
    if (legacy != null) {
      _log.warning('Task ${task.id}: "budget" config key is deprecated — use "tokenBudget"');
      if (legacy is int && legacy > 0) return legacy;
      if (legacy is num) {
        final intValue = legacy.toInt();
        return intValue > 0 ? intValue : null;
      }
    }
    return null;
  }

  String? _taskBaseRef(Task task) {
    final raw = task.configJson['_baseRef'] ?? task.configJson['baseRef'];
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  Future<String?> _resolveEffectiveBaseRef(Task task, Project project, {String? explicitBaseRef}) async {
    if (explicitBaseRef != null && explicitBaseRef.isNotEmpty) {
      return explicitBaseRef;
    }
    if (project.id == '_local' && task.workflowRunId != null) {
      final head = await _currentSymbolicHead(project.localPath);
      if (head != null && head.isNotEmpty) {
        return head;
      }
    }
    return project.defaultBranch;
  }

  String? _freshnessRefFor(Project project, String? baseRef) {
    if (baseRef == null || baseRef.isEmpty) return null;
    if (project.id != '_local' && baseRef.startsWith('origin/')) {
      final trimmed = baseRef.substring('origin/'.length).trim();
      return trimmed.isEmpty ? null : trimmed;
    }
    return baseRef;
  }

  String? _worktreeBaseRefFor(Task task, Project project, String? baseRef) {
    if (baseRef == null || baseRef.isEmpty) return null;
    final workflowGit = task.configJson['_workflowGit'];
    if (workflowGit is Map) {
      // Workflow-owned branches are local refs; do not rewrite to origin/*.
      return baseRef;
    }
    if (project.id == '_local') return baseRef;
    if (baseRef.startsWith('origin/') || baseRef.startsWith('refs/')) {
      return baseRef;
    }
    return 'origin/$baseRef';
  }

  bool _isWorkflowOwnedLocalRef(String? ref) => ref != null && ref.startsWith('dartclaw/workflow/');

  String? _readOnlyCheckDir(Task task, Project project) {
    final worktreePath = task.worktreeJson?['path'];
    if (worktreePath is String && worktreePath.trim().isNotEmpty) {
      return worktreePath;
    }
    return project.localPath;
  }

  Future<Set<String>?> _captureReadOnlyProjectStatus(Task task, Project? project) async {
    if (!_isReadOnlyTask(task) || project == null) {
      return null;
    }
    final workingDirectory = _readOnlyCheckDir(task, project);
    if (workingDirectory == null || workingDirectory.isEmpty) {
      return null;
    }
    return _gitStatusEntries(workingDirectory, taskId: task.id);
  }

  Future<String?> _readOnlyMutationSummary(Task task, Project? project, Set<String>? baseline) async {
    if (!_isReadOnlyTask(task) || project == null || baseline == null) {
      return null;
    }
    final workingDirectory = _readOnlyCheckDir(task, project);
    if (workingDirectory == null || workingDirectory.isEmpty) {
      return null;
    }
    final after = await _gitStatusEntries(workingDirectory, taskId: task.id);
    if (after == null) {
      return null;
    }
    final addedEntries = after.difference(baseline).toList()..sort();
    if (addedEntries.isEmpty) {
      return null;
    }
    final preview = addedEntries.take(6).map(_statusEntryPath).join(', ');
    final remaining = addedEntries.length - 6;
    final suffix = remaining > 0 ? ' (+$remaining more)' : '';
    return 'Read-only task modified project files: $preview$suffix';
  }

  Future<Set<String>?> _gitStatusEntries(String workingDirectory, {required String taskId}) async {
    try {
      final result = await Process.run('git', const [
        'status',
        '--short',
        '--untracked-files=all',
      ], workingDirectory: workingDirectory);
      if (result.exitCode != 0) {
        _log.fine(
          'Task $taskId: skipping read-only mutation check for "$workingDirectory" '
          'because git status failed: ${result.stderr}',
        );
        return null;
      }
      final stdout = (result.stdout as String).trimRight();
      if (stdout.isEmpty) {
        return <String>{};
      }
      return stdout.split('\n').map((line) => line.trimRight()).where((line) => line.isNotEmpty).toSet();
    } catch (error) {
      _log.fine(
        'Task $taskId: skipping read-only mutation check for "$workingDirectory" because git status threw: $error',
      );
      return null;
    }
  }

  String _statusEntryPath(String entry) {
    final trimmed = entry.trimLeft();
    if (trimmed.length <= 3) {
      return trimmed;
    }
    return trimmed.substring(3).trim();
  }

  Future<String?> _currentSymbolicHead(String workingDirectory) async {
    try {
      final result = await Process.run('git', [
        'symbolic-ref',
        '--quiet',
        '--short',
        'HEAD',
      ], workingDirectory: workingDirectory);
      if (result.exitCode != 0) return null;
      final stdout = (result.stdout as String).trim();
      return stdout.isEmpty ? null : stdout;
    } catch (_) {
      return null;
    }
  }

  /// Pre-turn budget check. Returns verdict and optional warning message to inject.
  ///
  /// Fail-safe: any exception returns [_BudgetVerdict.proceed] (open policy).
  Future<(_BudgetVerdict, String?)> _checkBudget(Task task, String sessionId, {Goal? goal}) async {
    try {
      final effectiveBudget = _resolveTokenBudget(task, goal: goal);
      if (effectiveBudget == null) return (_BudgetVerdict.proceed, null);

      final costData = await _readSessionCost(sessionId);
      if (costData == null) return (_BudgetVerdict.proceed, null);

      final warningThreshold = _budgetConfig?.warningThreshold ?? 0.8;
      final totalTokens = costData.totalTokens;
      final ratio = totalTokens / effectiveBudget;

      if (ratio >= 1.0) {
        await _failBudgetExceeded(task, totalTokens, effectiveBudget, costData);
        return (_BudgetVerdict.exceeded, null);
      }

      if (ratio >= warningThreshold && !_budgetWarningFired(task)) {
        final warningMsg = _fireBudgetWarning(task, ratio, totalTokens, effectiveBudget);
        task = await _markBudgetWarningFired(task);
        return (_BudgetVerdict.proceed, warningMsg);
      }

      return (_BudgetVerdict.proceed, null);
    } catch (e, st) {
      _log.warning('Budget check failed for task ${task.id}, proceeding (fail-safe): $e', e, st);
      return (_BudgetVerdict.proceed, null);
    }
  }

  /// Resolves the effective token budget: task > legacy configJson > goal > global default.
  int? _resolveTokenBudget(Task task, {Goal? goal}) {
    if (task.maxTokens != null && task.maxTokens! > 0) return task.maxTokens;

    // Legacy configJson fallback for backward compatibility.
    final legacy = _legacyTokenBudgetFromConfig(task);
    if (legacy != null) return legacy;

    if (goal?.maxTokens != null && goal!.maxTokens! > 0) return goal.maxTokens;

    return _budgetConfig?.defaultMaxTokens;
  }

  int? _legacyTokenBudgetFromConfig(Task task) {
    final primary = task.configJson['tokenBudget'];
    if (primary is num && primary.toInt() > 0) return primary.toInt();
    final legacy = task.configJson['budget'];
    if (legacy is num && legacy.toInt() > 0) return legacy.toInt();
    return null;
  }

  Future<_SessionCostSnapshot?> _readSessionCost(String sessionId) async {
    final raw = await _kv?.get('session_cost:$sessionId');
    if (raw == null) return null;
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return _SessionCostSnapshot(
      totalTokens: (json['total_tokens'] as num?)?.toInt() ?? 0,
      turnCount: (json['turn_count'] as num?)?.toInt() ?? 0,
    );
  }

  bool _budgetWarningFired(Task task) => task.configJson['_tokenBudgetWarningFired'] == true;

  Future<Task> _markBudgetWarningFired(Task task) async {
    final next = Map<String, dynamic>.from(task.configJson)..['_tokenBudgetWarningFired'] = true;
    return _tasks.updateFields(task.id, configJson: next);
  }

  String _fireBudgetWarning(Task task, double ratio, int consumed, int limit) {
    final percent = (ratio * 100).toStringAsFixed(0);
    _eventBus?.fire(
      BudgetWarningEvent(
        taskId: task.id,
        consumedPercent: ratio,
        consumed: consumed,
        limit: limit,
        timestamp: DateTime.now(),
      ),
    );
    return 'You have used $percent% of your token budget ($consumed of $limit tokens). '
        'Wrap up your current work and provide a summary of progress.';
  }

  Future<void> _failBudgetExceeded(Task task, int consumed, int limit, _SessionCostSnapshot costData) async {
    final artifactContent = jsonEncode({
      'consumed': consumed,
      'limit': limit,
      'totalTokens': costData.totalTokens,
      'turnCount': costData.turnCount,
      'exceededAt': DateTime.now().toIso8601String(),
    });
    await _createBudgetArtifact(task, artifactContent);
    _log.warning('Task ${task.id} exceeded token budget ($limit < $consumed tokens); marking failed');
    await _markFailedOrRetry(
      task,
      errorSummary: 'Budget exceeded: used $consumed tokens against a limit of $limit tokens',
      retryable: false,
    );
  }

  Future<void> _createBudgetArtifact(Task task, String content) async {
    try {
      final dataDir = _dataDir;
      String artifactPath;
      if (dataDir != null) {
        // Write JSON to a real file so the API and web UI can read it via File(path).
        final artifactFile = File(p.join(dataDir, 'tasks', task.id, 'artifacts', 'budget-exceeded.json'));
        await artifactFile.parent.create(recursive: true);
        await artifactFile.writeAsString(content);
        artifactPath = artifactFile.path;
      } else {
        // No dataDir configured — fall back to inline content (content unreadable via API).
        artifactPath = content;
      }
      await _tasks.addArtifact(
        id: _uuid.v4(),
        taskId: task.id,
        name: 'budget-exceeded',
        kind: ArtifactKind.data,
        path: artifactPath,
      );
    } catch (e, st) {
      _log.warning('Failed to create budget artifact for task ${task.id}', e, st);
    }
  }

  Future<void> _markFailed(Task task, {String? errorSummary}) async {
    if (errorSummary != null) {
      _eventRecorder?.recordError(task.id, message: errorSummary);
    }
    try {
      final current = await _tasks.get(task.id);
      if (current == null || current.status.terminal) {
        return;
      }
      await _tasks.transition(
        task.id,
        TaskStatus.failed,
        configJson: errorSummary == null ? null : _withErrorSummary(current.configJson, errorSummary),
        trigger: 'system',
      );
    } on StateError catch (error, stackTrace) {
      _log.warning('Failed to mark task ${task.id} as failed: $error', error, stackTrace);
    }
  }

  /// Attempts to retry the task or marks it permanently failed.
  ///
  /// Retry conditions (all must hold):
  /// 1. [retryable] is true (budget exceeded and loop detected are not retryable)
  /// 2. task.maxRetries > 0 and task.retryCount < task.maxRetries
  /// 3. Error class differs from configJson['lastError'] (loop detection)
  ///
  /// On retry: stores lastError, increments retryCount, clears sessionId,
  /// transitions running → failed → queued.
  /// On no retry: delegates to [_markFailed].
  Future<void> _markFailedOrRetry(Task task, {required String errorSummary, bool retryable = true}) async {
    if (errorSummary.isNotEmpty) {
      _eventRecorder?.recordError(task.id, message: errorSummary);
    }
    try {
      final current = await _tasks.get(task.id);
      if (current == null || current.status.terminal) {
        return;
      }

      if (retryable && current.maxRetries > 0 && current.retryCount < current.maxRetries) {
        // Error class loop detection.
        final lastError = current.configJson['lastError'] as String?;
        if (lastError != null) {
          final currentClass = _extractErrorClass(errorSummary);
          final previousClass = _extractErrorClass(lastError);
          if (currentClass == previousClass) {
            _log.info(
              'Task ${task.id}: same error class on retry '
              '(${current.retryCount + 1}/${current.maxRetries}), '
              'failing permanently: "$currentClass"',
            );
            await _markFailed(task, errorSummary: errorSummary);
            return;
          }
        }

        // Proceed with retry.
        _log.info(
          'Task ${task.id}: retry ${current.retryCount + 1}/${current.maxRetries} '
          '(error: "${_truncate(errorSummary, 80)}")',
        );

        final retryConfigJson = Map<String, dynamic>.from(current.configJson)
          ..['lastError'] = _sanitizeErrorSummary(errorSummary);

        // Update retryCount and clear sessionId while task is still running
        // (before transitioning to terminal state — updateFields rejects terminal tasks).
        await _tasks.updateFields(
          task.id,
          retryCount: current.retryCount + 1,
          sessionId: null,
          configJson: retryConfigJson,
        );

        // Transition: running → failed (records the failure with lastError in configJson).
        await _tasks.transition(task.id, TaskStatus.failed, trigger: 'system');

        // Transition: failed → queued (retry path).
        await _tasks.transition(task.id, TaskStatus.queued, trigger: 'retry');
        return;
      }

      // No retry — permanent failure.
      await _markFailed(task, errorSummary: errorSummary);
    } on StateError catch (error, stackTrace) {
      _log.warning('Failed to process retry/failure for task ${task.id}: $error', error, stackTrace);
    }
  }

  /// Extracts the "error class" from an error summary for loop detection.
  ///
  /// Normalizes to lowercase, strips common exception prefixes, extracts the
  /// leading segment before the first `:` or `(`, and truncates to 80 chars.
  String _extractErrorClass(String errorSummary) {
    var normalized = errorSummary.toLowerCase().trim();
    for (final prefix in const [
      'exception: ',
      'stateerror: ',
      'bad state: ',
      'argumenterror: ',
      'invalid argument(s): ',
    ]) {
      if (normalized.startsWith(prefix)) {
        normalized = normalized.substring(prefix.length).trim();
        break;
      }
    }
    final classEnd = normalized.indexOf(RegExp(r'[:(\[]'));
    if (classEnd > 0) {
      normalized = normalized.substring(0, classEnd).trim();
    }
    if (normalized.length > 80) {
      normalized = normalized.substring(0, 80);
    }
    return normalized;
  }

  String _truncate(String s, int maxLength) => s.length <= maxLength ? s : '${s.substring(0, maxLength - 3)}...';

  Map<String, dynamic> _withErrorSummary(Map<String, dynamic> configJson, String errorSummary) =>
      Map<String, dynamic>.from(configJson)..['errorSummary'] = _sanitizeErrorSummary(errorSummary);

  String _defaultTurnFailureSummary(TurnStatus status) =>
      status == TurnStatus.cancelled ? 'Turn cancelled' : 'Turn execution failed';

  Future<void> _persistTrace(
    TurnTraceService traceService, {
    required TurnOutcome outcome,
    required String taskId,
    required int runnerId,
    String? model,
    String? provider,
  }) async {
    try {
      final endedAt = outcome.completedAt;
      final startedAt = endedAt.subtract(outcome.turnDuration);
      await traceService.insert(
        TurnTrace(
          id: _uuid.v4(),
          sessionId: outcome.sessionId,
          taskId: taskId,
          runnerId: runnerId,
          model: model,
          provider: provider,
          startedAt: startedAt,
          endedAt: endedAt,
          inputTokens: outcome.inputTokens,
          outputTokens: outcome.outputTokens,
          cacheReadTokens: outcome.cacheReadTokens,
          cacheWriteTokens: outcome.cacheWriteTokens,
          isError: outcome.status != TurnStatus.completed,
          errorType: outcome.status != TurnStatus.completed ? outcome.errorMessage : null,
          toolCalls: outcome.toolCalls,
        ),
      );
    } catch (e, st) {
      _log.warning('Failed to persist turn trace for task $taskId', e, st);
    }
  }

  String _sanitizeErrorSummary(String message) {
    final firstLine = message
        .split('\n')
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => 'Task execution failed');
    var normalized = firstLine;
    for (final prefix in const [
      'Exception: ',
      'StateError: ',
      'Bad state: ',
      'ArgumentError: ',
      'Invalid argument(s): ',
    ]) {
      if (normalized.startsWith(prefix)) {
        normalized = normalized.substring(prefix.length).trim();
        break;
      }
    }
    normalized = normalized.replaceFirst(RegExp(r'[.]+$'), '').trim();
    if (normalized.isEmpty) {
      normalized = 'Task execution failed';
    }
    if (normalized.length <= 200) {
      return normalized;
    }
    return '${normalized.substring(0, 197).trimRight()}...';
  }
}

enum _QueuedTaskDisposition { ready, waiting, handled }

enum _BudgetVerdict { proceed, exceeded }

class _SessionCostSnapshot {
  final int totalTokens;
  final int turnCount;

  const _SessionCostSnapshot({required this.totalTokens, required this.turnCount});
}
