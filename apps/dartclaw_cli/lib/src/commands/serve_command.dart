// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
import 'package:dartclaw_server/src/behavior/behavior_file_service.dart';
import 'package:dartclaw_server/src/behavior/self_improvement_service.dart';
import 'package:dartclaw_server/src/observability/usage_tracker.dart';
import 'package:dartclaw_server/src/workspace/workspace_service.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' show Handler;
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'config_loader.dart';
import 'service_wiring.dart';

typedef HarnessFactory =
    AgentHarness Function(
      String cwd, {
      String? claudeExecutable,
      Duration? turnTimeout,
      Future<Map<String, dynamic>> Function(Map<String, dynamic>)? onMemorySave,
      Future<Map<String, dynamic>> Function(Map<String, dynamic>)? onMemorySearch,
      Future<Map<String, dynamic>> Function(Map<String, dynamic>)? onMemoryRead,
      HarnessConfig? harnessConfig,
      ContainerManager? containerManager,
    });
typedef ServerFactory =
    DartclawServer Function({
      required SessionService sessions,
      required MessageService messages,
      required AgentHarness worker,
      required String staticDir,
      required BehaviorFileService behavior,
      MemoryFileService? memoryFile,
      SessionService? sessionsForTurns,
      GuardChain? guardChain,
      KvService? kv,
      HealthService? healthService,
      TokenService? tokenService,
      SessionLockManager? lockManager,
      SessionResetService? resetService,
      ContextMonitor? contextMonitor,
      ResultTrimmer? resultTrimmer,
      ChannelManager? channelManager,
      WhatsAppChannel? whatsAppChannel,
      GoogleChatWebhookHandler? googleChatWebhookHandler,
      SignalChannel? signalChannel,
      String? webhookSecret,
      MessageRedactor? redactor,
      String? gatewayToken,
      SelfImprovementService? selfImprovement,
      UsageTracker? usageTracker,
      EventBus? eventBus,
      bool authEnabled,
      HarnessPool? pool,
      ContentGuardDisplayParams contentGuardDisplay,
      HeartbeatDisplayParams heartbeatDisplay,
      SchedulingDisplayParams schedulingDisplay,
      WorkspaceDisplayParams workspaceDisplay,
      AppDisplayParams appDisplay,
    });
typedef ServeFn = Future<HttpServer> Function(Handler handler, Object address, int port);
typedef WriteLine = void Function(String line);
typedef ExitFn = Never Function(int code);

/// Starts the DartClaw HTTP server with web UI.
class ServeCommand extends Command<void> {
  final DartclawConfig? _config;
  final SearchDbFactory _searchDbFactory;
  final TaskDbFactory _taskDbFactory;
  final HarnessFactory _harnessFactory;
  final ServerFactory _serverFactory;
  final ServeFn _serveFn;
  final WriteLine _stderrLine;
  final ExitFn _exitFn;
  static final _log = Logger('ServeCommand');

  @override
  String get name => 'serve';

  @override
  String get description => 'Start the DartClaw HTTP server';

  ServeCommand({
    DartclawConfig? config,
    SearchDbFactory? searchDbFactory,
    TaskDbFactory? taskDbFactory,
    HarnessFactory? harnessFactory,
    ServerFactory? serverFactory,
    ServeFn? serveFn,
    WriteLine? stderrLine,
    ExitFn? exitFn,
  }) : _config = config,
       _searchDbFactory = searchDbFactory ?? openSearchDb,
       _taskDbFactory = taskDbFactory ?? openTaskDb,
       _harnessFactory =
           harnessFactory ??
           ((
             cwd, {
             claudeExecutable,
             turnTimeout,
             onMemorySave,
             onMemorySearch,
             onMemoryRead,
             harnessConfig,
             containerManager,
           }) => ClaudeCodeHarness(
             claudeExecutable: claudeExecutable ?? 'claude',
             cwd: cwd,
             turnTimeout: turnTimeout ?? const Duration(seconds: 600),
             onMemorySave: onMemorySave,
             onMemorySearch: onMemorySearch,
             onMemoryRead: onMemoryRead,
             harnessConfig: harnessConfig ?? const HarnessConfig(),
             containerManager: containerManager,
           )),
       _serverFactory =
           serverFactory ??
           (({
             required sessions,
             required messages,
             required worker,
             required staticDir,
             required behavior,
             memoryFile,
             sessionsForTurns,
             guardChain,
             kv,
             healthService,
             tokenService,
             lockManager,
             resetService,
             contextMonitor,
             resultTrimmer,
             channelManager,
             whatsAppChannel,
             googleChatWebhookHandler,
             signalChannel,
             webhookSecret,
             redactor,
             gatewayToken,
             selfImprovement,
             usageTracker,
             eventBus,
             authEnabled = true,
             pool,
             contentGuardDisplay = const ContentGuardDisplayParams(),
             heartbeatDisplay = const HeartbeatDisplayParams(),
             schedulingDisplay = const SchedulingDisplayParams(),
             workspaceDisplay = const WorkspaceDisplayParams(),
             appDisplay = const AppDisplayParams(),
           }) => DartclawServer(
             sessions: sessions,
             messages: messages,
             worker: worker,
             staticDir: staticDir,
             behavior: behavior,
             memoryFile: memoryFile,
             guardChain: guardChain,
             kv: kv,
             healthService: healthService,
             tokenService: tokenService,
             lockManager: lockManager,
             resetService: resetService,
             contextMonitor: contextMonitor,
             resultTrimmer: resultTrimmer,
             channelManager: channelManager,
             whatsAppChannel: whatsAppChannel,
             googleChatWebhookHandler: googleChatWebhookHandler,
             signalChannel: signalChannel,
             webhookSecret: webhookSecret,
             redactor: redactor,
             gatewayToken: gatewayToken,
             selfImprovement: selfImprovement,
             usageTracker: usageTracker,
             eventBus: eventBus,
             authEnabled: authEnabled,
             pool: pool,
             contentGuardDisplay: contentGuardDisplay,
             heartbeatDisplay: heartbeatDisplay,
             schedulingDisplay: schedulingDisplay,
             workspaceDisplay: workspaceDisplay,
             appDisplay: appDisplay,
           )),
       _serveFn = serveFn ?? ((handler, address, port) => shelf_io.serve(handler, address, port)),
       _stderrLine = stderrLine ?? stderr.writeln,
       _exitFn = exitFn ?? exit {
    argParser
      ..addOption('port', abbr: 'p', defaultsTo: '3000', help: 'Port to listen on')
      ..addOption('host', abbr: 'H', defaultsTo: 'localhost', help: 'Host to bind to')
      ..addOption('data-dir', help: 'Data directory path')
      ..addOption('static-dir', help: 'Static assets directory path')
      ..addOption('worker-timeout', help: 'Worker timeout in seconds')
      ..addOption('claude-executable', help: 'Path to claude binary (default: claude)')
      ..addOption('log-format', allowed: ['human', 'json'], defaultsTo: 'human', help: 'Log output format')
      ..addOption('log-file', help: 'Write logs to file (in addition to stderr)')
      ..addOption(
        'log-level',
        allowed: ['FINE', 'INFO', 'WARNING', 'SEVERE'],
        defaultsTo: 'INFO',
        help: 'Minimum log level',
      )
      ..addFlag('dev', negatable: false, help: 'Enable dev mode (template hot-reload)');
  }

  @override
  Future<void> run() async {
    // Validate raw CLI port early (before config loading)
    if (_config == null) {
      final portStr = argResults!['port'] as String;
      final rawPort = int.tryParse(portStr);
      if (rawPort == null || rawPort < 1 || rawPort > 65535) {
        throw UsageException('Invalid port: $portStr (must be 1-65535)', usage);
      }
    }

    // Build config: injected > CLI+YAML+defaults
    final config =
        _config ??
        loadCliConfig(
          configPath: globalResults?['config'] as String?,
          cliOverrides: {
            if (argResults!.wasParsed('port')) 'port': argResults!['port'] as String,
            if (argResults!.wasParsed('host')) 'host': argResults!['host'] as String,
            if (argResults!.wasParsed('data-dir')) 'data_dir': argResults!['data-dir'] as String,
            if (argResults!.wasParsed('worker-timeout')) 'worker_timeout': argResults!['worker-timeout'] as String,
            if (argResults!.wasParsed('static-dir')) 'static_dir': argResults!['static-dir'] as String,
            if (argResults!.wasParsed('claude-executable'))
              'claude_executable': argResults!['claude-executable'] as String,
            if (argResults!['dev'] == true) 'dev_mode': 'true',
          },
        );

    for (final w in config.warnings) {
      _stderrLine('WARNING: $w');
    }

    final host = config.host;
    final port = config.port;

    // Warn about network exposure
    if (host == '0.0.0.0') {
      _stderrLine(
        'WARNING: Binding to 0.0.0.0 exposes the server to the network. '
        'Ensure gateway auth is enabled (gateway.auth_mode: token).',
      );
    }

    // Resolve config file path for ConfigWriter (same resolution as DartclawConfig.load).
    // If no config file exists, create a default empty one so ConfigWriter (and
    // the config API routes that depend on it) can operate.
    var resolvedConfigPath = _resolveConfigPath(globalResults?['config'] as String?);
    if (resolvedConfigPath == null) {
      final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
      final defaultPath = p.join(home, '.dartclaw', 'dartclaw.yaml');
      final defaultDir = Directory(p.dirname(defaultPath));
      if (!defaultDir.existsSync()) defaultDir.createSync(recursive: true);
      File(defaultPath).writeAsStringSync('# DartClaw configuration\n');
      resolvedConfigPath = defaultPath;
    }

    // Ensure data directory exists
    final dataDir = config.dataDir;
    try {
      final dir = Directory(dataDir);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
    } on FileSystemException {
      _stderrLine('ERROR: Cannot write to data directory at $dataDir');
      _exitFn(1);
    }

    // Load and validate HTML templates
    try {
      initTemplates(config.templatesDir, devMode: config.devMode);
    } on StateError catch (e) {
      _stderrLine('ERROR: ${e.message}');
      _exitFn(1);
    }

    // Workspace migration + scaffold (before any service init)
    final workspace = WorkspaceService(dataDir: dataDir);
    try {
      await workspace.migrate();
    } on WorkspaceMigrationException catch (e) {
      _stderrLine('ERROR: Migration failed: $e');
      _exitFn(1);
    }
    await workspace.scaffold();

    // Ensure logs directory exists and generate sample rotation configs
    final logsDir = Directory(config.logsDir);
    if (!logsDir.existsSync()) {
      logsDir.createSync(recursive: true);
    }
    ServiceWiring.writeLogRotationSamples(logsDir.path);

    // Configure structured logging
    // CLI flags override config values only when config was not injected.
    T cliOr<T>(String flag, T configValue) =>
        _config == null && argResults!.wasParsed(flag) ? argResults![flag] as T : configValue;

    final logFormat = cliOr('log-format', config.logFormat);
    final logFile = cliOr<String?>('log-file', config.logFile);
    final logLevel = cliOr('log-level', config.logLevel);

    final messageRedactor = MessageRedactor(extraPatterns: config.redactPatterns);
    final logRedactor = LogRedactor(redactor: messageRedactor);
    final logService = LogService.fromConfig(
      format: logFormat,
      logFile: logFile,
      level: logLevel,
      redactor: logRedactor,
    );
    logService.install();

    StreamSubscription<ProcessSignal>? sigintSub;
    StreamSubscription<ProcessSignal>? sigtermSub;
    try {
      // Wire all services
      final wiring = ServiceWiring(
        config: config,
        dataDir: dataDir,
        port: port,
        harnessFactory: _harnessFactory,
        serverFactory: _serverFactory,
        searchDbFactory: _searchDbFactory,
        taskDbFactory: _taskDbFactory,
        stderrLine: _stderrLine,
        exitFn: _exitFn,
        resolvedConfigPath: resolvedConfigPath,
        logService: logService,
        messageRedactor: messageRedactor,
      );
      final result = await wiring.wire();

      // Start HTTP server (handler built here — services are set above)
      late HttpServer httpServer;
      try {
        httpServer = await _serveFn(result.server.handler, host, port);
      } on SocketException catch (_) {
        _log.severe(
          'Cannot bind to $host:$port — is another process already '
          'using this port? Try: lsof -ti :$port | xargs kill',
        );
        await ServiceWiring.teardown(result.server, result.searchDb, result.harness, result.taskService);
        await result.shutdownExtras();
        _exitFn(1);
      }

      if (stderr.hasTerminal) {
        _stderrLine(
          startupBanner(
            host: host,
            port: port,
            name: config.name,
            token: result.tokenService?.token,
            authEnabled: result.authEnabled,
            guardsEnabled: config.guards.enabled,
            containerEnabled: config.containerConfig.enabled,
            channels: [
              if (config.channelConfig.channelConfigs['whatsapp']?['enabled'] == true) 'WhatsApp',
              if (config.channelConfig.channelConfigs['signal']?['enabled'] == true) 'Signal',
            ],
            colorize: true,
          ),
        );
      } else {
        _log.info('${config.name} v$dartclawVersion listening on http://$host:$port');
      }
      result.resetService.start();

      // Connect channels
      if (result.channelManager != null) {
        await result.channelManager!.connectAll();
      }

      // Shutdown machinery
      final shutdownCompleter = Completer<void>();
      var shuttingDown = false;

      Future<void> shutdown() async {
        if (shuttingDown) return;
        shuttingDown = true;
        _stderrLine('Shutting down...');

        try {
          await Future(() async {
            result.heartbeat?.stop();
            await Future.wait([httpServer.close(), result.server.shutdown()]);
            result.scheduleService?.stop();
            result.resetService.dispose();
            await result.kvService.dispose();
            await result.selfImprovement.dispose();
            await result.taskService.dispose();
            await result.eventBus.dispose();
            await result.qmdManager?.stop();
            await result.shutdownExtras();
            result.searchDb.close();
            _stderrLine('Shutdown complete');
          }).timeout(const Duration(seconds: 10));
        } on TimeoutException {
          _stderrLine('Shutdown timed out, forcing exit');
          _exitFn(1);
        } catch (e) {
          _log.severe('Shutdown error: $e');
        }

        if (!shutdownCompleter.isCompleted) shutdownCompleter.complete();
      }

      // Register signal handlers
      sigintSub = ProcessSignal.sigint.watch().listen((_) => unawaited(shutdown()));
      if (!Platform.isWindows) {
        sigtermSub = ProcessSignal.sigterm.watch().listen((_) => unawaited(shutdown()));
      }

      // Keep process alive until shutdown completes
      await shutdownCompleter.future;
    } finally {
      await sigintSub?.cancel();
      await sigtermSub?.cancel();
      await logService.dispose();
    }
  }
}

/// Resolves the config file path using the same search order as
/// [DartclawConfig.load]: `--config` > `DARTCLAW_CONFIG` env > CWD >
/// `~/.dartclaw/dartclaw.yaml`.
///
/// Returns null if no config file is found (server runs with defaults only).
String? _resolveConfigPath(String? cliConfigPath) {
  if (cliConfigPath != null) {
    return File(cliConfigPath).existsSync() ? cliConfigPath : null;
  }
  final envPath = Platform.environment['DARTCLAW_CONFIG'];
  if (envPath != null) {
    return File(envPath).existsSync() ? envPath : null;
  }
  if (File('dartclaw.yaml').existsSync()) return 'dartclaw.yaml';
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
  final homePath = p.join(home, '.dartclaw', 'dartclaw.yaml');
  if (File(homePath).existsSync()) return homePath;
  return null;
}

/// Returns built-in tool names to suppress when the MCP server is active.
///
/// `WebFetch` is always suppressed when MCP is enabled (replaced by the
/// `web_fetch` MCP tool which includes ContentGuard scanning).
/// `WebSearch` is only suppressed when at least one search provider is
/// configured — otherwise the agent loses search capability entirely.
List<String> mcpDisallowedTools({
  required bool mcpEnabled,
  required bool searchEnabled,
  required List<String> userDisallowed,
}) {
  return [...userDisallowed, if (mcpEnabled) 'WebFetch', if (mcpEnabled && searchEnabled) 'WebSearch'];
}
