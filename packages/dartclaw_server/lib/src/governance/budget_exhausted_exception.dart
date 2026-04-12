import 'package:dartclaw_core/dartclaw_core.dart';

/// Thrown when a turn is rejected because the daily token budget is exhausted.
///
/// Only thrown when [BudgetConfig.action] is [BudgetAction.block] and the daily
/// token total has reached or exceeded [BudgetConfig.dailyTokens].
///
/// Implements [BudgetExhaustedError] so that [MessageQueue] in `dartclaw_core`
/// can catch it without a circular package dependency.
class BudgetExhaustedException implements Exception, BudgetExhaustedError {
  @override
  final int tokensUsed;
  @override
  final int budget;

  const BudgetExhaustedException({required this.tokensUsed, required this.budget});

  @override
  String toString() =>
      'Daily token budget exhausted: $tokensUsed/$budget tokens used. '
      'New turns blocked until daily reset.';
}
