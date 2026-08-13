import '../turn_manager.dart' show TurnManager;
import 'workflow_cli_runner.dart';

/// Turn-management and orchestration dependencies for [TaskExecutor].
class TaskExecutorRunners {
  const new({required this.turns, this.workflowCliRunner});

  final TurnManager turns;
  final WorkflowCliRunner? workflowCliRunner;
}
