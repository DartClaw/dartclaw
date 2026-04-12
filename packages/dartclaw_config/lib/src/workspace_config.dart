/// Configuration for the workspace subsystem.
class WorkspaceConfig {
  final bool gitSyncEnabled;
  final bool gitSyncPushEnabled;

  const WorkspaceConfig({this.gitSyncEnabled = true, this.gitSyncPushEnabled = true});

  /// Default configuration.
  const WorkspaceConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WorkspaceConfig &&
          gitSyncEnabled == other.gitSyncEnabled &&
          gitSyncPushEnabled == other.gitSyncPushEnabled;

  @override
  int get hashCode => Object.hash(gitSyncEnabled, gitSyncPushEnabled);
}
