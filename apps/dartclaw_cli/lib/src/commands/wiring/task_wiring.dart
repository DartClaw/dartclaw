import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'storage_wiring.dart';

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
  })  : _dataDir = dataDir,
        _eventBus = eventBus,
        _storage = storage;

  final DartclawConfig config;
  final String _dataDir;
  final EventBus _eventBus;
  final StorageWiring _storage;

  static final _log = Logger('TaskWiring');

  late WorktreeManager _worktreeManager;
  late MergeExecutor _mergeExecutor;
  late TaskFileGuard _taskFileGuard;
  late TaskReviewService _taskReviewService;
  late DiffGenerator _diffGenerator;
  late ArtifactCollector _artifactCollector;
  late AgentObserver _agentObserver;
  late TaskExecutor _taskExecutor;
  late ChannelReviewHandler _reviewHandler;
  late ContainerTaskFailureSubscriber _containerTaskFailureSubscriber;

  WorktreeManager get worktreeManager => _worktreeManager;
  MergeExecutor get mergeExecutor => _mergeExecutor;
  TaskFileGuard get taskFileGuard => _taskFileGuard;
  TaskReviewService get taskReviewService => _taskReviewService;
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
      defaultStrategy: config.tasks.worktreeMergeStrategy == 'merge'
          ? MergeStrategy.merge
          : MergeStrategy.squash,
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

    _taskReviewService = TaskReviewService(
      tasks: _storage.taskService,
      worktreeManager: _worktreeManager,
      taskFileGuard: _taskFileGuard,
      mergeExecutor: _mergeExecutor,
      dataDir: _dataDir,
      mergeStrategy: config.tasks.worktreeMergeStrategy,
      baseRef: config.tasks.worktreeBaseRef,
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
  }) async {
    _diffGenerator = DiffGenerator(projectDir: Directory.current.path);
    _artifactCollector = ArtifactCollector(
      tasks: _storage.taskService,
      messages: _storage.messages,
      sessionsDir: config.sessionsDir,
      dataDir: _dataDir,
      workspaceDir: Directory.current.path,
      diffGenerator: _diffGenerator,
      baseRef: config.tasks.worktreeBaseRef,
    );

    _containerTaskFailureSubscriber = ContainerTaskFailureSubscriber(tasks: _storage.taskService);
    _containerTaskFailureSubscriber.subscribe(_eventBus);

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
      dataDir: _dataDir,
      mergeStrategy: config.tasks.worktreeMergeStrategy,
      baseRef: config.tasks.worktreeBaseRef,
      pushBackFeedbackDelivery: delivery,
    );
    _reviewHandler = _taskReviewService.channelReviewHandler(trigger: 'channel');
    _log.fine('TaskReviewService updated with push-back feedback delivery');
  }

  Future<void> dispose() async {
    await _taskExecutor.stop();
    _agentObserver.dispose();
    await _containerTaskFailureSubscriber.dispose();
  }
}
