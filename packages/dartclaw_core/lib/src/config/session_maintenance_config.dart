/// Session maintenance configuration for lifecycle management.
///
/// Controls automatic session archival, count caps, cron retention,
/// and disk budget enforcement. Consumed by [SessionMaintenanceService].
library;

/// Maintenance execution mode.
enum MaintenanceMode {
  /// Log planned actions without applying changes.
  warn,

  /// Apply all maintenance actions.
  enforce;

  /// Parses a YAML string to [MaintenanceMode].
  ///
  /// Returns `null` for unknown values.
  static MaintenanceMode? fromYaml(String value) => switch (value) {
        'warn' => MaintenanceMode.warn,
        'enforce' => MaintenanceMode.enforce,
        _ => null,
      };

  /// Returns the YAML representation.
  String toYaml() => name;
}

/// Configuration for the session maintenance pipeline.
class SessionMaintenanceConfig {
  /// Maintenance mode: warn (dry-run) or enforce (apply).
  final MaintenanceMode mode;

  /// Archive sessions older than this many days. 0 = disabled.
  final int pruneAfterDays;

  /// Maximum number of active sessions. 0 = disabled.
  final int maxSessions;

  /// Maximum total disk usage in MB. 0 = disabled.
  final int maxDiskMb;

  /// Delete orphaned cron sessions older than this many hours. 0 = disabled.
  final int cronRetentionHours;

  /// Cron schedule for automated maintenance runs.
  final String schedule;

  const SessionMaintenanceConfig({
    this.mode = MaintenanceMode.warn,
    this.pruneAfterDays = 30,
    this.maxSessions = 500,
    this.maxDiskMb = 0,
    this.cronRetentionHours = 24,
    this.schedule = '0 3 * * *',
  });

  /// Default maintenance configuration.
  const SessionMaintenanceConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionMaintenanceConfig &&
          mode == other.mode &&
          pruneAfterDays == other.pruneAfterDays &&
          maxSessions == other.maxSessions &&
          maxDiskMb == other.maxDiskMb &&
          cronRetentionHours == other.cronRetentionHours &&
          schedule == other.schedule;

  @override
  int get hashCode => Object.hash(
        mode,
        pruneAfterDays,
        maxSessions,
        maxDiskMb,
        cronRetentionHours,
        schedule,
      );

  @override
  String toString() =>
      'SessionMaintenanceConfig(mode: $mode, pruneAfterDays: $pruneAfterDays, '
      'maxSessions: $maxSessions, maxDiskMb: $maxDiskMb, '
      'cronRetentionHours: $cronRetentionHours, schedule: $schedule)';
}
