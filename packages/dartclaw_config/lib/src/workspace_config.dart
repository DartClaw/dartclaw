/// Configuration for the workspace subsystem.
class WorkspaceConfig {
  /// gitSyncEnabled.
  final bool gitSyncEnabled;

  /// gitSyncPushEnabled.
  final bool gitSyncPushEnabled;

  /// const WorkspaceConfig({this.gitSyncEnabled = true, this.gitS.
  const new({this.gitSyncEnabled = true, this.gitSyncPushEnabled = true});

  /// Default configuration.
  const new defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WorkspaceConfig &&
          gitSyncEnabled == other.gitSyncEnabled &&
          gitSyncPushEnabled == other.gitSyncPushEnabled;

  @override
  int get hashCode => Object.hash(gitSyncEnabled, gitSyncPushEnabled);
}
