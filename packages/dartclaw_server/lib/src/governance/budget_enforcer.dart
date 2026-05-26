import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:logging/logging.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

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
/// Supported timezone formats: `UTC`, `UTC+N`, `UTC-N`, and IANA timezone names.
class BudgetEnforcer {
  static final _log = Logger('BudgetEnforcer');
  static var _timezoneDataInitialized = false;

  final UsageTracker _usageTracker;
  final BudgetConfig _config;

  BudgetEnforcer({required UsageTracker usageTracker, required BudgetConfig config})
    : _usageTracker = usageTracker,
      _config = config;

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
    final localNow = _localTimeFor(timestamp, _config.timezone);
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
    final localNow = _localTimeFor(timestamp, _config.timezone);
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

  static DateTime _localTimeFor(DateTime timestamp, String timezone) {
    final utcTimestamp = timestamp.toUtc();
    final location = _resolveIanaLocation(timezone);
    if (location != null) {
      return tz.TZDateTime.from(utcTimestamp, location);
    }
    return utcTimestamp.add(_resolveTimezoneOffset(timezone, at: utcTimestamp));
  }

  /// Resolves timezone string to a UTC offset at [at].
  static Duration _resolveTimezoneOffset(String timezone, {DateTime? at}) {
    final fixedOffset = _resolveFixedTimezoneOffset(timezone);
    if (fixedOffset != null) return fixedOffset;
    final location = _resolveIanaLocation(timezone);
    if (location != null) {
      return tz.TZDateTime.from((at ?? DateTime.now()).toUtc(), location).timeZoneOffset;
    }
    _log.warning(
      'Unrecognized timezone "$timezone" — falling back to UTC. '
      'Supported formats: UTC, UTC+N, UTC-N, or IANA timezone names',
    );
    return Duration.zero;
  }

  static Duration? _resolveFixedTimezoneOffset(String timezone) {
    final normalized = timezone.trim().toUpperCase();
    if (normalized == 'UTC' || normalized == 'GMT') return Duration.zero;
    final match = RegExp(r'^UTC([+-])(\d{1,2})$').firstMatch(normalized);
    if (match != null) {
      final sign = match.group(1) == '+' ? 1 : -1;
      final hours = int.parse(match.group(2)!);
      return Duration(hours: sign * hours);
    }
    return null;
  }

  static tz.Location? _resolveIanaLocation(String timezone) {
    final value = timezone.trim();
    if (value.isEmpty || !value.contains('/')) return null;
    try {
      if (!_timezoneDataInitialized) {
        tzdata.initializeTimeZones();
        _timezoneDataInitialized = true;
      }
      return tz.getLocation(value);
    } on tz.LocationNotFoundException {
      return null;
    }
  }

  // Expose for testing.
  static String dateKeyForTime(DateTime localTime) => _dateKey(localTime);
  static Duration resolveTimezoneOffset(String timezone, {DateTime? at}) => _resolveTimezoneOffset(timezone, at: at);
}
