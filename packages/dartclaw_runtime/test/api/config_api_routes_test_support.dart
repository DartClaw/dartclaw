part of 'config_api_routes_test.dart';

ApiRouteTestClient api(Router router) => ApiRouteTestClient(router.call);

ApiRouteTestClient adminApi(Router router) =>
    ApiRouteTestClient((request) => router.call(withAdminAuthContext(request)));

/// The runtime state a router boots with, derived from its [DartclawConfig].
RuntimeConfig _runtimeFor(DartclawConfig cfg) => RuntimeConfig(
  heartbeatEnabled: cfg.scheduling.heartbeatEnabled,
  gitSyncEnabled: cfg.workspace.gitSyncEnabled,
  gitSyncPushEnabled: cfg.workspace.gitSyncPushEnabled,
);

/// Builds a [configApiRoutes] router whose [ConfigNotifier] throws on [reload].
/// Used to test the reloadable-fallback-to-pendingRestart path.
Router _buildRouterWithThrowingNotifier(String configPath, String dataDir) {
  final cfg = const DartclawConfig.defaults();
  final rc = _runtimeFor(cfg);
  return configApiRoutes(
    config: cfg,
    writer: ConfigWriter(configPath: configPath),
    validator: const ConfigValidator(),
    runtimeConfig: rc,
    dataDir: dataDir,
    configNotifier: _ThrowingConfigNotifier(cfg),
  );
}

/// [ConfigNotifier] subclass whose [reload] always throws.
class _ThrowingConfigNotifier extends ConfigNotifier {
  new(super.initial);

  @override
  ConfigDelta? reload(DartclawConfig newConfig) {
    throw StateError('simulated reload failure');
  }
}
