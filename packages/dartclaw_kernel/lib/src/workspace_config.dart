/// Configuration for the workspace subsystem.
class WorkspaceConfig {
  /// gitSyncEnabled.
  final bool gitSyncEnabled;

  /// gitSyncPushEnabled.
  final bool gitSyncPushEnabled;

  /// Minutes between workspace git-sync runs.
  ///
  /// Git sync owns its own schedule; it no longer rides the heartbeat cycle.
  final int gitSyncIntervalMinutes;

  /// Creates a [WorkspaceConfig] value.
  const new({this.gitSyncEnabled = true, this.gitSyncPushEnabled = true, this.gitSyncIntervalMinutes = 30});

  /// Default configuration.
  const new defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WorkspaceConfig &&
          gitSyncEnabled == other.gitSyncEnabled &&
          gitSyncPushEnabled == other.gitSyncPushEnabled &&
          gitSyncIntervalMinutes == other.gitSyncIntervalMinutes;

  @override
  int get hashCode => Object.hash(gitSyncEnabled, gitSyncPushEnabled, gitSyncIntervalMinutes);
}
