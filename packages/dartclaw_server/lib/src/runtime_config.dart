/// Tracks runtime toggle overrides for services that support start/stop.
///
/// All state is ephemeral — lost on process restart. This is the single
/// source of truth for the web UI's toggle switches.
class RuntimeConfig {
  bool heartbeatEnabled;
  bool gitSyncEnabled;
  bool gitSyncPushEnabled;

  RuntimeConfig({required this.heartbeatEnabled, required this.gitSyncEnabled, this.gitSyncPushEnabled = true});

  Map<String, dynamic> toJson() => {
    'heartbeat': {'enabled': heartbeatEnabled},
    'gitSync': {'enabled': gitSyncEnabled, 'pushEnabled': gitSyncPushEnabled},
  };
}
