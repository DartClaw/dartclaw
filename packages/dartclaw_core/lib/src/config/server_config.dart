/// Configuration for the server subsystem.
class ServerConfig {
  final int port;
  final String host;
  final String name;
  final String dataDir;
  final String? baseUrl;
  final int workerTimeout;
  final String claudeExecutable;
  final String staticDir;
  final String templatesDir;
  final bool devMode;
  final int maxParallelTurns;

  const ServerConfig({
    this.port = 3000,
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
