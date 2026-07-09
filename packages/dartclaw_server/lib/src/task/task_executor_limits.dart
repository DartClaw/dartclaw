import 'package:dartclaw_config/dartclaw_config.dart'
    show IdentifierPreservationMode, TaskBudgetConfig, TurnProgressAction;

/// Policy and limits configuration for [TaskExecutor].
class TaskExecutorLimits {
  const TaskExecutorLimits({
    this.maxMemoryBytes,
    this.compactInstructions,
    this.identifierPreservation = IdentifierPreservationMode.strict,
    this.identifierInstructions,
    this.budgetConfig,
    this.defaultProviderId = 'claude',
    this.stallTimeout = Duration.zero,
    this.stallAction = TurnProgressAction.warn,
    this.defaultStepTimeout,
  });

  final int? maxMemoryBytes;
  final String? compactInstructions;
  final IdentifierPreservationMode identifierPreservation;
  final String? identifierInstructions;
  final TaskBudgetConfig? budgetConfig;
  final String? defaultProviderId;
  final Duration stallTimeout;
  final TurnProgressAction stallAction;
  final Duration? defaultStepTimeout;
}
