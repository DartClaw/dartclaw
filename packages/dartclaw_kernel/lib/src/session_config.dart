import 'session_maintenance_config.dart';
import 'session_scope_config.dart';

/// Configuration for the session subsystem.
class SessionConfig {
  /// Local hour at which main, channel and cron sessions are archived and
  /// restarted under the same key. Negative disables the daily reset.
  final int resetHour;

  /// idleTimeoutMinutes.
  final int idleTimeoutMinutes;

  /// scopeConfig.
  final SessionScopeConfig scopeConfig;

  /// maintenanceConfig.
  final SessionMaintenanceConfig maintenanceConfig;

  /// Creates a [SessionConfig] value.
  const new({
    this.resetHour = 4,
    this.idleTimeoutMinutes = 0,
    this.scopeConfig = const SessionScopeConfig.defaults(),
    this.maintenanceConfig = const SessionMaintenanceConfig.defaults(),
  });

  /// Default configuration.
  const new defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionConfig &&
          resetHour == other.resetHour &&
          idleTimeoutMinutes == other.idleTimeoutMinutes &&
          scopeConfig == other.scopeConfig &&
          maintenanceConfig == other.maintenanceConfig;

  @override
  int get hashCode => Object.hash(resetHour, idleTimeoutMinutes, scopeConfig, maintenanceConfig);
}
