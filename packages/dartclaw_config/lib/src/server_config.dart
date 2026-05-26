/// Configuration for the server subsystem.
class ServerConfig {
  /// port.
  final int port;

  /// host.
  final String host;

  /// name.
  final String name;

  /// dataDir.
  final String dataDir;

  /// baseUrl.
  final String? baseUrl;

  /// workerTimeout.
  final int workerTimeout;

  /// claudeExecutable.
  final String claudeExecutable;

  /// staticDir.
  final String staticDir;

  /// templatesDir.
  final String templatesDir;

  /// devMode.
  final bool devMode;

  /// maxParallelTurns.
  final int maxParallelTurns;

  /// Creates a [ServerConfig] value.
  const ServerConfig({
    this.port = 3333,
    this.host = 'localhost',
    this.name = 'DartClaw',
    this.dataDir = '~/.dartclaw',
    this.baseUrl,
    this.workerTimeout = 600,
    this.claudeExecutable = 'claude',
    this.staticDir = 'packages/dartclaw_server/lib/src/static',
    this.templatesDir = 'packages/dartclaw_server/lib/src/templates',
    this.devMode = false,
    this.maxParallelTurns = 3,
  });

  /// Default configuration.
  const ServerConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ServerConfig &&
          port == other.port &&
          host == other.host &&
          name == other.name &&
          dataDir == other.dataDir &&
          baseUrl == other.baseUrl &&
          workerTimeout == other.workerTimeout &&
          claudeExecutable == other.claudeExecutable &&
          staticDir == other.staticDir &&
          templatesDir == other.templatesDir &&
          devMode == other.devMode &&
          maxParallelTurns == other.maxParallelTurns;

  @override
  int get hashCode => Object.hash(
    port,
    host,
    name,
    dataDir,
    baseUrl,
    workerTimeout,
    claudeExecutable,
    staticDir,
    templatesDir,
    devMode,
    maxParallelTurns,
  );
}
