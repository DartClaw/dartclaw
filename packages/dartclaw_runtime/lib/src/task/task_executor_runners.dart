import '../turn_manager.dart' show TurnManager;

/// Turn-management and orchestration dependencies for [TaskExecutor].
class TaskExecutorRunners {
  const new({required this.turns});

  final TurnManager turns;
}
