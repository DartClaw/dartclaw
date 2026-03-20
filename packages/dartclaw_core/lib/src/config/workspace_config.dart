/// Configuration for the workspace subsystem.
class WorkspaceConfig {
  final bool gitSyncEnabled;
  final bool gitSyncPushEnabled;

  const WorkspaceConfig({
    this.gitSyncEnabled = true,
    this.gitSyncPushEnabled = true,
  });

  /// Default configuration.
  const WorkspaceConfig.defaults() : this();
}
