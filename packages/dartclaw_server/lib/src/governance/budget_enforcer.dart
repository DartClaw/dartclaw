import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:logging/logging.dart';

import '../observability/usage_tracker.dart';

// ---------------------------------------------------------------------------
// BudgetDecision
// ---------------------------------------------------------------------------

/// Budget enforcement decisions.
enum BudgetDecision {
  /// Under budget — proceed normally.
  allow,

  /// At or above 80% — post warning (once), then allow.
  warn,

  /// At or above 100% and action is [BudgetAction.block] — reject turn.
  block,
}

// ---------------------------------------------------------------------------
// BudgetCheckResult
// ---------------------------------------------------------------------------

/// Result of a budget enforcement check.
class BudgetCheckResult {
  final BudgetDecision decision;
  final int tokensUsed;
  final int budget;
  final int percentage;

  /// True if the warning threshold was crossed for the first time today.
  final bool warningIsNew;

  const BudgetCheckResult({
    required this.decision,
    this.tokensUsed = 0,
    this.budget = 0,
    this.percentage = 0,
    this.warningIsNew = false,
  });
}

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

  const BudgetStatus({
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

/// Checks daily token consumption against the configured budget.
///
/// Reads from [UsageTracker.dailySummaryForDate] to get persisted daily totals.
/// Warning state (80% threshold) is in-memory — resets on restart.
/// Timezone-aware: uses [BudgetConfig.timezone] to determine "today".
///
/// Supported timezone formats: `UTC`, `UTC+N`, `UTC-N`. Named IANA timezones
/// (e.g. `America/New_York`) fall back to UTC with a warning.
class BudgetEnforcer {
  static final _log = Logger('BudgetEnforcer');

  final UsageTracker _usageTracker;
  final BudgetConfig _config;
  final Duration _tzOffset;

  BudgetEnforcer({required UsageTracker usageTracker, required BudgetConfig config})
    : _usageTracker = usageTracker,
      _config = config,
      _tzOffset = _resolveTimezoneOffset(config.timezone);

  /// Returns the enforcement decision for the current budget state.
  ///
  /// Returns:
  /// - [BudgetDecision.allow] if under 80% or budget is disabled (dailyTokens == 0)
  /// - [BudgetDecision.warn] if at/above 80% and warning not yet posted today
  /// - [BudgetDecision.allow] if at/above 80% and warning already posted (no repeat)
  /// - [BudgetDecision.block] if at/above 100% and action is [BudgetAction.block]
  /// - [BudgetDecision.warn] if at/above 100% and action is [BudgetAction.warn]
  Future<BudgetCheckResult> check({DateTime? now}) async {
    if (!_config.enabled) {
      return const BudgetCheckResult(decision: BudgetDecision.allow);
    }

    final timestamp = now ?? DateTime.now();
    final localNow = timestamp.add(_tzOffset);
    final dateKey = _dateKey(localNow);
    final summary = await _usageTracker.dailySummaryForDate(dateKey);

    final totalTokens = _extractTotalTokens(summary);
    final budget = _config.dailyTokens;
    final percentage = budget > 0 ? (totalTokens / budget * 100).round() : 0;
    final warningAlreadyPosted = summary?['budget_warning_posted_at'] is String;

    // At or above 100%
    if (totalTokens >= budget) {
      final shouldWarn = !warningAlreadyPosted;
      if (shouldWarn) {
        await _usageTracker.markBudgetWarningPosted(dateKey, timestamp: timestamp);
      }

      if (_config.action == BudgetAction.block) {
        return BudgetCheckResult(
          decision: BudgetDecision.block,
          tokensUsed: totalTokens,
          budget: budget,
          percentage: percentage,
          warningIsNew: shouldWarn,
        );
      }

      // warn mode at 100% — log but allow
      return BudgetCheckResult(
        decision: shouldWarn ? BudgetDecision.warn : BudgetDecision.allow,
        tokensUsed: totalTokens,
        budget: budget,
        percentage: percentage,
        warningIsNew: shouldWarn,
      );
    }

    // At or above 80%
    if (totalTokens >= budget * 0.8) {
      final shouldWarn = !warningAlreadyPosted;
      if (shouldWarn) {
        await _usageTracker.markBudgetWarningPosted(dateKey, timestamp: timestamp);
      }
      return BudgetCheckResult(
        decision: shouldWarn ? BudgetDecision.warn : BudgetDecision.allow,
        tokensUsed: totalTokens,
        budget: budget,
        percentage: percentage,
        warningIsNew: shouldWarn,
      );
    }

    // Under 80%
    return BudgetCheckResult(
      decision: BudgetDecision.allow,
      tokensUsed: totalTokens,
      budget: budget,
      percentage: percentage,
    );
  }

  /// Returns current budget status for `/status` reporting.
  Future<BudgetStatus> status({DateTime? now}) async {
    if (!_config.enabled) {
      return const BudgetStatus(enabled: false);
    }

    final timestamp = now ?? DateTime.now();
    final localNow = timestamp.add(_tzOffset);
    final dateKey = _dateKey(localNow);
    final summary = await _usageTracker.dailySummaryForDate(dateKey);

    final totalTokens = _extractTotalTokens(summary);
    final budget = _config.dailyTokens;
    final percentage = budget > 0 ? (totalTokens / budget * 100).round() : 0;

    return BudgetStatus(
      enabled: true,
      tokensUsed: totalTokens,
      budget: budget,
      percentage: percentage,
      action: _config.action,
      timezone: _config.timezone,
    );
  }

  int _extractTotalTokens(Map<String, dynamic>? summary) {
    if (summary == null) return 0;
    final input = summary['total_input_tokens'] as int? ?? 0;
    final output = summary['total_output_tokens'] as int? ?? 0;
    return input + output;
  }

  static String _dateKey(DateTime localTime) {
    final m = localTime.month.toString().padLeft(2, '0');
    final d = localTime.day.toString().padLeft(2, '0');
    return 'usage_daily:${localTime.year}-$m-$d';
  }

  /// Resolves timezone string to a fixed UTC offset.
  ///
  /// Supports "UTC", "UTC+N", "UTC-N" formats. For named timezones
  /// (e.g., "America/New_York"), falls back to UTC with a warning.
  /// Full IANA timezone support deferred — fixed offsets cover the
  /// primary use case without adding a timezone dependency.
  static Duration _resolveTimezoneOffset(String timezone) {
    final tz = timezone.trim().toUpperCase();
    if (tz == 'UTC' || tz == 'GMT') return Duration.zero;
    final match = RegExp(r'^UTC([+-])(\d{1,2})$').firstMatch(tz);
    if (match != null) {
      final sign = match.group(1) == '+' ? 1 : -1;
      final hours = int.parse(match.group(2)!);
      return Duration(hours: sign * hours);
    }
    _log.warning(
      'Unrecognized timezone "$timezone" — falling back to UTC. '
      'Supported formats: UTC, UTC+N, UTC-N',
    );
    return Duration.zero;
  }

  // Expose for testing.
  static String dateKeyForTime(DateTime localTime) => _dateKey(localTime);
  static Duration resolveTimezoneOffset(String timezone) => _resolveTimezoneOffset(timezone);
}
