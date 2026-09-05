import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkspaceSkillInventory, WorkspaceSkillLinker;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'project_wiring.dart';
import 'storage_wiring.dart';

/// Builds the auto-accept callback used by [TaskExecutor].
///
/// The callback is best-effort: non-success review results are converted into
/// thrown errors so [TaskExecutor] can log them and keep the task in `review`.
Future<void> Function(String taskId)? buildAutoAcceptCallback({
  required String completionAction,
  required Future<ReviewResult> Function(String taskId) reviewTask,
}) {
  if (completionAction != 'accept') {
    return null;
  }

  return (taskId) async {
    final result = await reviewTask(taskId);
    switch (result) {
      case ReviewSuccess():
        return;
      case ReviewMergeConflict(
        taskId: final conflictTaskId,
        taskTitle: final taskTitle,
        conflictingFiles: final conflictingFiles,
        details: final details,
      ):
        throw StateError(
          'Auto-accept failed for task $conflictTaskId ("$taskTitle"): merge conflict on ${conflictingFiles.join(', ')}. '
          '$details',
        );
      case ReviewNotFound(taskId: final missingTaskId):
        throw StateError('Auto-accept failed for task $taskId: no task found with ID $missingTaskId.');
      case ReviewInvalidTransition(taskId: final invalidTaskId, currentStatus: final currentStatus):
        throw StateError(
          'Auto-accept failed for task $taskId: task $invalidTaskId is not in review '
          '(current status: ${currentStatus.name}).',
        );
      case ReviewInvalidRequest(:final message):
        throw StateError('Auto-accept failed for task $taskId: $message');
      case ReviewActionFailed(:final message):
        throw StateError('Auto-accept failed for task $taskId: $message');
    }
  };
}

/// Constructs and exposes task-execution layer services.
///
/// Owns worktree manager, merge executor, task file guard, task review service,
/// diff generator, artifact collector, runner observer, and task executor.
///
/// Split into two phases:
/// - [wirePreServer]: builds services needed by [ChannelWiring] (review handler)
///   before server construction.
/// - [wirePostServer]: builds services that need a live [TurnManager] from the
///   constructed server.
class TaskWiring {
  new({
    required this.config,
    required String dataDir,
    required String runtimeCwd,
    String? localFallbackDir,
    RemotePushService? remotePushServiceOverride,
    required EventBus eventBus,
    required StorageWiring storage,
    ProjectWiring? project,
  }) : _dataDir = dataDir,
       _runtimeCwd = runtimeCwd,
       _localFallbackDir = localFallbackDir,
       _remotePushServiceOverride = remotePushServiceOverride,
       _eventBus = eventBus,
       _storage = storage,
       _project = project;

  final DartclawConfig config;
  final String _dataDir;

  /// The repository this composition operates on — the invocation cwd.
  final String _runtimeCwd;

  /// Non-null in the zero-server lane, which roots its worktrees beside the
  /// repository it was invoked in rather than in the managed workspace.
  final String? _localFallbackDir;

  final RemotePushService? _remotePushServiceOverride;
  final EventBus _eventBus;
  final StorageWiring _storage;
  final ProjectWiring? _project;

  static final _log = Logger('TaskWiring');

  late WorktreeManager _worktreeManager;
  late MergeExecutor _mergeExecutor;
  late TaskFileGuard _taskFileGuard;
  late TaskReviewService _taskReviewService;
  late RemotePushService _remotePushService;
  late PrCreator _prCreator;
  late DiffGenerator _diffGenerator;
  late ArtifactCollector _artifactCollector;
  late RunnerObserver _runnerObserver;
  late final WorkspaceSkillLinker _workspaceSkillLinker = WorkspaceSkillLinker();
  late TaskExecutor _taskExecutor;
  late ChannelReviewHandler _reviewHandler;
  bool _postServerWired = false;
  late TaskCancellationSubscriber _taskCancellationSubscriber;
  late ContainerTaskFailureSubscriber _containerTaskFailureSubscriber;
  late CompactionTaskEventSubscriber _compactionTaskEventSubscriber;
  Future<void>? _prepareShutdownFuture;

  WorktreeManager get worktreeManager => _worktreeManager;
  MergeExecutor get mergeExecutor => _mergeExecutor;
  TaskFileGuard get taskFileGuard => _taskFileGuard;
  TaskReviewService get taskReviewService => _taskReviewService;
  RemotePushService get remotePushService => _remotePushService;
  PrCreator get prCreator => _prCreator;
  DiffGenerator get diffGenerator => _diffGenerator;
  ArtifactCollector get artifactCollector => _artifactCollector;
  RunnerObserver get runnerObserver => _runnerObserver;
  TaskExecutor get taskExecutor => _taskExecutor;

  /// Whether [wirePostServer] ran — false for a lifecycle-only composition.
  bool get hasExecutionStack => _postServerWired;

  /// The channel review handler — available after [wirePreServer].
  ChannelReviewHandler get reviewHandler => _reviewHandler;

  /// Pre-wires services that do not need [TurnManager].
  ///
  /// Must be called before [ChannelWiring.wire] so the [reviewHandler] is
  /// available to Google Chat card handling.
  Future<void> wirePreServer() async {
    _mergeExecutor = MergeExecutor(
      projectDir: _runtimeCwd,
      defaultStrategy: config.tasks.worktreeMergeStrategy == 'merge' ? MergeStrategy.merge : MergeStrategy.squash,
    );
    _taskFileGuard = TaskFileGuard();
    _worktreeManager = WorktreeManager(
      dataDir: _dataDir,
      projectDir: _runtimeCwd,
      baseRef: config.tasks.worktreeBaseRef,
      staleTimeoutHours: config.tasks.worktreeStaleTimeoutHours,
      // Worktrees are checkouts of the repository the lane operates on. The
      // zero-server lane operates on the invocation cwd, so they must live
      // beside it even when `--config` points the data dir elsewhere.
      worktreesDir: p.join(_localFallbackDir ?? config.workspaceDir, '.dartclaw', 'worktrees'),
      taskLookup: _storage.taskService.get,
      projectLookup: _project?.projectService.get,
      skillMaterializer: _materializeWorkflowSkillsForWorktree,
    );
    await _worktreeManager.detectStaleWorktrees();

    _remotePushService =
        _remotePushServiceOverride ?? RemotePushService(credentials: config.credentials, dataDir: _dataDir);
    _prCreator = PrCreator(credentials: config.credentials);

    _taskReviewService = _buildTaskReviewService();
    _reviewHandler = _taskReviewService.channelReviewHandler(trigger: 'channel');
  }

  Future<void> _materializeWorkflowSkillsForWorktree(String worktreePath) async {
    final inventory = WorkspaceSkillInventory.fromDataDir(_dataDir);
    _workspaceSkillLinker.materialize(
      dataDir: _dataDir,
      workspaceDir: worktreePath,
      skillNames: inventory.skillNames,
      agentMdNames: inventory.agentMdNames,
      agentTomlNames: inventory.agentTomlNames,
    );
  }

  /// Wires task services that require a live [TurnManager].
  ///
  /// Must be called after server construction. [turns] comes from the
  /// newly-built server, [executions] from [HarnessWiring].
  Future<void> wirePostServer({
    required TurnManager turns,
    required ExecutionCoordinator executions,
    required ExecutionPolicyResolver policyResolver,
  }) async {
    _diffGenerator = DiffGenerator(projectDir: _runtimeCwd);
    _artifactCollector = ArtifactCollector(
      tasks: _storage.taskService,
      sessionsDir: config.sessionsDir,
      dataDir: _dataDir,
      diffGenerator: _diffGenerator,
      projectService: _project?.projectService,
      baseRef: config.tasks.worktreeBaseRef,
    );

    _containerTaskFailureSubscriber = ContainerTaskFailureSubscriber(tasks: _storage.taskService);
    _containerTaskFailureSubscriber.subscribe(_eventBus);

    _taskCancellationSubscriber = TaskCancellationSubscriber(tasks: _storage.taskService, turns: turns);
    _taskCancellationSubscriber.subscribe(_eventBus);

    _compactionTaskEventSubscriber = CompactionTaskEventSubscriber(
      tasks: _storage.taskService,
      eventRecorder: _storage.taskEventRecorder,
    );
    _compactionTaskEventSubscriber.subscribe(_eventBus);

    _runnerObserver = RunnerObserver(executions: executions, eventBus: _eventBus);
    _taskExecutor = TaskExecutor(
      services: TaskExecutorServices(
        tasks: _storage.taskService,
        goals: _storage.goalService,
        sessions: _storage.sessions,
        messages: _storage.messages,
        artifactCollector: _artifactCollector,
        worktreeManager: _worktreeManager,
        taskFileGuard: _taskFileGuard,
        eventRecorder: _storage.taskEventRecorder,
        workflowStepExecutionRepository: _storage.workflowStepExecutionRepository,
        workflowRunRepository: _storage.workflowRunRepository,
        projectService: _project?.projectService,
        kvService: _storage.kvService,
        eventBus: _eventBus,
        policyResolver: policyResolver,
      ),
      runners: TaskExecutorRunners(turns: turns),
      limits: TaskExecutorLimits(
        maxMemoryBytes: config.memory.maxBytes,
        compactInstructions: config.context.compactInstructions,
        identifierPreservation: config.context.identifierPreservation,
        identifierInstructions: config.context.identifierInstructions,
        budgetConfig: config.tasks.budget,
        defaultProviderId: config.agent.provider,
      ),
      onAutoAccept: buildAutoAcceptCallback(
        completionAction: config.tasks.completionAction,
        reviewTask: (taskId) => _taskReviewService.review(taskId, 'accept', trigger: 'auto_accept'),
      ),
      workspaceRoot: config.workspaceDir,
      currentDirectory: _runtimeCwd,
      dataDir: _dataDir,
    );
    _postServerWired = true;
    _log.fine('TaskExecutor wired');
  }

  /// Injects a push-back feedback delivery callback into [TaskReviewService].
  ///
  /// Rebuilds the review service and the [reviewHandler] with it. This must run
  /// before `ChannelWiring.wire` captures the handler for Google Chat cards and
  /// before MCP registration reads [taskReviewService].
  void setPushBackFeedbackDelivery(PushBackFeedbackDelivery? delivery) {
    _taskReviewService = _buildTaskReviewService(pushBackFeedbackDelivery: delivery);
    _reviewHandler = _taskReviewService.channelReviewHandler(trigger: 'channel');
    _log.fine('TaskReviewService updated with push-back feedback delivery');
  }

  TaskReviewService _buildTaskReviewService({PushBackFeedbackDelivery? pushBackFeedbackDelivery}) {
    return TaskReviewService(
      tasks: _storage.taskService,
      worktreeManager: _worktreeManager,
      taskFileGuard: _taskFileGuard,
      mergeExecutor: _mergeExecutor,
      remotePushService: _remotePushService,
      prCreator: _prCreator,
      projectService: _project?.projectService,
      dataDir: _dataDir,
      mergeStrategy: config.tasks.worktreeMergeStrategy,
      baseRef: config.tasks.worktreeBaseRef,
      pushBackFeedbackDelivery: pushBackFeedbackDelivery,
      eventRecorder: _storage.taskEventRecorder,
    );
  }

  /// No-ops when [wirePostServer] never ran — a lifecycle-only composition has
  /// no executor to stop.
  Future<void> prepareExecutionShutdown() => _prepareShutdownFuture ??= Future(() async {
    if (!_postServerWired) return;
    _taskExecutor.stopPolling();
    await _taskExecutor.cancelActive();
  });

  Future<void> drainExecutions() async {
    if (!_postServerWired) return;
    await _taskExecutor.drain();
  }

  Future<void> dispose() async {
    await prepareExecutionShutdown();
    await drainExecutions();
    if (_postServerWired) {
      await _runnerObserver.dispose();
      await _taskCancellationSubscriber.dispose();
      await _containerTaskFailureSubscriber.dispose();
      await _compactionTaskEventSubscriber.dispose();
    }
    _remotePushService.dispose();
  }
}
