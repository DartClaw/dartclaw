import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
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
/// diff generator, artifact collector, agent observer, and task executor.
///
/// Split into two phases:
/// - [wirePreServer]: builds services needed by [ChannelWiring] (review handler)
///   before server construction.
/// - [wirePostServer]: builds services that need a live [TurnManager] from the
///   constructed server.
class TaskWiring {
  TaskWiring({
    required this.config,
    required String dataDir,
    required EventBus eventBus,
    required StorageWiring storage,
    ProjectWiring? project,
  }) : _dataDir = dataDir,
       _eventBus = eventBus,
       _storage = storage,
       _project = project;

  final DartclawConfig config;
  final String _dataDir;
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
  late AgentObserver _agentObserver;
  late TaskExecutor _taskExecutor;
  late ChannelReviewHandler _reviewHandler;
  late TaskCancellationSubscriber _taskCancellationSubscriber;
  late ContainerTaskFailureSubscriber _containerTaskFailureSubscriber;
  late CompactionTaskEventSubscriber _compactionTaskEventSubscriber;

  WorktreeManager get worktreeManager => _worktreeManager;
  MergeExecutor get mergeExecutor => _mergeExecutor;
  TaskFileGuard get taskFileGuard => _taskFileGuard;
  TaskReviewService get taskReviewService => _taskReviewService;
  RemotePushService get remotePushService => _remotePushService;
  PrCreator get prCreator => _prCreator;
  DiffGenerator get diffGenerator => _diffGenerator;
  ArtifactCollector get artifactCollector => _artifactCollector;
  AgentObserver get agentObserver => _agentObserver;
  TaskExecutor get taskExecutor => _taskExecutor;

  /// The channel review handler — available after [wirePreServer].
  ChannelReviewHandler get reviewHandler => _reviewHandler;

  /// Pre-wires services that do not need [TurnManager].
  ///
  /// Must be called before [ChannelWiring.wire] so the [reviewHandler] is
  /// available for the channel task bridge.
  Future<void> wirePreServer() async {
    _mergeExecutor = MergeExecutor(
      projectDir: Directory.current.path,
      defaultStrategy: config.tasks.worktreeMergeStrategy == 'merge' ? MergeStrategy.merge : MergeStrategy.squash,
    );
    _taskFileGuard = TaskFileGuard();
    _worktreeManager = WorktreeManager(
      dataDir: _dataDir,
      projectDir: Directory.current.path,
      baseRef: config.tasks.worktreeBaseRef,
      staleTimeoutHours: config.tasks.worktreeStaleTimeoutHours,
      worktreesDir: p.join(config.workspaceDir, '.dartclaw', 'worktrees'),
    );
    await _worktreeManager.detectStaleWorktrees();

    _remotePushService = RemotePushService(credentials: config.credentials, dataDir: _dataDir);
    _prCreator = PrCreator(credentials: config.credentials);

    _taskReviewService = TaskReviewService(
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
      eventRecorder: _storage.taskEventRecorder,
    );
    _reviewHandler = _taskReviewService.channelReviewHandler(trigger: 'channel');
  }

  /// Wires task services that require a live [TurnManager].
  ///
  /// Must be called after server construction. [turns] comes from the
  /// newly-built server, [pool] from [HarnessWiring].
  Future<void> wirePostServer({
    required TurnManager turns,
    required HarnessPool pool,
    Future<void> Function()? onSpawnNeeded,
  }) async {
    _diffGenerator = DiffGenerator(projectDir: Directory.current.path);
    _artifactCollector = ArtifactCollector(
      tasks: _storage.taskService,
      messages: _storage.messages,
      sessionsDir: config.sessionsDir,
      dataDir: _dataDir,
      workspaceDir: Directory.current.path,
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

    _agentObserver = AgentObserver(pool: pool, eventBus: _eventBus);

    _taskExecutor = TaskExecutor(
      tasks: _storage.taskService,
      goals: _storage.goalService,
      sessions: _storage.sessions,
      messages: _storage.messages,
      turns: turns,
      artifactCollector: _artifactCollector,
      worktreeManager: _worktreeManager,
      taskFileGuard: _taskFileGuard,
      observer: _agentObserver,
      eventRecorder: _storage.taskEventRecorder,
      onSpawnNeeded: onSpawnNeeded,
      onAutoAccept: buildAutoAcceptCallback(
        completionAction: config.tasks.completionAction,
        reviewTask: (taskId) => _taskReviewService.review(taskId, 'accept', trigger: 'auto_accept'),
      ),
      projectService: _project?.projectService,
      workspaceDir: config.workspaceDir,
      maxMemoryBytes: config.memory.maxBytes,
      compactInstructions: config.context.compactInstructions,
      identifierPreservation: config.context.identifierPreservation,
      identifierInstructions: config.context.identifierInstructions,
      kvService: _storage.kvService,
      budgetConfig: config.tasks.budget,
      eventBus: _eventBus,
      dataDir: _dataDir,
    );
    _taskExecutor.start();
    _log.fine('TaskExecutor started');
  }

  /// Injects a push-back feedback delivery callback into [TaskReviewService].
  ///
  /// Called after the server is built so the callback can reference [serverRef].
  /// Recreates the review service (and channel review handler) with the callback.
  /// Safe to call after [wirePreServer] but before any review actions occur.
  void setPushBackFeedbackDelivery(PushBackFeedbackDelivery? delivery) {
    _taskReviewService = TaskReviewService(
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
      pushBackFeedbackDelivery: delivery,
      eventRecorder: _storage.taskEventRecorder,
    );
    _reviewHandler = _taskReviewService.channelReviewHandler(trigger: 'channel');
    _log.fine('TaskReviewService updated with push-back feedback delivery');
  }

  Future<void> dispose() async {
    await _taskExecutor.stop();
    _agentObserver.dispose();
    await _taskCancellationSubscriber.dispose();
    await _containerTaskFailureSubscriber.dispose();
    await _compactionTaskEventSubscriber.dispose();
  }
}
