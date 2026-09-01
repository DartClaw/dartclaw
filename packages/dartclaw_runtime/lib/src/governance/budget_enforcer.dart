import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:logging/logging.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

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
/// survives a restart. Timezone-aware: [BudgetConfig.timezone] decides which
/// day "today" is.
///
/// Supported timezone formats: `UTC`, `UTC+N`, `UTC-N`, and IANA timezone names.
///
/// Deliberately has no error handling: a storage failure must surface to the
/// caller rather than silently allow an over-budget turn.
class BudgetEnforcer {
  static final _log = Logger('BudgetEnforcer');
  static var _timezoneDataInitialized = false;

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
      timezone: _config.timezone,
    );
  }

  _DailyBudgetScope _scopeAt(DateTime timestamp) =>
      _DailyBudgetScope(usageTracker: _usageTracker, config: _config, timestamp: timestamp);

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

  /// Resolved lazily so a disabled budget never resolves a timezone — and never
  /// logs an unknown-zone warning for a guardrail nobody enabled.
  late final String _dateKey = BudgetEnforcer._dateKey(BudgetEnforcer._localTimeFor(_timestamp, _config.timezone));

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
