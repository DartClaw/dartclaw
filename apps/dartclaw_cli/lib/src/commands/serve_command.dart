import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' show Handler;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:sqlite3/sqlite3.dart';

typedef HarnessFactory =
    AgentHarness Function(
      String cwd, {
      String? claudeExecutable,
      Duration? turnTimeout,
      Future<Map<String, dynamic>> Function(Map<String, dynamic>)? onMemorySave,
      Future<Map<String, dynamic>> Function(Map<String, dynamic>)? onMemorySearch,
      Future<Map<String, dynamic>> Function(Map<String, dynamic>)? onMemoryRead,
      HarnessConfig? harnessConfig,
    });
typedef ServerFactory =
    DartclawServer Function({
      required SessionService sessions,
      required MessageService messages,
      required AgentHarness worker,
      required String staticDir,
      required BehaviorFileService behavior,
      MemoryFileService? memoryFile,
      GuardChain? guardChain,
      KvService? kv,
      HealthService? healthService,
      TokenService? tokenService,
      SessionStore? sessionStore,
      SessionLockManager? lockManager,
      SessionResetService? resetService,
      ContextMonitor? contextMonitor,
      ResultTrimmer? resultTrimmer,
      ChannelManager? channelManager,
      WhatsAppChannel? whatsAppChannel,
      bool authEnabled,
    });
typedef ServeFn = Future<HttpServer> Function(Handler handler, Object address, int port);
typedef WriteLine = void Function(String line);
typedef ExitFn = Never Function(int code);

/// Starts the DartClaw HTTP server with web UI.
class ServeCommand extends Command<void> {
  final DartclawConfig? _config;
  final SearchDbFactory _searchDbFactory;
  final HarnessFactory _harnessFactory;
  final ServerFactory _serverFactory;
  final ServeFn _serveFn;
  final WriteLine _stdoutLine;
  final WriteLine _stderrLine;
  final ExitFn _exitFn;

  @override
  String get name => 'serve';

  @override
  String get description => 'Start the DartClaw HTTP server';

  ServeCommand({
    DartclawConfig? config,
    SearchDbFactory? searchDbFactory,
    HarnessFactory? harnessFactory,
    ServerFactory? serverFactory,
    ServeFn? serveFn,
    WriteLine? stdoutLine,
    WriteLine? stderrLine,
    ExitFn? exitFn,
  }) : _config = config,
       _searchDbFactory = searchDbFactory ?? openSearchDb,
       _harnessFactory =
           harnessFactory ??
           ((cwd, {claudeExecutable, turnTimeout, onMemorySave, onMemorySearch, onMemoryRead, harnessConfig}) => ClaudeCodeHarness(
             claudeExecutable: claudeExecutable ?? 'claude',
             cwd: cwd,
             turnTimeout: turnTimeout ?? const Duration(seconds: 600),
             onMemorySave: onMemorySave,
             onMemorySearch: onMemorySearch,
             onMemoryRead: onMemoryRead,
             harnessConfig: harnessConfig ?? const HarnessConfig(),
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
             guardChain,
             kv,
             healthService,
             tokenService,
             sessionStore,
             lockManager,
             resetService,
             contextMonitor,
             resultTrimmer,
             channelManager,
             whatsAppChannel,
             authEnabled = true,
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
             sessionStore: sessionStore,
             lockManager: lockManager,
             resetService: resetService,
             contextMonitor: contextMonitor,
             resultTrimmer: resultTrimmer,
             channelManager: channelManager,
             whatsAppChannel: whatsAppChannel,
             authEnabled: authEnabled,
           )),
       _serveFn = serveFn ?? ((handler, address, port) => shelf_io.serve(handler, address, port)),
       _stdoutLine = stdoutLine ?? stdout.writeln,
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
      ..addOption('log-level', allowed: ['FINE', 'INFO', 'WARNING', 'SEVERE'], defaultsTo: 'INFO', help: 'Minimum log level');
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
        DartclawConfig.load(
          configPath: globalResults?['config'] as String?,
          cliOverrides: {
            if (argResults!.wasParsed('port')) 'port': argResults!['port'] as String,
            if (argResults!.wasParsed('host')) 'host': argResults!['host'] as String,
            if (argResults!.wasParsed('data-dir')) 'data_dir': argResults!['data-dir'] as String,
            if (argResults!.wasParsed('worker-timeout')) 'worker_timeout': argResults!['worker-timeout'] as String,
            if (argResults!.wasParsed('static-dir')) 'static_dir': argResults!['static-dir'] as String,
            if (argResults!.wasParsed('claude-executable'))
              'claude_executable': argResults!['claude-executable'] as String,
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

    // Ensure data directory exists
    final dataDir = config.dataDir;
    try {
      final dir = Directory(dataDir);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
    } on FileSystemException {
      _stderrLine('Error: Cannot write to data directory at $dataDir');
      _exitFn(1);
    }

    // Workspace migration + scaffold (before any service init)
    final workspace = WorkspaceService(dataDir: dataDir);
    try {
      await workspace.migrate();
    } on WorkspaceMigrationException catch (e) {
      _stderrLine('Error: Migration failed: $e');
      _exitFn(1);
    }
    await workspace.scaffold();

    // Ensure logs directory exists and generate sample rotation configs
    final logsDir = Directory(config.logsDir);
    if (!logsDir.existsSync()) {
      logsDir.createSync(recursive: true);
    }
    _writeLogRotationSamples(logsDir.path);

    // Configure structured logging
    final logFormat = _config == null && argResults!.wasParsed('log-format')
        ? argResults!['log-format'] as String
        : config.logFormat;
    final logFile = _config == null && argResults!.wasParsed('log-file')
        ? argResults!['log-file'] as String?
        : config.logFile;
    final logLevel = _config == null && argResults!.wasParsed('log-level')
        ? argResults!['log-level'] as String
        : config.logLevel;

    final logService = LogService.fromConfig(
      format: logFormat,
      logFile: logFile,
      level: logLevel,
      redactPatterns: config.redactPatterns,
    );
    logService.install();

    Database? searchDb;
    AgentHarness? harness;
    DartclawServer? server;
    StreamSubscription<ProcessSignal>? sigintSub;
    StreamSubscription<ProcessSignal>? sigtermSub;
    try {
      // Construct file-based services
      Directory(config.sessionsDir).createSync(recursive: true);

      final sessions = SessionService(baseDir: config.sessionsDir);
      final messages = MessageService(baseDir: config.sessionsDir);

      // Ensure main session exists on startup
      await sessions.getOrCreateMain();

      // Search DB
      try {
        searchDb = _searchDbFactory(config.searchDbPath);
      } catch (_) {
        _stderrLine('Error: Cannot open search database at ${config.searchDbPath}');
        _exitFn(1);
      }

      // Memory stack (MEMORY.md now lives in workspace/)
      final memoryFile = MemoryFileService(baseDir: config.workspaceDir);
      final memory = MemoryService(searchDb);
      final handlers = createMemoryHandlers(memory: memory, memoryFile: memoryFile);

      final harnessConfig = HarnessConfig(
        disallowedTools: config.agentDisallowedTools,
        maxTurns: config.agentMaxTurns,
        model: config.agentModel,
        agents: config.agentAgents,
        context1m: config.agentContext1m,
      );

      harness = _harnessFactory(
        Directory.current.path,
        claudeExecutable: config.claudeExecutable,
        turnTimeout: Duration(seconds: config.workerTimeout),
        onMemorySave: handlers.onSave,
        onMemorySearch: handlers.onSearch,
        onMemoryRead: handlers.onRead,
        harnessConfig: harnessConfig,
      );
      try {
        await harness.start();
      } catch (e) {
        _stderrLine('Error: Failed to start harness: $e');
        await memoryFile.dispose();
        await _teardown(null, searchDb, harness);
        _exitFn(1);
      }

      final behavior = BehaviorFileService(
        workspaceDir: config.workspaceDir,
        projectDir: p.join(Directory.current.path, '.dartclaw'),
        maxMemoryBytes: config.memoryMaxBytes,
      );

      // Construct guard chain with per-guard YAML configs
      final guardChain = config.guards.enabled
          ? GuardChain(
              failOpen: config.guards.failOpen,
              guards: [
                CommandGuard(
                  config: config.guardsYaml['command'] is Map
                      ? CommandGuardConfig.fromYaml(
                          Map<String, dynamic>.from(config.guardsYaml['command'] as Map))
                      : CommandGuardConfig.defaults(),
                ),
                FileGuard(
                  config: (config.guardsYaml['file'] is Map
                          ? FileGuardConfig.fromYaml(
                              Map<String, dynamic>.from(config.guardsYaml['file'] as Map))
                          : FileGuardConfig.defaults())
                      .withSelfProtection(p.join(dataDir, 'dartclaw.yaml')),
                ),
                NetworkGuard(
                  config: config.guardsYaml['network'] is Map
                      ? NetworkGuardConfig.fromYaml(
                          Map<String, dynamic>.from(config.guardsYaml['network'] as Map))
                      : NetworkGuardConfig.defaults(),
                ),
              ],
              auditLogger: GuardAuditLogger(),
            )
          : null;

      // KV store for per-session cost tracking
      final kvService = KvService(filePath: config.kvPath);

      // Health service
      final startedSearchDb = searchDb;
      final startedHarness = harness;
      final healthService = HealthService(
        worker: startedHarness,
        searchDbPath: config.searchDbPath,
        sessionsDir: config.sessionsDir,
      );

      // Gateway auth
      final authEnabled = config.gatewayAuthMode != 'none';
      TokenService? tokenService;
      SessionStore? sessionStore;

      if (authEnabled) {
        final existingToken = config.gatewayToken ?? TokenService.loadFromFile(dataDir);
        if (existingToken != null) {
          tokenService = TokenService(token: existingToken);
        } else {
          tokenService = TokenService();
          TokenService.persistToFile(dataDir, tokenService.token);
        }
        sessionStore = SessionStore();
      } else {
        final isLoopback = host == 'localhost' || host == '127.0.0.1';
        if (isLoopback) {
          Logger('ServeCommand').warning('Auth disabled on loopback — acceptable for local dev only');
        } else {
          Logger('ServeCommand').severe('CRITICAL: Auth disabled on network-accessible host $host');
        }
      }

      // Context management
      final contextMonitor = ContextMonitor(reserveTokens: config.contextReserveTokens);
      final resultTrimmer = ResultTrimmer(maxBytes: config.contextMaxResultBytes);

      // Concurrency + reset
      final lockManager = SessionLockManager(maxParallel: config.maxParallelTurns);
      final resetService = SessionResetService(
        sessions: sessions,
        messages: messages,
        resetHour: config.sessionResetHour,
        idleTimeoutMinutes: config.sessionIdleTimeoutMinutes,
      );

      // Container isolation (CR-03): validate config at startup
      if (config.containerConfig.enabled) {
        final validationErrors = DockerValidator.validate(config.containerConfig);
        if (validationErrors.isNotEmpty) {
          for (final err in validationErrors) {
            _stderrLine('Error: Container config rejected: $err');
          }
          _exitFn(1);
        }
        // ContainerManager will be instantiated by the harness when spawning agent processes
        Logger('ServeCommand').info('Container isolation enabled (image: ${config.containerConfig.image})');
      } else {
        Logger('ServeCommand').warning(
          'Container isolation disabled — agent has full host access. '
          'Guards are the only security boundary. '
          'Enable container isolation for production use (see docs/guide/security.md).',
        );
      }

      // Channel + message queue (H-01: S14-S15 wiring)
      ChannelManager? channelManager;
      WhatsAppChannel? whatsAppChannel;
      final waConfig = config.channelConfig.channelConfigs['whatsapp'];
      if (waConfig != null && waConfig['enabled'] == true) {
        final messageQueue = MessageQueue(
          debounceWindow: config.channelConfig.debounceWindow,
          maxConcurrentTurns: config.maxParallelTurns,
          maxQueueDepth: config.channelConfig.maxQueueDepth,
          defaultRetryPolicy: config.channelConfig.defaultRetryPolicy,
          dispatcher: (sessionKey, message, {String? senderJid}) async {
            final session = await sessions.getOrCreateByKey(sessionKey, type: SessionType.channel);
            final userMsg = <String, dynamic>{'role': 'user', 'content': message};
            final turnId = await server!.turns.startTurn(session.id, [userMsg]);
            final outcome = await server.turns.waitForOutcome(session.id, turnId);
            return outcome.status == TurnStatus.completed ? 'OK' : 'Failed: ${outcome.errorMessage}';
          },
        );
        channelManager = ChannelManager(queue: messageQueue, config: config.channelConfig);

        try {
          final warns = <String>[];
          final parsedConfig = WhatsAppConfig.fromYaml(waConfig, warns);
          for (final w in warns) {
            Logger('ServeCommand').warning('WhatsApp config: $w');
          }
          final gowaManager = GowaManager(
            executable: parsedConfig.gowaExecutable,
            host: parsedConfig.gowaHost,
            port: parsedConfig.gowaPort,
          );
          final waChannel = WhatsAppChannel(
            gowa: gowaManager,
            config: parsedConfig,
            dmAccess: DmAccessController(
              mode: parsedConfig.dmAccess,
              allowlist: parsedConfig.dmAllowlist.toSet(),
            ),
            mentionGating: MentionGating(
              requireMention: parsedConfig.requireMention,
              mentionPatterns: parsedConfig.mentionPatterns,
              ownJid: '', // Set after GOWA connects and provides own JID
            ),
            channelManager: channelManager,
            workspaceDir: config.workspaceDir,
          );
          channelManager.registerChannel(waChannel);
          whatsAppChannel = waChannel;
          Logger('ServeCommand').info('WhatsApp channel registered');
        } catch (e) {
          Logger('ServeCommand').warning('Failed to initialize WhatsApp channel: $e');
        }
      }

      server = _serverFactory(
        sessions: sessions,
        messages: messages,
        worker: startedHarness,
        staticDir: config.staticDir,
        behavior: behavior,
        memoryFile: memoryFile,
        guardChain: guardChain,
        kv: kvService,
        healthService: healthService,
        tokenService: tokenService,
        sessionStore: sessionStore,
        lockManager: lockManager,
        resetService: resetService,
        contextMonitor: contextMonitor,
        resultTrimmer: resultTrimmer,
        channelManager: channelManager,
        whatsAppChannel: whatsAppChannel,
        authEnabled: authEnabled,
      );

      // Parse scheduled jobs from config
      final scheduledJobs = <ScheduledJob>[];
      for (final jobConfig in config.schedulingJobs) {
        try {
          scheduledJobs.add(ScheduledJob.fromConfig(jobConfig));
        } catch (e) {
          Logger('ServeCommand').warning('Invalid scheduled job config: $e — skipping');
        }
      }

      // Start HTTP server
      late HttpServer httpServer;
      try {
        httpServer = await _serveFn(server.handler, host, port);
      } on SocketException catch (_) {
        _stderrLine('Error: Cannot bind to $host:$port');
        await _teardown(server, searchDb, harness);
        _exitFn(1);
      }

      _stdoutLine('Listening on http://$host:$port');
      if (tokenService != null) {
        _stdoutLine('Web UI: http://$host:$port/?token=${tokenService.token}');
      }
      resetService.start();

      // Start cron scheduler
      ScheduleService? scheduleService;
      if (scheduledJobs.isNotEmpty) {
        scheduleService = ScheduleService(
          turns: server.turns,
          sessions: sessions,
          jobs: scheduledJobs,
        );
        scheduleService.start();
      }

      // Workspace git sync (H-01: S17 wiring)
      WorkspaceGitSync? gitSync;
      if (config.gitSyncEnabled) {
        gitSync = WorkspaceGitSync(
          workspaceDir: config.workspaceDir,
          pushEnabled: config.gitSyncPushEnabled,
        );
        if (await gitSync.isGitAvailable()) {
          await gitSync.initIfNeeded();
          Logger('ServeCommand').info('Workspace git sync enabled');
        } else {
          gitSync = null;
        }
      }

      // Heartbeat scheduler (H-01: S16 wiring)
      HeartbeatScheduler? heartbeat;
      if (config.heartbeatEnabled) {
        heartbeat = HeartbeatScheduler(
          interval: Duration(minutes: config.heartbeatIntervalMinutes),
          workspaceDir: config.workspaceDir,
          dispatch: (sessionKey, message) async {
            final session = await sessions.getOrCreateByKey(sessionKey, type: SessionType.cron);
            final userMsg = <String, dynamic>{'role': 'user', 'content': message};
            await server!.turns.startTurn(session.id, [userMsg]);
          },
          gitSync: gitSync,
        );
        heartbeat.start();
        Logger('ServeCommand').info('Heartbeat scheduler started (${config.heartbeatIntervalMinutes}m interval)');
      }

      // Connect channels
      if (channelManager != null) {
        await channelManager.connectAll();
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
            heartbeat?.stop();
            await Future.wait([httpServer.close(), server!.shutdown()]);
            scheduleService?.stop();
            resetService.dispose();
            await kvService.dispose();
            startedSearchDb.close();
            _stderrLine('Shutdown complete');
          }).timeout(const Duration(seconds: 10));
        } on TimeoutException {
          _stderrLine('Shutdown timed out, forcing exit');
          _exitFn(1);
        } catch (e) {
          _stderrLine('Error during shutdown: $e');
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

  void _writeLogRotationSamples(String logsDir) {
    final logPath = p.join(logsDir, 'dartclaw.log');

    // macOS newsyslog.d sample
    final newsyslog = File(p.join(logsDir, 'newsyslog.conf.sample'));
    if (!newsyslog.existsSync()) {
      newsyslog.writeAsStringSync(
        '# newsyslog.d config for DartClaw log rotation (macOS)\n'
        '# Copy to /etc/newsyslog.d/dartclaw.conf\n'
        '$logPath\t\t644\t7\t1024\t*\tJ\n',
      );
    }

    // Linux logrotate sample
    final logrotate = File(p.join(logsDir, 'logrotate.conf.sample'));
    if (!logrotate.existsSync()) {
      logrotate.writeAsStringSync(
        '# logrotate config for DartClaw log rotation (Linux)\n'
        '# Copy to /etc/logrotate.d/dartclaw\n'
        '$logPath {\n'
        '    daily\n'
        '    rotate 7\n'
        '    compress\n'
        '    missingok\n'
        '    notifempty\n'
        '    size 1024k\n'
        '}\n',
      );
    }

    Logger('ServeCommand').info('Log rotation configs generated in $logsDir');
  }

  /// Tears down server + search DB without HTTP server (used when bind fails).
  Future<void> _teardown(DartclawServer? server, Database? searchDb, AgentHarness? harness) async {
    try {
      if (server != null) {
        await server.shutdown();
      } else if (harness != null) {
        await harness.stop();
      }
    } catch (_) {}
    try {
      searchDb?.close();
    } catch (_) {}
  }
}
