part of 'governance_config.dart';

/// Action to take when the token budget is exceeded.
enum BudgetAction {
  /// Log a warning but continue processing.
  warn,

  /// Block new turns until the next budget window.
  block;

  /// Parses a YAML string to [BudgetAction].
  ///
  /// Returns `null` for unknown values.
  static BudgetAction? fromYaml(String value) => switch (value) {
    'warn' => BudgetAction.warn,
    'block' => BudgetAction.block,
    _ => null,
  };

  /// Returns the YAML representation.
  String toYaml() => name;
}

/// Token budget configuration.
class BudgetConfig {
  /// Maximum daily token usage. 0 = disabled.
  final int dailyTokens;

  /// Action when budget is exceeded.
  final BudgetAction action;

  /// Timezone for daily budget window reset (IANA name, e.g. 'UTC', 'America/New_York').
  final String timezone;

  /// Whether budget enforcement is active (dailyTokens > 0).
  bool get enabled => dailyTokens > 0;

  const BudgetConfig({this.dailyTokens = 0, this.action = BudgetAction.warn, this.timezone = 'UTC'});

  const BudgetConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BudgetConfig && dailyTokens == other.dailyTokens && action == other.action && timezone == other.timezone;

  @override
  int get hashCode => Object.hash(dailyTokens, action, timezone);

  @override
  String toString() => 'BudgetConfig(dailyTokens: $dailyTokens, action: $action, timezone: $timezone)';
}
