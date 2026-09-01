import 'package:dartclaw_kernel/dartclaw_kernel.dart';

/// Policy and limits configuration for [TaskExecutor].
class TaskExecutorLimits {
  const new({
    this.maxMemoryBytes,
    this.compactInstructions,
    this.identifierPreservation = IdentifierPreservationMode.strict,
    this.identifierInstructions,
    this.budgetConfig,
    this.defaultProviderId = 'claude',
  });

  final int? maxMemoryBytes;
  final String? compactInstructions;
  final IdentifierPreservationMode identifierPreservation;
  final String? identifierInstructions;
  final TaskBudgetConfig? budgetConfig;
  final String? defaultProviderId;
}
