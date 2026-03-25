import 'dart:async';
import 'dart:math';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

import '../observability/usage_tracker.dart';
import '../task/task_service.dart';
import '../templates/canvas_stats_bar.dart';
import '../templates/canvas_task_board.dart';
import 'canvas_service.dart';

/// Auto-renders workshop canvas fragments when task state changes.
class WorkshopCanvasSubscriber {
  static final _log = Logger('WorkshopCanvasSubscriber');

  final CanvasService _canvasService;
  final TaskService _taskService;
  final UsageTracker _usageTracker;
  final String _sessionKey;
  final int _dailyBudgetTokens;
  final DateTime _serverStartTime;
  final bool _taskBoardEnabled;
  final bool _statsBarEnabled;
  final ThreadBindingStore? _threadBindings;

  StreamSubscription<TaskStatusChangedEvent>? _subscription;
  Timer? _debounceTimer;

  WorkshopCanvasSubscriber({
    required CanvasService canvasService,
    required TaskService taskService,
    required UsageTracker usageTracker,
    required String sessionKey,
    required int dailyBudgetTokens,
    required DateTime serverStartTime,
    bool taskBoardEnabled = true,
    bool statsBarEnabled = true,
    ThreadBindingStore? threadBindings,
  }) : _canvasService = canvasService,
       _taskService = taskService,
       _usageTracker = usageTracker,
       _sessionKey = sessionKey,
       _dailyBudgetTokens = dailyBudgetTokens,
       _serverStartTime = serverStartTime,
       _taskBoardEnabled = taskBoardEnabled,
       _statsBarEnabled = statsBarEnabled,
       _threadBindings = threadBindings;

  /// Starts listening for task status updates.
  void subscribe(EventBus eventBus) {
    if (_subscription != null) return;
    if (!_taskBoardEnabled && !_statsBarEnabled) {
      _log.fine('Workshop canvas subscriber disabled (both fragments disabled).');
      return;
    }

    _subscription = eventBus.on<TaskStatusChangedEvent>().listen((event) {
      unawaited(_onTaskStatusChanged(event));
    });
  }

  Future<void> _onTaskStatusChanged(TaskStatusChangedEvent _) async {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(_renderAndPush());
    });
  }

  Future<void> _renderAndPush() async {
    try {
      final tasks = await _taskService.list();
      final fragments = <String>[];

      if (_statsBarEnabled) {
        fragments.add(
          await canvasStatsBarFragment(
            tasks: tasks,
            usageTracker: _usageTracker,
            dailyBudgetTokens: _dailyBudgetTokens,
            serverStartTime: _serverStartTime,
          ),
        );
      }

      if (_taskBoardEnabled) {
        final bindingCounts = <String, int>{
          for (final task in tasks) task.id: max(0, _threadBindings?.lookupByTask(task.id).length ?? 0),
        };
        fragments.add(canvasTaskBoardFragment(tasks, bindingCounts: bindingCounts));
      }

      if (fragments.isEmpty) return;
      _canvasService.push(_sessionKey, fragments.join('\n'));
    } catch (error, stackTrace) {
      _log.warning('Failed to render/push workshop canvas update', error, stackTrace);
    }
  }

  /// Stops listening and clears pending debounced renders.
  Future<void> dispose() async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    await _subscription?.cancel();
    _subscription = null;
  }
}
