import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import '../observability/usage_tracker.dart';
import 'budget_engine.dart';

// ---------------------------------------------------------------------------
// BudgetStatus
// ---------------------------------------------------------------------------

/// Budget status for `/status` reporting.
class BudgetStatus {
  final bool enabled;
  final int tokensUsed;
  final int budget;
  final int percentage;
  final BudgetAction? action;
  final String? timezone;

  const new({
    required this.enabled,
    this.tokensUsed = 0,
    this.budget = 0,
    this.percentage = 0,
    this.action,
    this.timezone,
  });
}

// ---------------------------------------------------------------------------
// BudgetEnforcer
// ---------------------------------------------------------------------------

/// The daily/global scope over [BudgetEngine]: an instance-wide token
/// guardrail evaluated per turn.
///
/// Reads persisted daily totals from [UsageTracker.dailySummaryForDate] and
/// keeps its warn-once marker in the same aggregate, so one warning per day
/// survives a restart. "Today" is [UsageTracker.dailyKeyFor]'s day, the one the
/// usage was recorded in; the wiring builds the tracker with
/// [BudgetConfig.timezone].
///
/// Deliberately has no error handling: a storage failure must surface to the
/// caller rather than silently allow an over-budget turn.
class BudgetEnforcer {
  /// Fraction of the daily budget at which the operator is warned.
  static const _dailyWarningThreshold = 0.8;

  static const _engine = BudgetEngine();

  final UsageTracker _usageTracker;
  final BudgetConfig _config;

  new({required UsageTracker usageTracker, required BudgetConfig config})
    : _usageTracker = usageTracker,
      _config = config;

  /// The configured action once the daily budget is exhausted.
  ///
  /// Consumers map it — with the evaluation's outcome — onto block-vs-warn;
  /// the engine never sees it.
  BudgetAction get action => _config.action;

  /// Evaluates today's token consumption against the configured daily budget.
  ///
  /// Returns [BudgetOutcome.under] when the budget is disabled. The first
  /// evaluation to reach either threshold consumes the day's warning
  /// ([BudgetEvaluation.warningIsNew]); later ones on the same day do not.
  Future<BudgetEvaluation> check({DateTime? now}) => _engine.evaluate(_scopeAt(now ?? DateTime.now()));

  /// Returns current budget status for `/status` reporting.
  Future<BudgetStatus> status({DateTime? now}) async {
    if (!_config.enabled) {
      return const BudgetStatus(enabled: false);
    }

    final scope = _scopeAt(now ?? DateTime.now());
    final consumption = await scope.read();
    final budget = scope.limit ?? 0;

    return BudgetStatus(
      enabled: true,
      tokensUsed: consumption.tokensUsed,
      budget: budget,
      percentage: budgetPercentage(consumption.tokensUsed, budget),
      action: _config.action,
      timezone: _usageTracker.timezone,
    );
  }

  _DailyBudgetScope _scopeAt(DateTime timestamp) =>
      _DailyBudgetScope(usageTracker: _usageTracker, config: _config, timestamp: timestamp);
}

// ---------------------------------------------------------------------------
// _DailyBudgetScope
// ---------------------------------------------------------------------------

/// One day's window over the persisted usage aggregate.
final class _DailyBudgetScope implements BudgetScope {
  new({required UsageTracker usageTracker, required BudgetConfig config, required DateTime timestamp})
    : _usageTracker = usageTracker,
      _config = config,
      _timestamp = timestamp;

  final UsageTracker _usageTracker;
  final BudgetConfig _config;
  final DateTime _timestamp;

  /// Resolved lazily so a disabled budget reads no usage aggregate.
  late final String _dateKey = _usageTracker.dailyKeyFor(_timestamp);

  @override
  double get warningThreshold => BudgetEnforcer._dailyWarningThreshold;

  @override
  bool get limitConsumesWarning => true;

  @override
  int? get limit => _config.enabled ? _config.dailyTokens : null;

  @override
  Future<BudgetConsumption> readConsumption() => read();

  @override
  Future<void> markWarningPosted() => _usageTracker.markBudgetWarningPosted(_dateKey, timestamp: _timestamp);

  /// The non-nullable form of [readConsumption]: the daily aggregate always
  /// yields a reading, treating an absent summary as zero tokens.
  Future<BudgetConsumption> read() async {
    final summary = await _usageTracker.dailySummaryForDate(_dateKey);
    return BudgetConsumption(
      tokensUsed: _totalTokens(summary),
      warningPosted: summary?['budget_warning_posted_at'] is String,
    );
  }

  static int _totalTokens(Map<String, dynamic>? summary) {
    if (summary == null) return 0;
    final input = summary['total_input_tokens'] as int? ?? 0;
    final output = summary['total_output_tokens'] as int? ?? 0;
    return input + output;
  }
}
