import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

import '../harness_pool.dart';
import '../turn_manager.dart';
import '../turn_runner.dart';
import 'agent_observer.dart';
import 'artifact_collector.dart';
import 'goal_service.dart';
import 'task_file_guard.dart';
import 'task_service.dart';
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
    // eventBus is kept for API compatibility but events are now fired by TaskService.
    @Deprecated('Events are now centralized in TaskService. Pass eventBus to TaskService instead.') EventBus? eventBus,
    WorktreeManager? worktreeManager,
    TaskFileGuard? taskFileGuard,
    AgentObserver? observer,
    Future<void> Function()? onSpawnNeeded,
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
       _onSpawnNeeded = onSpawnNeeded;

  static final _log = Logger('TaskExecutor');

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
  final Future<void> Function()? _onSpawnNeeded;
  final Duration pollInterval;

  Timer? _timer;
  Future<bool>? _inFlightPoll;
  bool _isSpawning = false;

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

      var started = false;
      for (final task in queued) {
        final profile = resolveProfile(task.type);
        final runner = _acquirePoolRunner(profile, provider: task.provider);
        if (runner == null) {
          continue;
        }

        final runnerIndex = _pool.indexOf(runner);
        final runningTask = await _checkout(task);
        if (runningTask == null) {
          _pool.release(runner);
          continue;
        }

        started = true;
        _observer?.markBusy(runnerIndex, taskId: runningTask.id);
        unawaited(_runPoolTask(runningTask, runner, runnerIndex: runnerIndex));
      }
      return started;
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

    final task = queued.first;
    _observer?.markBusy(0, taskId: task.id);
    final runningTask = await _checkout(task);
    if (runningTask == null) {
      _observer?.markIdle(0);
      return false;
    }

    try {
      await _execute(runningTask);
      return true;
    } finally {
      _observer?.markIdle(0);
    }
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

  /// Pool-mode execution: uses a specific acquired [runner].
  Future<void> _executeWithRunner(Task runningTask, TurnRunner runner, {required int runnerIndex}) async {
    return _executeCore(
      runningTask,
      runnerIndex: runnerIndex,
      reserveTurn: (sessionId, {String? directory, String? model, String? effort}) =>
          runner.reserveTurn(sessionId, agentName: 'task', directory: directory, model: model, effort: effort),
      executeTurn: runner.executeTurn,
      waitForOutcome: runner.waitForOutcome,
    );
  }

  /// Single-harness fallback execution: uses TurnManager (primary runner).
  Future<void> _execute(Task runningTask) async {
    return _executeCore(
      runningTask,
      runnerIndex: 0,
      reserveTurn: (sessionId, {String? directory, String? model, String? effort}) =>
          _reserveSharedTurn(sessionId, directory: directory, model: model, effort: effort),
      executeTurn: _turns.executeTurn,
      waitForOutcome: _turns.waitForOutcome,
    );
  }

  /// Shared task execution logic for both pool-mode and single-harness paths.
  Future<void> _executeCore(
    Task runningTask, {
    required int runnerIndex,
    required Future<String> Function(String sessionId, {String? directory, String? model, String? effort}) reserveTurn,
    required void Function(
      String sessionId,
      String turnId,
      List<Map<String, dynamic>> messages, {
      String? source,
      String agentName,
    })
    executeTurn,
    required Future<TurnOutcome> Function(String sessionId, String turnId) waitForOutcome,
  }) async {
    var task = runningTask;
    WorktreeInfo? worktreeInfo;
    try {
      // Worktree setup for coding tasks
      if (task.type == TaskType.coding && _worktreeManager != null) {
        worktreeInfo = await _worktreeManager.create(task.id);
        _taskFileGuard?.register(task.id, worktreeInfo.path);
        task = await _tasks.updateFields(task.id, worktreeJson: worktreeInfo.toJson());
      }

      final session = await _sessions.getOrCreateByKey(
        SessionKey.taskSession(taskId: runningTask.id),
        type: SessionType.task,
      );

      if (task.sessionId != session.id) {
        task = await _tasks.updateFields(task.id, sessionId: session.id);
      }

      final pendingMessage = await _composePendingMessage(task, session.id, workingDirectory: worktreeInfo?.path);
      if (pendingMessage == null) {
        _log.warning('Task ${task.id} had no message to execute; marking failed');
        await _markFailed(task, errorSummary: 'Task had no executable prompt.');
        return;
      }
      final modelOverride = _modelOverride(task);
      final effortOverride = _effortOverride(task);
      final tokenBudget = _tokenBudget(task);

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

      final turnId = await reserveTurn(
        session.id,
        directory: worktreeInfo?.path,
        model: modelOverride,
        effort: effortOverride,
      );
      executeTurn(session.id, turnId, turnMessages, source: 'task', agentName: 'task');
      final outcome = await waitForOutcome(session.id, turnId);
      _observer?.recordTurn(
        runnerIndex,
        inputTokens: outcome.inputTokens,
        outputTokens: outcome.outputTokens,
        isError: outcome.status != TurnStatus.completed,
      );

      if (outcome.status == TurnStatus.completed) {
        final refreshed = await _tasks.get(task.id) ?? task;
        if (refreshed.status == TaskStatus.cancelled) {
          return;
        }
        await _artifactCollector.collect(refreshed);
        if (tokenBudget != null && outcome.totalTokens > tokenBudget) {
          _log.warning('Task ${task.id} exceeded token budget ($tokenBudget < ${outcome.totalTokens}); marking failed');
          await _markFailed(
            task,
            errorSummary: 'Token budget exceeded: used ${outcome.totalTokens} tokens against a limit of $tokenBudget.',
          );
          return;
        }
        await _tasks.transition(task.id, TaskStatus.review, trigger: 'system');
        return;
      }

      // Mid-turn loop detection (tool fingerprinting) sets loopDetection on outcome.
      if (outcome.loopDetection != null) {
        _log.warning('Loop detected during task ${task.id}: ${outcome.loopDetection!.message}');
        await _markFailed(task, errorSummary: 'Loop detected: ${outcome.loopDetection!.message}');
        return;
      }

      await _markFailed(task, errorSummary: outcome.errorMessage ?? _defaultTurnFailureSummary(outcome.status));
      return;
    } on LoopDetectedException catch (e) {
      // Pre-turn loop detection (turn chain depth or token velocity).
      _log.warning('Loop detected during task ${task.id}: ${e.message}');
      await _markFailed(task, errorSummary: 'Loop detected: ${e.message}');
      return;
    } catch (error, stackTrace) {
      if (error is GitNotFoundException || error is WorktreeException) {
        _log.warning('Worktree setup failed for task ${task.id}: $error');
      } else {
        _log.warning('Task execution failed for ${task.id}: $error', error, stackTrace);
      }
      await _markFailed(task, errorSummary: _sanitizeErrorSummary(error.toString()));
      return;
    }
  }

  Future<String> _reserveSharedTurn(String sessionId, {String? directory, String? model, String? effort}) async {
    while (true) {
      try {
        return await _turns.reserveTurn(
          sessionId,
          agentName: 'task',
          directory: directory,
          model: model,
          effort: effort,
        );
      } on BusyTurnException {
        await Future<void>.delayed(pollInterval);
      }
    }
  }

  TurnRunner? _acquirePoolRunner(String profile, {String? provider}) {
    if (provider != null) {
      if (!_pool.hasTaskRunnerForProvider(provider)) {
        return null;
      }
      return _pool.tryAcquireForProviderAndProfile(provider, profile);
    }
    if (_pool.hasTaskRunnerForProfile(profile)) {
      return _pool.tryAcquireForProfile(profile);
    }
    if (_pool.taskProfiles.length <= 1) {
      return _pool.tryAcquire();
    }
    return null;
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

    await _messages.getMessages(sessionId);
    return _initialPrompt(task, goalContext: goalContext, workingDirectory: workingDirectory);
  }

  String _initialPrompt(Task task, {String? goalContext, String? workingDirectory}) {
    final buffer = StringBuffer()
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

  Future<void> _markFailed(Task task, {String? errorSummary}) async {
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

  Map<String, dynamic> _withErrorSummary(Map<String, dynamic> configJson, String errorSummary) =>
      Map<String, dynamic>.from(configJson)..['errorSummary'] = _sanitizeErrorSummary(errorSummary);

  String _defaultTurnFailureSummary(TurnStatus status) =>
      status == TurnStatus.cancelled ? 'Turn cancelled' : 'Turn execution failed';

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
