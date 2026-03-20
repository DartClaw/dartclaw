import '../scoping/session_scope_config.dart';
import 'session_maintenance_config.dart';

/// Configuration for the session subsystem.
class SessionConfig {
  final int resetHour;
  final int idleTimeoutMinutes;
  final SessionScopeConfig scopeConfig;
  final SessionMaintenanceConfig maintenanceConfig;

  const SessionConfig({
    this.resetHour = 4,
    this.idleTimeoutMinutes = 0,
    this.scopeConfig = const SessionScopeConfig.defaults(),
    this.maintenanceConfig = const SessionMaintenanceConfig.defaults(),
  });

  /// Default configuration.
  const SessionConfig.defaults() : this();
}
