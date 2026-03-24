import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';

import 'task_service.dart';
import 'tool_call_summary.dart';

/// Throttled progress tracker for running tasks.
///
/// Subscribes to [TaskEventCreatedEvent] on [EventBus], accumulates token
/// usage and current tool activity per task, and emits [TaskProgressSnapshot]
/// updates at most once per second per task via [onProgress].
///
/// Multiple SSE connections can subscribe to [onProgress] — it is a broadcast
/// stream. Call [start] once after construction, [dispose] on shutdown.
class TaskProgressTracker {
  final EventBus _eventBus;
  final TaskService _tasks;
  final _progressController = StreamController<TaskProgressSnapshot>.broadcast();
  final _state = <String, _TaskProgressState>{};
  final _timers = <String, Timer>{};
  StreamSubscription<TaskEventCreatedEvent>? _subscription;

  static const _throttleInterval = Duration(seconds: 1);

  TaskProgressTracker({required EventBus eventBus, required TaskService tasks}) : _eventBus = eventBus, _tasks = tasks;

  /// Broadcast stream of throttled progress snapshots.
  Stream<TaskProgressSnapshot> get onProgress => _progressController.stream;

  /// Start listening to [TaskEventCreatedEvent] on the event bus.
  void start() {
    _subscription = _eventBus.on<TaskEventCreatedEvent>().listen(_onEvent);
  }

  /// Cancel subscriptions, timers, and close the broadcast stream.
  void dispose() {
    _subscription?.cancel();
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _state.clear();
    _progressController.close();
  }

  /// Returns the current snapshot for [taskId], or null if no state exists.
  TaskProgressSnapshot? currentSnapshot(String taskId) {
    final state = _state[taskId];
    if (state == null) return null;
    return _buildSnapshot(taskId, state);
  }

  /// Seeds tracker state from historical [events] for [taskId].
  ///
  /// Accepts raw maps with `kind` (String) and `details` (Map) keys.
  /// Call before [start] (or while running) to replay persisted events so
  /// that cumulative counters are correct when the first live event arrives.
  void seedFromEvents(String taskId, List<Map<String, dynamic>> events, {int? tokenBudget}) {
    final state = _state.putIfAbsent(taskId, _TaskProgressState.new);
    state.tokenBudget ??= tokenBudget;
    for (final e in events) {
      final kind = e['kind']?.toString() ?? '';
      final details = (e['details'] as Map<String, dynamic>?) ?? const {};
      _applyEvent(state, kind, details);
    }
  }

  void _onEvent(TaskEventCreatedEvent event) {
    final kind = event.kind;
    final details = event.details;
    final taskId = event.taskId;

    if (kind == 'statusChanged') {
      final newStatus = details['newStatus']?.toString() ?? '';
      if (newStatus == 'running') {
        // Initialize state, then asynchronously resolve token budget.
        _state.putIfAbsent(taskId, _TaskProgressState.new);
        unawaited(_resolveTokenBudget(taskId));
      } else {
        // Task left running state — emit final snapshot then clear.
        final state = _state[taskId];
        if (state != null) {
          _timers[taskId]?.cancel();
          _timers.remove(taskId);
          if (!_progressController.isClosed) {
            _progressController.add(
              TaskProgressSnapshot(
                taskId: taskId,
                progress: _computeProgress(state),
                currentActivity: state.currentActivity,
                tokensUsed: state.tokensUsed,
                tokenBudget: state.tokenBudget,
                isComplete: true,
              ),
            );
          }
          _state.remove(taskId);
        }
      }
      return;
    }

    final state = _state[taskId];
    if (state == null) return; // Task not in running state — ignore.

    _applyEvent(state, kind, details);
    _scheduleEmit(taskId);
  }

  void _applyEvent(_TaskProgressState state, String kind, Map<String, dynamic> details) {
    switch (kind) {
      case 'toolCalled':
        final name = details['name']?.toString() ?? '';
        state.currentActivity = _formatActivity(name, details);
      case 'tokenUpdate':
        final input = ((details['inputTokens'] as num?)?.toInt() ?? 0).clamp(0, 1 << 30);
        final output = ((details['outputTokens'] as num?)?.toInt() ?? 0).clamp(0, 1 << 30);
        state.tokensUsed += input + output;
    }
  }

  void _scheduleEmit(String taskId) {
    final state = _state[taskId];
    if (state == null) return;

    if (_timers.containsKey(taskId)) {
      // Inside throttle window — mark dirty, deferred emit will handle it.
      state.dirty = true;
      return;
    }

    // No active timer — emit immediately, then arm throttle timer.
    _emit(taskId, state);
    _timers[taskId] = Timer(_throttleInterval, () {
      _timers.remove(taskId);
      final s = _state[taskId];
      if (s != null && s.dirty) {
        _emit(taskId, s);
        // If more events arrived, they re-arm via next _scheduleEmit call.
      }
    });
  }

  void _emit(String taskId, _TaskProgressState state) {
    state.dirty = false;
    if (!_progressController.isClosed) {
      _progressController.add(_buildSnapshot(taskId, state));
    }
  }

  TaskProgressSnapshot _buildSnapshot(String taskId, _TaskProgressState state) {
    return TaskProgressSnapshot(
      taskId: taskId,
      progress: _computeProgress(state),
      currentActivity: state.currentActivity,
      tokensUsed: state.tokensUsed,
      tokenBudget: state.tokenBudget,
      isComplete: false,
    );
  }

  int? _computeProgress(_TaskProgressState state) {
    final budget = state.tokenBudget;
    if (budget == null || budget <= 0) return null;
    return (state.tokensUsed / budget * 100).round().clamp(0, 100);
  }

  Future<void> _resolveTokenBudget(String taskId) async {
    try {
      final task = await _tasks.get(taskId);
      if (task == null) return;
      final budget = (task.configJson['tokenBudget'] as num?)?.toInt() ?? (task.configJson['budget'] as num?)?.toInt();
      final state = _state[taskId];
      if (state != null && budget != null) {
        state.tokenBudget = budget;
      }
    } catch (_) {
      // Non-critical — tracker continues without budget.
    }
  }

  /// Maps raw tool names to user-friendly activity verbs.
  static String _formatActivity(String toolName, Map<String, dynamic> details) {
    final context = details['context']?.toString();
    return formatToolActivity(toolName, context: context);
  }

  /// Public alias for tests.
  static String formatActivity(String toolName, Map<String, dynamic> details) => _formatActivity(toolName, details);
}

/// Immutable snapshot of a task's current progress state.
class TaskProgressSnapshot {
  final String taskId;

  /// Progress percentage 0–100, or null if no token budget is set.
  final int? progress;

  /// Human-readable description of the current tool activity.
  final String? currentActivity;

  /// Cumulative tokens used across all turns so far.
  final int tokensUsed;

  /// Configured token budget, or null if none.
  final int? tokenBudget;

  /// True when emitted because the task left the running state.
  final bool isComplete;

  const TaskProgressSnapshot({
    required this.taskId,
    required this.progress,
    required this.currentActivity,
    required this.tokensUsed,
    required this.tokenBudget,
    required this.isComplete,
  });

  Map<String, dynamic> toJson() => {
    'type': 'task_progress',
    'taskId': taskId,
    'progress': progress,
    'currentActivity': currentActivity,
    'tokensUsed': tokensUsed,
    'tokenBudget': tokenBudget,
    'isComplete': isComplete,
  };

  @override
  String toString() => jsonEncode(toJson());
}

class _TaskProgressState {
  String? currentActivity;
  int tokensUsed = 0;
  int? tokenBudget;
  bool dirty = false;
}
