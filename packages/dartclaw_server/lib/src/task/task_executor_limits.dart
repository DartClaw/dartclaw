import 'package:dartclaw_config/dartclaw_config.dart' show IdentifierPreservationMode, TaskBudgetConfig;

/// Policy and limits configuration for [TaskExecutor].
class TaskExecutorLimits {
  const TaskExecutorLimits({
    this.maxMemoryBytes,
    this.compactInstructions,
    this.identifierPreservation = IdentifierPreservationMode.strict,
    this.identifierInstructions,
    this.budgetConfig,
  });

  final int? maxMemoryBytes;
  final String? compactInstructions;
  final IdentifierPreservationMode identifierPreservation;
  final String? identifierInstructions;
  final TaskBudgetConfig? budgetConfig;
}
