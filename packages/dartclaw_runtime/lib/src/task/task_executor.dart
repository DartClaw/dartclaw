import 'dart:async';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show WorkflowRunRepository, WorkflowStepExecutionRepository, WorkflowWorktreeBinding;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../behavior/behavior_file_service.dart';
import '../execution_coordinator.dart';
import '../execution_policy_resolver.dart';
import '../governance/budget_engine.dart';
import '../turn_runner.dart' show TurnRunner;
import 'artifact_collector.dart';
import 'goal_service.dart';
import 'task_budget_policy.dart';
import 'task_config_view.dart';
import 'task_event_recorder.dart';
import 'task_executor_limits.dart';
import 'task_executor_runners.dart';
import 'task_executor_services.dart';
import 'task_file_guard.dart';
import 'task_project_ref.dart';
import 'task_read_only_guard.dart';
import 'task_service.dart';
import 'workflow_one_shot_runner.dart';
import 'workflow_worktree_binder.dart';
import 'worktree_manager.dart';

part 'task_executor_helpers.dart';

/// Executes queued tasks through the shared execution authority.
class TaskExecutor {
  new({
    required TaskExecutorServices services,
    required TaskExecutorRunners runners,
    TaskExecutorLimits limits = const TaskExecutorLimits(),
    Future<void> Function(String taskId)? onAutoAccept,
    String? workspaceRoot,
    String? currentDirectory,
    String? dataDir,
    this.pollInterval = const Duration(seconds: 2),
  }) : _tasks = services.tasks,
       _goals = services.goals,
       _sessions = services.sessions,
       _messages = services.messages,
       _executions = runners.turns.executions,
       _artifactCollector = services.artifactCollector,
       _worktreeManager = services.worktreeManager,
       _taskFileGuard = services.taskFileGuard,
       _traceService = services.traceService,
       _eventRecorder = services.eventRecorder,
       _workflowStepExecutionRepository = services.workflowStepExecutionRepository,
       _workflowRunRepository = services.workflowRunRepository,
       _onAutoAccept = onAutoAccept,
       _projectService = services.projectService,
       _workspaceRoot = workspaceRoot,
       _currentDirectory = currentDirectory ?? Directory.current.path,
       _maxMemoryBytes = limits.maxMemoryBytes,
       _compactInstructions = limits.compactInstructions,
       _identifierPreservation = limits.identifierPreservation,
       _identifierInstructions = limits.identifierInstructions,
       _kv = services.kvService,
       _policyResolver = services.policyResolver,
       _budgetConfig = limits.budgetConfig,
       _defaultProviderId = limits.defaultProviderId,
       _eventBus = services.eventBus,
       _dataDir = dataDir;

  static final _log = Logger('TaskExecutor');
  static const _uuid = Uuid();

  final TaskService _tasks;
  final GoalService? _goals;
  final SessionService _sessions;
  final MessageService _messages;
  final ExecutionCoordinator _executions;
  final ExecutionPolicyResolver? _policyResolver;
  final ArtifactCollector _artifactCollector;
  final WorktreeManager? _worktreeManager;
  final TaskFileGuard? _taskFileGuard;
  final TurnTraceService? _traceService;
  final TaskEventRecorder? _eventRecorder;
  final WorkflowStepExecutionRepository? _workflowStepExecutionRepository;
  final WorkflowRunRepository? _workflowRunRepository;
  final Future<void> Function(String taskId)? _onAutoAccept;
  final ProjectService? _projectService;
  final String? _workspaceRoot;
  final String _currentDirectory;
  final int? _maxMemoryBytes;
  final String? _compactInstructions;
  final IdentifierPreservationMode _identifierPreservation;
  final String? _identifierInstructions;
  final KvService? _kv;
  final TaskBudgetConfig? _budgetConfig;
  final String? _defaultProviderId;
  final EventBus? _eventBus;
  final String? _dataDir;
  final Duration pollInterval;
  late final TaskFailureHandler _failureHandler = TaskFailureHandler(
    tasks: _tasks,
    eventRecorder: _eventRecorder,
    log: _log,
  );
  late final ExecutionPolicyResolver _taskPolicyResolver =
      _policyResolver ?? ExecutionPolicyResolver.forStandalonePolicy(_executions.primary?.executionPolicy);
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
    workflowStepExecutionRepository: _workflowStepExecutionRepository,
    messages: _messages,
    budgetPolicy: _budgetPolicy,
    tasks: _tasks,
    eventRecorder: _eventRecorder,
    eventBus: _eventBus,
    log: _log,
  );

  Timer? _timer;
  Future<bool>? _inFlightPoll;
  final Set<Future<void>> _activeExecutionTasks = <Future<void>>{};
  final Map<String, ({TurnRunner runner, String sessionId})> _activeTaskTurns = {};
  final Set<String> _providerUnavailableTaskIds = <String>{};

  void hydrateWorkflowSharedWorktreeBinding(WorkflowWorktreeBinding binding) {
    _worktreeBinder.hydrate(binding);
  }

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(pollInterval, (_) {
      unawaited(pollOnce());
    });
    unawaited(pollOnce());
  }

  Future<void> stop() async {
    stopPolling();
    await cancelActive();
    await drain();
  }

  Future<void> cancelActive() async {
    await _inFlightPoll;
    final activeTasks = Map<String, ({TurnRunner runner, String sessionId})>.of(_activeTaskTurns);
    await Future.wait(
      activeTasks.entries.map((entry) async {
        try {
          var task = await _tasks.get(entry.key);
          while (task?.status == TaskStatus.running) {
            try {
              await _tasks.transition(task!.id, TaskStatus.cancelled, trigger: 'system');
              break;
            } on Object catch (error) {
              if (error is! StateError && error is! VersionConflictException) rethrow;
              task = await _tasks.get(entry.key);
            }
          }
        } finally {
          await entry.value.runner.cancelTurn(entry.value.sessionId);
        }
      }),
      eagerError: false,
    );
  }

  void stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> drain() async {
    await _inFlightPoll;
    while (_activeExecutionTasks.isNotEmpty) {
      await Future.wait(List<Future<void>>.from(_activeExecutionTasks), eagerError: false);
    }
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

  Future<void> _failForProject(Task task, String projectId) => _failureHandler.markFailedOrRetry(
    task,
    errorSummary: 'Project "$projectId" not found',
    kind: TaskFailureReason.projectSetup,
    retryable: false,
  );

  void _recordProviderUnavailable(Task task, String message) {
    _eventRecorder?.recordError(task.id, message: message);
  }

  Future<bool> _pollOnceInner() async {
    final queued = await _queuedTasks();
    if (queued.isEmpty) return false;
    var didWork = false;
    final unavailableWorkerProfiles = <String>{};
    for (final task in queued) {
      if (task.legacyRefusal == TaskLegacyRefusal.securityProfileUndeclared) {
        await _failureHandler.markFailedOrRetry(
          task,
          errorSummary: retiredResearchTaskTypeMessage,
          kind: TaskExecutionFailure(const RetiredTaskTypeException()),
          retryable: false,
        );
        didWork = true;
        continue;
      }
      if (task.legacyRefusal == TaskLegacyRefusal.worktreeUndeclared) {
        await _failureHandler.markFailedOrRetry(
          task,
          errorSummary: retiredCodingWorktreeMessage,
          kind: TaskExecutionFailure(const MissingWorktreeDeclarationException()),
          retryable: false,
        );
        didWork = true;
        continue;
      }

      final disposition = await _prepareQueuedTask(task);
      if (disposition == _QueuedTaskDisposition.waiting) {
        continue;
      }
      if (disposition == _QueuedTaskDisposition.handled) {
        didWork = true;
        continue;
      }

      final hydratedTask = await _hydrateWorkflowStepExecution(task);
      final preparedTask = await _prepareExecutionSession(hydratedTask);
      if (preparedTask == null) {
        didWork = true;
        continue;
      }
      final provider = _effectiveProviderForTask(preparedTask);
      if (provider == null) {
        if (_providerUnavailableTaskIds.add(preparedTask.id)) {
          _recordProviderUnavailable(preparedTask, 'Task has no configured execution provider');
        }
        continue;
      }
      // A step declaring a schema is *not* refused on a provider that cannot
      // enforce one. The structure is host-enforced on this path: the finalizer
      // prompt asks for the envelope and `WorkflowOneShotRunner` validates the
      // payload with `SchemaValidator`. `StepTurnRunner` withholds the schema
      // from such a harness so nothing claims provider enforcement it lacks.
      final ExecutionPolicy policy;
      try {
        policy = _executionPolicyForTask(preparedTask);
      } on ExecutionPolicyException catch (error) {
        await _failureHandler.markFailedOrRetry(
          preparedTask,
          errorSummary: error.message,
          kind: TaskExecutionFailure(error),
          retryable: false,
        );
        didWork = true;
        continue;
      }
      final workerProfileKey = '$provider\u0000${policy.describe()}';
      if (unavailableWorkerProfiles.contains(workerProfileKey)) {
        continue;
      }
      final isWorkflow = _isWorkflowOrchestrated(preparedTask);
      final workflowInputs = isWorkflow ? WorkflowOneShotRunner.constructionInputs(preparedTask) : null;
      ExecutionLease? lease;
      try {
        if (isWorkflow) WorkflowOneShotRunner.createArtifactsDirectory(preparedTask);
        lease = await _executions.acquire(
          ExecutionRequest(
            surface: isWorkflow ? ExecutionSurface.workflow : ExecutionSurface.task,
            providerId: provider,
            policy: policy,
            sessionId: preparedTask.sessionId!,
            admission: ExecutionAdmission.failFast,
            taskId: preparedTask.id,
            allowedTools: _allowedTools(preparedTask),
            artifactsDir: workflowInputs?.artifactsDir,
            spawnEnvironment: workflowInputs?.spawnEnvironment,
          ),
        );
      } on StateError catch (error) {
        unavailableWorkerProfiles.add(workerProfileKey);
        if (_providerUnavailableTaskIds.add(preparedTask.id)) {
          _recordProviderUnavailable(preparedTask, error.message);
        }
        continue;
      } on FileSystemException catch (error) {
        if (_providerUnavailableTaskIds.add(preparedTask.id)) {
          _recordProviderUnavailable(preparedTask, error.toString());
        }
        continue;
      } on WorkerCreationException catch (error) {
        unavailableWorkerProfiles.add(workerProfileKey);
        if (_providerUnavailableTaskIds.add(preparedTask.id)) {
          _recordProviderUnavailable(preparedTask, error.message);
        }
        continue;
      }
      if (lease == null) continue;
      _providerUnavailableTaskIds.remove(preparedTask.id);
      final runningTask = await _checkout(preparedTask);
      if (runningTask == null) {
        await lease.release();
        continue;
      }
      didWork = true;
      _trackExecutionTask(_runLeasedTask(runningTask, lease));
    }
    return didWork;
  }

  Future<List<Task>> _queuedTasks() async {
    final queued = await _tasks.list(status: TaskStatus.queued);
    queued.sort((a, b) {
      final createdAtCompare = a.createdAt.compareTo(b.createdAt);
      if (createdAtCompare != 0) return createdAtCompare;
      return a.id.compareTo(b.id);
    });
    return queued;
  }

  String? _effectiveProviderForTask(Task task) {
    final provider = task.provider;
    if (provider != null) {
      if (provider.trim().isEmpty) return null;
      return ProviderIdentity.normalize(provider);
    }
    final defaultProvider = _defaultProviderId;
    if (defaultProvider != null && defaultProvider.trim().isNotEmpty) {
      return ProviderIdentity.normalize(defaultProvider);
    }
    return _executions.primary?.providerId;
  }

  /// The effective policy for background work carrying no logical-agent
  /// identity, honoring an operator-declared task profile.
  ///
  ExecutionPolicy _executionPolicyForTask(Task task) {
    final securityProfile = TaskConfigView(task).securityProfile;
    return _taskPolicyResolver.resolveForTask(securityProfile: securityProfile);
  }

  /// Shared task execution logic for coordinated and single-harness paths.
  Future<void> _executeCore(
    Task runningTask, {
    required TurnRunner runner,
    required int runnerIndex,
    String? provider,
    ExecutionPolicy? runnerPolicy,
    required Future<String> Function(
      String sessionId, {
      String? directory,
      String? model,
      String? effort,
      String? taskId,
      BehaviorFileService? behaviorOverride,
      required List<String>? allowedTools,
      required bool readOnly,
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
    Future<void> Function(String sessionId, String turnId)? waitForExecutionSettled,
  }) async {
    var task = runningTask;
    _log.info(
      'Task execution start: ${task.id} "${task.title}" '
      'provider=${provider ?? "default"}, '
      'execution=${runnerPolicy?.describe() ?? "unresolved"}',
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
            await _failForProject(task, projectId);
            return;
          }
          if (project.status == ProjectStatus.error) {
            await _failureHandler.markFailedOrRetry(
              task,
              errorSummary: project.errorMessage?.trim().isNotEmpty == true
                  ? 'Project "${project.name}" failed to clone: ${project.errorMessage!.trim()}'
                  : 'Project "${project.name}" failed to clone',
              kind: TaskFailureReason.projectSetup,
              retryable: false,
            );
            return;
          }
          if (project.status == ProjectStatus.cloning) {
            await _failureHandler.markFailedOrRetry(
              task,
              errorSummary: 'Project "${project.name}" is still cloning',
              kind: TaskFailureReason.projectSetup,
              retryable: false,
            );
            return;
          }
        } else if (!_isWorkflowOrchestrated(task)) {
          project = await projectService.defaultProject;
        }
        if (project != null) {
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
                kind: TaskFailureReason.projectSetup,
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
      }

      final usesInlineWorkflowCheckout = await _worktreeBinder.usesInlineProjectCheckout(task);
      if (_taskNeedsWorktree(task) && usesInlineWorkflowCheckout && project != null) {
        final inlineBaseRef = _taskBaseRef(task);
        if (inlineBaseRef != null && inlineBaseRef.isNotEmpty) {
          final prepared = await _worktreeBinder.ensureInlineWorkflowBranchCheckedOut(task, project, inlineBaseRef);
          if (!prepared) {
            return;
          }
          task = await _tasks.updateFields(task.id, worktreeJson: {'path': project.localPath, 'branch': inlineBaseRef});
        }
      }

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
      }

      final executionDirectory = taskExecutionDirectory(
        task,
        standaloneDirectory: _currentDirectory,
        worktreePath: worktreeInfo?.path,
        project: project,
      );
      final requiredInputPath = TaskConfigView(task, log: _log).requiredInputPath;
      if (requiredInputPath != null) {
        final exists = File(p.join(executionDirectory, requiredInputPath)).existsSync();
        if (!exists) {
          await _failureHandler.markFailedOrRetry(
            task,
            errorSummary:
                'artifact-propagation: required input path "$requiredInputPath" is missing in "$executionDirectory"',
            kind: TaskFailureReason.missingArtifactInput,
            retryable: false,
          );
          return;
        }
      }

      readOnlyProjectStatusBeforeTurn = await _captureReadOnlyProjectStatus(task, executionDirectory);

      final sessionId = task.sessionId;
      final session = sessionId == null ? null : await _sessions.getSession(sessionId);
      if (session == null || session.type == SessionType.archive) {
        await _failureHandler.markFailedOrRetry(
          task,
          errorSummary: 'Task execution session "$sessionId" not found or archived',
          kind: TaskFailureReason.sessionMissing,
          retryable: false,
        );
        return;
      }

      // Pre-turn budget check – fail-safe open policy.
      final goalForBudget = task.goalId != null ? await _goals?.get(task.goalId!) : null;
      final (budgetOutcome, budgetWarningMessage) = await _budgetPolicy.checkBudget(
        task,
        session.id,
        goal: goalForBudget,
      );
      if (budgetOutcome == BudgetOutcome.exceeded) return;

      final pendingMessage = await _composePendingMessage(task, session.id, workingDirectory: executionDirectory);
      if (pendingMessage == null) {
        _log.warning('Task ${task.id} had no message to execute; marking failed');
        await _failureHandler.markFailedOrRetry(
          task,
          errorSummary: 'Task had no executable prompt',
          kind: TaskFailureReason.absentPrompt,
          retryable: false,
        );
        return;
      }
      final modelOverride = _modelOverride(task);
      final effortOverride = _effortOverride(task);
      final tokenBudget = _tokenBudget(task);
      final projectDirForTask = taskProjectId(task) != null ? project?.localPath : null;

      if (budgetWarningMessage != null) {
        await _messages.insertMessage(sessionId: session.id, role: 'system', content: budgetWarningMessage);
      }

      if (_isWorkflowOrchestrated(task)) {
        final workflowProvider = task.provider ?? _defaultProviderId;
        if (workflowProvider == null || workflowProvider.trim().isEmpty) {
          throw StateError('Workflow one-shot task ${task.id} has no provider and no configured default provider');
        }
        final TurnOutcome outcome;
        try {
          outcome = await _workflowOneShotRunner.execute(
            task,
            runner: runner,
            sessionId: session.id,
            pendingMessage: pendingMessage,
            provider: workflowProvider,
            workingDirectory: executionDirectory,
            modelOverride: modelOverride,
            effortOverride: effortOverride,
            allowedTools: _allowedTools(task),
            readOnly: _isReadOnlyTask(task),
          );
        } on StateError catch (error, stackTrace) {
          // A workflow turn failure must win even when dispose
          // already raced this task to cancelled. Scope the cancelled->failed
          // correction to this workflow surface so generic cancellation (below,
          // and the shared catch) never rewrites an intentional cancel.
          _log.warning('Workflow one-shot failed for task ${task.id}: $error', error, stackTrace);
          await _failureHandler.markFailedOrRetry(
            task,
            errorSummary: _failureHandler.sanitizeErrorSummary(error.toString()),
            kind: TaskExecutionFailure(error),
            correctCancelled: true,
          );
          return;
        }
        if (outcome.status == TurnStatus.cancelled) {
          final limitBreach = outcome.limitBreach;
          if (limitBreach != null) {
            await _failureHandler.markFailedOrRetry(
              task,
              errorSummary: outcome.errorMessage ?? 'Workflow one-shot turn breached ${limitBreach.jsonName}',
              kind: TaskLimitFailure.fromBreach(limitBreach),
              correctCancelled: true,
            );
            return;
          }
          final current = await _tasks.get(task.id);
          if (current?.status == TaskStatus.cancelled) return;
          if (current != null && !current.status.terminal) {
            await _tasks.transition(task.id, TaskStatus.cancelled, trigger: 'system');
          }
          return;
        }
        if (outcome.status != TurnStatus.completed) {
          // A genuine provider failure must win even when dispose already raced
          // this one-shot task to cancelled; scope the correction here only.
          await _failureHandler.markFailedOrRetry(
            task,
            errorSummary: outcome.errorMessage ?? 'Workflow one-shot execution failed',
            kind: TaskFailureReason.workflowOneShot,
            correctCancelled: true,
          );
          return;
        }
        if ((await _tasks.get(task.id))?.status == TaskStatus.cancelled) return;
        final refreshedTask = await _tasks.get(task.id) ?? task;
        final readOnlyMutationSummary = await _readOnlyMutationSummary(
          refreshedTask,
          executionDirectory,
          readOnlyProjectStatusBeforeTurn,
        );
        if (readOnlyMutationSummary != null) {
          _log.warning('Task ${task.id}: $readOnlyMutationSummary');
          await _failureHandler.markFailedOrRetry(
            task,
            errorSummary: readOnlyMutationSummary,
            kind: TaskFailureReason.readOnlyMutation,
            retryable: false,
          );
          return;
        }
        final artifacts = await _artifactCollector.collect(refreshedTask, executionDirectory: executionDirectory);
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

      final turnDirectory = executionDirectory;

      // Create task-scoped BehaviorFileService for workflow tasks first.
      final workflowWorkspaceDir = _worktreeBinder.workflowWorkspaceDir(task);
      final workspaceRoot = _workspaceRoot;
      final workflowWorkspace = workflowWorkspaceDir?.trim();
      final taskWorkspaceDir = workflowWorkspace != null && workflowWorkspace.isNotEmpty
          ? workflowWorkspaceDir
          : projectDirForTask != null
          ? workspaceRoot
          : null;
      final taskBehavior = taskWorkspaceDir == null
          ? null
          : BehaviorFileService(
              workspaceDir: taskWorkspaceDir,
              projectDir: projectDirForTask,
              maxMemoryBytes: _maxMemoryBytes,
              compactInstructions: _compactInstructions,
              identifierPreservation: _identifierPreservation,
              identifierInstructions: _identifierInstructions,
            );

      // Determine prompt scope for this task turn.
      // Restricted profile gets tools-only; all other tasks get the lean task
      // scope (no user/memory noise).
      final PromptScope promptScope;
      if (workflowWorkspaceDir != null && workflowWorkspaceDir.trim().isNotEmpty) {
        promptScope = PromptScope.task;
      } else if (runnerPolicy?.containerProfile == 'restricted') {
        promptScope = PromptScope.restricted;
      } else {
        promptScope = PromptScope.task;
      }

      final turnId = await reserveTurn(
        session.id,
        directory: turnDirectory,
        model: modelOverride,
        effort: effortOverride,
        taskId: task.id,
        behaviorOverride: taskBehavior,
        allowedTools: _allowedTools(task),
        readOnly: _isReadOnlyTask(task),
        promptScope: promptScope,
      );
      executeTurn(session.id, turnId, turnMessages, source: 'task', agentName: 'task');
      final outcome = await waitForOutcome(session.id, turnId);
      await waitForExecutionSettled?.call(session.id, turnId);
      // Record synchronous token update + tool call events for durability.
      // Must execute before the fire-and-forget trace write.
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
        final readOnlyMutationSummary = await _readOnlyMutationSummary(
          task,
          executionDirectory,
          readOnlyProjectStatusBeforeTurn,
        );
        if (readOnlyMutationSummary != null) {
          _log.warning('Task ${task.id}: $readOnlyMutationSummary');
          await _failureHandler.markFailedOrRetry(
            task,
            errorSummary: readOnlyMutationSummary,
            kind: TaskFailureReason.readOnlyMutation,
            retryable: false,
          );
          return;
        }
        final refreshed = await _tasks.get(task.id) ?? task;
        if (refreshed.status == TaskStatus.cancelled) {
          return;
        }
        final artifacts = await _artifactCollector.collect(refreshed, executionDirectory: executionDirectory);
        for (final artifact in artifacts) {
          _eventRecorder?.recordArtifactCreated(task.id, name: artifact.name, kind: artifact.kind.name);
        }
        if (tokenBudget != null && outcome.totalTokens > tokenBudget) {
          _log.warning('Task ${task.id} exceeded token budget ($tokenBudget < ${outcome.totalTokens}); marking failed');
          await _failureHandler.markFailedOrRetry(
            task,
            errorSummary: 'Token budget exceeded: used ${outcome.totalTokens} tokens against a limit of $tokenBudget',
            kind: TaskFailureReason.budgetExceeded,
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
                kind: TaskExecutionFailure(error),
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
          kind: TaskFailureReason.loopDetected,
          retryable: false,
        );
        return;
      }

      await _failureHandler.markFailedOrRetry(
        task,
        errorSummary: outcome.errorMessage ?? _defaultTurnFailureSummary(outcome.status),
        kind: TaskFailureReason.turnFailure,
      );
      return;
    } on LoopDetectedException catch (e) {
      // Pre-turn loop detection (turn chain depth or token velocity).
      _log.warning('Loop detected during task ${task.id}: ${e.message}');
      await _failureHandler.markFailedOrRetry(
        task,
        errorSummary: 'Loop detected: ${e.message}',
        kind: TaskFailureReason.loopDetected,
        retryable: false,
      );
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
        kind: TaskExecutionFailure(error),
      );
      return;
    }
  }
}

enum _QueuedTaskDisposition { ready, waiting, handled }
