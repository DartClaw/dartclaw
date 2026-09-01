// ---------------------------------------------------------------------------
// BudgetOutcome
// ---------------------------------------------------------------------------

/// Outcome of a single budget evaluation, shared by every budget scope.
///
/// The outcome describes consumption only. What a breach *means* — reject the
/// turn, fail the task — belongs to the scope's consumer.
enum BudgetOutcome {
  /// Consumption is below the scope's warning threshold.
  under,

  /// Consumption is at or above the warning threshold but below the limit.
  warning,

  /// Consumption is at or above the limit.
  exceeded,
}

// ---------------------------------------------------------------------------
// Budget arithmetic
// ---------------------------------------------------------------------------

/// Fraction of [limit] consumed by [tokensUsed]; `0` when [limit] is not positive.
double budgetRatio(int tokensUsed, int limit) => limit > 0 ? tokensUsed / limit : 0;

/// Rounded percentage of [limit] consumed by [tokensUsed]; `0` when [limit] is
/// not positive.
int budgetPercentage(int tokensUsed, int limit) => (budgetRatio(tokensUsed, limit) * 100).round();

// ---------------------------------------------------------------------------
// BudgetConsumption
// ---------------------------------------------------------------------------

/// A scope's consumption reading for the current window.
final class BudgetConsumption {
  final int tokensUsed;

  /// Whether this window's warn-once marker has already been written.
  final bool warningPosted;

  const new({required this.tokensUsed, required this.warningPosted});
}

// ---------------------------------------------------------------------------
// BudgetScope
// ---------------------------------------------------------------------------

/// Supplies the limit, the consumption reading and the warn-once cell for one
/// budget scope.
///
/// Implementations own all I/O and all error posture. [BudgetEngine] neither
/// catches nor retries, so a scope that must fail open wraps the evaluation
/// rather than asking the engine to swallow the failure.
abstract interface class BudgetScope {
  double get warningThreshold;

  /// Whether reaching the limit also consumes this scope's warn-once marker.
  ///
  /// The daily guardrail burns the day's single warning on the first crossing
  /// of either threshold. The per-task cap fails the task terminally instead
  /// and leaves its marker unwritten, so a retried task can still warn.
  bool get limitConsumesWarning;

  /// Tokens allowed for this window, or `null` when the scope is unlimited.
  ///
  /// Read before consumption, so an unlimited scope costs no I/O.
  int? get limit;

  /// Tokens consumed in this window, or `null` when no reading exists.
  Future<BudgetConsumption?> readConsumption();

  Future<void> markWarningPosted();
}

// ---------------------------------------------------------------------------
// BudgetEvaluation
// ---------------------------------------------------------------------------

/// Result of evaluating one scope's consumption against its limit.
final class BudgetEvaluation {
  final BudgetOutcome outcome;
  final int tokensUsed;
  final int limit;

  /// Whether this evaluation is the one that wrote the scope's warn-once marker.
  final bool warningIsNew;

  const new({required this.outcome, this.tokensUsed = 0, this.limit = 0, this.warningIsNew = false});

  /// The evaluation returned for a scope with no limit.
  static const unlimited = BudgetEvaluation(outcome: BudgetOutcome.under);

  /// Fraction of [limit] consumed; `0` when there is no limit.
  double get ratio => budgetRatio(tokensUsed, limit);

  /// Rounded percentage of [limit] consumed; `0` when there is no limit.
  int get percentage => budgetPercentage(tokensUsed, limit);
}

// ---------------------------------------------------------------------------
// BudgetEngine
// ---------------------------------------------------------------------------

/// The one implementation of token-budget arithmetic: threshold comparison,
/// percentage, and warn-once gating.
final class BudgetEngine {
  const new();

  /// Evaluates [scope]'s consumption against its limit, writing the scope's
  /// warn-once marker when this evaluation is the first to cross a threshold
  /// that consumes it.
  Future<BudgetEvaluation> evaluate(BudgetScope scope) async {
    final limit = scope.limit;
    if (limit == null || limit <= 0) return BudgetEvaluation.unlimited;

    final consumption = await scope.readConsumption();
    if (consumption == null) return BudgetEvaluation(outcome: BudgetOutcome.under, limit: limit);

    final tokensUsed = consumption.tokensUsed;
    final ratio = budgetRatio(tokensUsed, limit);

    if (ratio >= 1.0) {
      final warningIsNew = scope.limitConsumesWarning && !consumption.warningPosted;
      if (warningIsNew) await scope.markWarningPosted();
      return BudgetEvaluation(
        outcome: BudgetOutcome.exceeded,
        tokensUsed: tokensUsed,
        limit: limit,
        warningIsNew: warningIsNew,
      );
    }

    if (ratio >= scope.warningThreshold) {
      final warningIsNew = !consumption.warningPosted;
      if (warningIsNew) await scope.markWarningPosted();
      return BudgetEvaluation(
        outcome: BudgetOutcome.warning,
        tokensUsed: tokensUsed,
        limit: limit,
        warningIsNew: warningIsNew,
      );
    }

    return BudgetEvaluation(outcome: BudgetOutcome.under, tokensUsed: tokensUsed, limit: limit);
  }
}
