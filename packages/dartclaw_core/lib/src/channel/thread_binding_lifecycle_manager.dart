import 'dart:async';

import 'package:logging/logging.dart';

import '../events/dartclaw_event.dart';
import '../events/event_bus.dart';
import 'thread_binding.dart';

/// Manages the lifecycle of [ThreadBinding] records.
///
/// Two responsibilities:
///   1. **Auto-unbind** — subscribes to [TaskStatusChangedEvent] on the
///      [EventBus] and removes the binding when the task reaches a terminal
///      state (accepted / rejected / cancelled / failed).
///   2. **Idle timeout cleanup** — runs a periodic timer that removes bindings
///      whose [ThreadBinding.lastActivity] exceeds [idleTimeout].
///
/// Call [start] once after construction to activate both mechanisms.
/// Call [dispose] on shutdown to cancel the subscription and timer.
class ThreadBindingLifecycleManager {
  static final _log = Logger('ThreadBindingLifecycleManager');

  final ThreadBindingStore _store;
  final EventBus _eventBus;
  final Duration _idleTimeout;
  final Duration _cleanupInterval;

  StreamSubscription<TaskStatusChangedEvent>? _eventSub;
  Timer? _cleanupTimer;

  /// Creates a lifecycle manager.
  ///
  /// [store] — the binding store to manage.
  /// [eventBus] — the bus to subscribe on for task status events.
  /// [idleTimeout] — how long since last activity before a binding is removed
  ///   (default: 1 hour).
  /// [cleanupInterval] — how often the idle-timeout sweep runs
  ///   (default: 5 minutes).
  ThreadBindingLifecycleManager({
    required ThreadBindingStore store,
    required EventBus eventBus,
    Duration idleTimeout = const Duration(hours: 1),
    Duration cleanupInterval = const Duration(minutes: 5),
  })  : _store = store,
        _eventBus = eventBus,
        _idleTimeout = idleTimeout,
        _cleanupInterval = cleanupInterval;

  /// Starts listening for task status events and schedules periodic cleanup.
  void start() {
    _eventSub = _eventBus.on<TaskStatusChangedEvent>().listen(_onTaskStatusChanged);
    _cleanupTimer = Timer.periodic(_cleanupInterval, (_) => _cleanupExpiredBindings());
  }

  /// Cancels the event subscription and the cleanup timer.
  void dispose() {
    _eventSub?.cancel();
    _eventSub = null;
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
  }

  void _onTaskStatusChanged(TaskStatusChangedEvent event) {
    if (!event.newStatus.terminal) return;
    final removed = _store.deleteByTaskId(event.taskId);
    if (removed != null) {
      _log.info(
        'Removed thread binding for task ${event.taskId} '
        '(reason: terminal state ${event.newStatus.name})',
      );
    }
  }

  void _cleanupExpiredBindings() {
    final cutoff = DateTime.now().subtract(_idleTimeout);
    final expired = _store.removeExpiredBindings(cutoff);
    for (final binding in expired) {
      _log.info(
        'Removed thread binding for task ${binding.taskId} '
        '(reason: idle timeout, last activity: ${binding.lastActivity.toIso8601String()})',
      );
    }
  }
}
