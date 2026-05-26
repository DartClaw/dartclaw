import '../turn_manager.dart' show TurnManager;
import 'agent_observer.dart';
import 'workflow_cli_runner.dart';

/// Turn-management and orchestration dependencies for [TaskExecutor].
class TaskExecutorRunners {
  const TaskExecutorRunners({required this.turns, this.observer, this.workflowCliRunner});

  final TurnManager turns;
  final AgentObserver? observer;
  final WorkflowCliRunner? workflowCliRunner;
}
