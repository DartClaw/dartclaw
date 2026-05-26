import 'package:dartclaw_models/dartclaw_models.dart' show SessionScopeConfig;
import 'session_maintenance_config.dart';

/// Configuration for the session subsystem.
class SessionConfig {
  /// resetHour.
  final int resetHour;

  /// idleTimeoutMinutes.
  final int idleTimeoutMinutes;

  /// scopeConfig.
  final SessionScopeConfig scopeConfig;

  /// maintenanceConfig.
  final SessionMaintenanceConfig maintenanceConfig;

  /// Creates a [SessionConfig] value.
  const SessionConfig({
    this.resetHour = 4,
    this.idleTimeoutMinutes = 0,
    this.scopeConfig = const SessionScopeConfig.defaults(),
    this.maintenanceConfig = const SessionMaintenanceConfig.defaults(),
  });

  /// Default configuration.
  const SessionConfig.defaults() : this();

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
