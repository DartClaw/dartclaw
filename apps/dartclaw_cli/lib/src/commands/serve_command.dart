import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/command_runner.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
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
      SessionService? sessionsForTurns,
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
      SignalChannel? signalChannel,
      String? webhookSecret,
      MessageRedactor? redactor,
      String? gatewayToken,
      SelfImprovementService? selfImprovement,
      UsageTracker? usageTracker,
      bool authEnabled,
      bool heartbeatEnabled,
      int heartbeatIntervalMinutes,
      List<Map<String, dynamic>> scheduledJobs,
      String? workspacePath,
      bool gitSyncEnabled,
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
           ((cwd, {claudeExecutable, turnTimeout, onMemorySave, onMemorySearch, onMemoryRead, harnessConfig}) =>
               ClaudeCodeHarness(
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
             sessionsForTurns,
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
             signalChannel,
             webhookSecret,
             redactor,
             gatewayToken,
             selfImprovement,
             usageTracker,
             authEnabled = true,
             heartbeatEnabled = false,
             heartbeatIntervalMinutes = 30,
             scheduledJobs = const [],
             workspacePath,
             gitSyncEnabled = false,
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
             signalChannel: signalChannel,
             webhookSecret: webhookSecret,
             redactor: redactor,
             gatewayToken: gatewayToken,
             selfImprovement: selfImprovement,
             usageTracker: usageTracker,
             authEnabled: authEnabled,
             heartbeatEnabled: heartbeatEnabled,
             heartbeatIntervalMinutes: heartbeatIntervalMinutes,
             scheduledJobs: scheduledJobs,
             workspacePath: workspacePath,
             gitSyncEnabled: gitSyncEnabled,
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
      ..addOption(
        'log-level',
        allowed: ['FINE', 'INFO', 'WARNING', 'SEVERE'],
        defaultsTo: 'INFO',
        help: 'Minimum log level',
      );
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

    // Load and validate HTML templates
    try {
      initTemplates(config.templatesDir);
    } on StateError catch (e) {
      _stderrLine('Error: ${e.message}');
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

    final messageRedactor = MessageRedactor(extraPatterns: config.redactPatterns);
    final logRedactor = LogRedactor(redactor: messageRedactor);
    final logService = LogService.fromConfig(
      format: logFormat,
      logFile: logFile,
      level: logLevel,
      redactor: logRedactor,
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

      // QMD hybrid search (optional — requires `qmd` binary)
      QmdManager? qmdManager;
      if (config.searchBackend == 'qmd') {
        final mgr = QmdManager(
          host: config.searchQmdHost,
          port: config.searchQmdPort,
          workspaceDir: config.workspaceDir,
        );
        if (await mgr.isAvailable()) {
          try {
            await mgr.start();
            qmdManager = mgr;
            Logger('ServeCommand').info('QMD hybrid search active on ${mgr.baseUrl}');
          } catch (e) {
            Logger('ServeCommand').warning('QMD daemon failed to start, falling back to FTS5: $e');
          }
        } else {
          Logger('ServeCommand').warning('search.backend is "qmd" but qmd binary not found — falling back to FTS5');
        }
      }

      final searchBackend = createSearchBackend(
        backend: config.searchBackend,
        memoryService: memory,
        qmdManager: qmdManager,
        defaultDepth: config.searchDefaultDepth,
      );
      final selfImprovement = SelfImprovementService(workspaceDir: config.workspaceDir);
      final handlers = createMemoryHandlers(
        memory: memory,
        memoryFile: memoryFile,
        searchBackend: searchBackend,
        selfImprovement: selfImprovement,
      );

      final behavior = BehaviorFileService(
        workspaceDir: config.workspaceDir,
        projectDir: p.join(Directory.current.path, '.dartclaw'),
        maxMemoryBytes: config.memoryMaxBytes,
      );

      final staticPrompt = await behavior.composeStaticPrompt();

      // Build agent definitions before HarnessConfig so default search agent
      // model is included in the initialize handshake.
      final agentDefs = config.agentDefinitions.isNotEmpty ? config.agentDefinitions : [AgentDefinition.searchAgent()];
      final agentMap = {for (final a in agentDefs) a.id: a};
      final agentsPayload = {for (final a in agentDefs) a.id: a.toInitializePayload()};

      // Resolve gateway token early so it's available for MCP config in HarnessConfig.
      final authEnabled = config.gatewayAuthMode != 'none';
      String? resolvedGatewayToken;
      if (authEnabled) {
        resolvedGatewayToken = config.gatewayToken ?? TokenService.loadFromFile(dataDir);
        if (resolvedGatewayToken == null) {
          final ts = TokenService();
          resolvedGatewayToken = ts.token;
          TokenService.persistToFile(dataDir, resolvedGatewayToken);
        }
      }

      final harnessConfig = HarnessConfig(
        disallowedTools: config.agentDisallowedTools,
        maxTurns: config.agentMaxTurns,
        model: config.agentModel,
        agents: agentsPayload,
        context1m: config.agentContext1m,
        appendSystemPrompt: staticPrompt,
        mcpServerUrl: resolvedGatewayToken != null ? 'http://127.0.0.1:$port/mcp' : null,
        mcpGatewayToken: resolvedGatewayToken,
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

      // Build ToolPolicyCascade from agent definitions
      final agentAllow = <String, Set<String>>{};
      final agentDeny = <String, Set<String>>{};
      for (final agent in agentDefs) {
        if (agent.allowedTools.isNotEmpty) agentAllow[agent.id] = agent.allowedTools;
        if (agent.deniedTools.isNotEmpty) agentDeny[agent.id] = agent.deniedTools;
      }
      final toolPolicyCascade = ToolPolicyCascade(
        globalDeny: config.agentDisallowedTools.toSet(),
        agentDeny: agentDeny,
        agentAllow: agentAllow,
      );

      // Construct guard chain with per-guard YAML configs
      final auditLogger = GuardAuditLogger();
      final guardChain = config.guards.enabled
          ? GuardChain(
              failOpen: config.guards.failOpen,
              guards: [
                InputSanitizer(
                  config: config.guardsYaml['input_sanitizer'] is Map
                      ? InputSanitizerConfig.fromYaml(
                          Map<String, dynamic>.from(config.guardsYaml['input_sanitizer'] as Map),
                        )
                      : InputSanitizerConfig(
                          enabled: config.inputSanitizerEnabled,
                          channelsOnly: config.inputSanitizerChannelsOnly,
                          patterns: InputSanitizerConfig.defaults().patterns,
                        ),
                ),
                CommandGuard(
                  config: config.guardsYaml['command'] is Map
                      ? CommandGuardConfig.fromYaml(Map<String, dynamic>.from(config.guardsYaml['command'] as Map))
                      : CommandGuardConfig.defaults(),
                ),
                FileGuard(
                  config:
                      (config.guardsYaml['file'] is Map
                              ? FileGuardConfig.fromYaml(Map<String, dynamic>.from(config.guardsYaml['file'] as Map))
                              : FileGuardConfig.defaults())
                          .withSelfProtection(p.join(dataDir, 'dartclaw.yaml')),
                ),
                NetworkGuard(
                  config: config.guardsYaml['network'] is Map
                      ? NetworkGuardConfig.fromYaml(Map<String, dynamic>.from(config.guardsYaml['network'] as Map))
                      : NetworkGuardConfig.defaults(),
                ),
                ToolPolicyGuard(cascade: toolPolicyCascade),
              ],
              auditLogger: auditLogger,
            )
          : null;

      // ContentGuard: classifier selection based on config
      ContentGuard? contentGuard;
      if (config.contentGuardEnabled) {
        ContentClassifier? classifier;
        var failOpen = false;

        if (config.contentGuardClassifier == 'anthropic_api') {
          final apiKey = Platform.environment['ANTHROPIC_API_KEY'];
          if (apiKey != null && apiKey.isNotEmpty) {
            classifier = AnthropicApiClassifier(
              apiKey: apiKey,
              model: config.contentGuardModel,
            );
          } else {
            Logger('ServeCommand').warning(
              'ANTHROPIC_API_KEY not set — content guard disabled. '
              'Set the environment variable or switch to classifier: claude_binary.',
            );
          }
        } else {
          // Default: claude_binary — works with OAuth, no API key needed
          classifier = ClaudeBinaryClassifier(
            claudeExecutable: config.claudeExecutable,
            model: config.contentGuardModel,
          );
          failOpen = true;
        }

        if (classifier != null) {
          contentGuard = ContentGuard(
            classifier: classifier,
            maxContentBytes: config.contentGuardMaxBytes,
            failOpen: failOpen,
          );
        }
      }

      // Ensure agent session directories exist
      for (final agent in agentDefs) {
        if (agent.sessionStorePath.isNotEmpty) {
          Directory(p.join(config.workspaceDir, agent.sessionStorePath)).createSync(recursive: true);
        }
      }

      // SessionDelegate: dispatches sub-agent turns with content guard at boundary
      final totalConcurrent = agentDefs.fold(0, (sum, a) => sum + a.maxConcurrent);
      final subagentLimits = SubagentLimits(
        maxConcurrent: totalConcurrent,
        maxSpawnDepth: 1,
        maxChildrenPerAgent: totalConcurrent,
      );
      final sessionDelegate = SessionDelegate(
        dispatch: ({required sessionId, required message, required agentId}) async {
          final session = await sessions.getOrCreateByKey(sessionId);
          final userMsg = <String, dynamic>{'role': 'user', 'content': message};
          final turnId = await server!.turns.startTurn(session.id, [userMsg], agentName: agentId);
          final outcome = await server.turns.waitForOutcome(session.id, turnId);
          if (outcome.status != TurnStatus.completed) {
            throw StateError('Agent turn failed: ${outcome.errorMessage}');
          }
          // Extract last assistant message from the session
          final msgs = await messages.getMessages(session.id);
          final lastAssistant = msgs.lastWhere(
            (m) => m.role == 'assistant',
            orElse: () => throw StateError('No assistant response in session'),
          );
          return lastAssistant.content;
        },
        limits: subagentLimits,
        agents: agentMap,
        contentGuard: contentGuard,
        auditLogger: auditLogger,
      );

      // KV store for per-session cost tracking
      final kvService = KvService(filePath: config.kvPath);

      // Usage tracking (fire-and-forget, never blocks turns)
      final usageTracker = UsageTracker(
        dataDir: dataDir,
        kv: kvService,
        budgetWarningTokens: config.usageBudgetWarningTokens,
        maxFileSizeBytes: config.usageMaxFileSizeBytes,
      );

      // Health service
      final startedSearchDb = searchDb;
      final startedHarness = harness;
      final healthService = HealthService(
        worker: startedHarness,
        searchDbPath: config.searchDbPath,
        sessionsDir: config.sessionsDir,
        usageTracker: usageTracker,
      );

      // Gateway auth (token already resolved earlier for HarnessConfig MCP wiring).
      TokenService? tokenService;
      SessionStore? sessionStore;

      if (authEnabled) {
        tokenService = TokenService(token: resolvedGatewayToken!);
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
      final waConfig = config.channelConfig.channelConfigs['whatsapp'];
      final sigConfig = config.channelConfig.channelConfigs['signal'];
      final waEnabled = waConfig != null && waConfig['enabled'] == true;
      final sigEnabled = sigConfig != null && sigConfig['enabled'] == true;

      ChannelManager? channelManager;
      WhatsAppChannel? whatsAppChannel;
      SignalChannel? signalChannel;
      String? webhookSecret;

      if (waEnabled || sigEnabled) {
        channelManager = _buildChannelManager(config: config, sessions: sessions, serverRef: () => server, redactor: messageRedactor);
      }

      if (waEnabled && channelManager != null) {
        try {
          final warns = <String>[];
          final parsedConfig = WhatsAppConfig.fromYaml(waConfig, warns);
          for (final w in warns) {
            Logger('ServeCommand').warning('WhatsApp config: $w');
          }
          // Generate shared webhook secret for GOWA→DartClaw webhook auth
          final webhookSecretBytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
          webhookSecret = base64Url.encode(webhookSecretBytes).replaceAll('=', '');
          final webhookUrl = 'http://localhost:$port/webhook/whatsapp?secret=$webhookSecret';

          final gowaManager = GowaManager(
            executable: parsedConfig.gowaExecutable,
            host: parsedConfig.gowaHost,
            port: parsedConfig.gowaPort,
            dbUri: parsedConfig.gowaDbUri,
            webhookUrl: webhookUrl,
          );
          final waChannel = WhatsAppChannel(
            gowa: gowaManager,
            config: parsedConfig,
            dmAccess: DmAccessController(mode: parsedConfig.dmAccess, allowlist: parsedConfig.dmAllowlist.toSet()),
            mentionGating: MentionGating(
              requireMention: parsedConfig.requireMention,
              mentionPatterns: parsedConfig.mentionPatterns,
              ownJid: '',
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

      // Signal channel wiring
      if (sigEnabled && channelManager != null) {
        try {
          final warns = <String>[];
          final parsedSignalConfig = SignalConfig.fromYaml(sigConfig, warns);
          for (final w in warns) {
            Logger('ServeCommand').warning('Signal config: $w');
          }

          final sidecar = SignalCliManager(
            executable: parsedSignalConfig.executable,
            host: parsedSignalConfig.host,
            port: parsedSignalConfig.port,
            phoneNumber: parsedSignalConfig.phoneNumber,
          );

          final sigDmAccess = SignalDmAccessController(
            mode: parsedSignalConfig.dmAccess,
            allowlist: parsedSignalConfig.dmAllowlist.toSet(),
          );
          final sigMentionGating = SignalMentionGating(
            requireMention: parsedSignalConfig.requireMention,
            mentionPatterns: parsedSignalConfig.mentionPatterns,
            ownNumber: parsedSignalConfig.phoneNumber,
          );

          final sigChannel = SignalChannel(
            sidecar: sidecar,
            config: parsedSignalConfig,
            dmAccess: sigDmAccess,
            mentionGating: sigMentionGating,
            channelManager: channelManager,
          );
          channelManager.registerChannel(sigChannel);
          signalChannel = sigChannel;
          Logger('ServeCommand').info('Signal channel registered');
        } catch (e) {
          Logger('ServeCommand').warning('Failed to initialize Signal channel: $e');
        }
      }

      // Mutable display list for scheduling UI (includes both user-configured
      // and built-in jobs). Starts as a copy of the raw config maps.
      final displayJobs = config.schedulingJobs.map((j) => Map<String, dynamic>.of(j)).toList();

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
        signalChannel: signalChannel,
        webhookSecret: webhookSecret,
        redactor: messageRedactor,
        gatewayToken: resolvedGatewayToken,
        selfImprovement: selfImprovement,
        usageTracker: usageTracker,
        authEnabled: authEnabled,
        heartbeatEnabled: config.heartbeatEnabled,
        heartbeatIntervalMinutes: config.heartbeatIntervalMinutes,
        scheduledJobs: displayJobs,
        workspacePath: config.workspaceDir,
        gitSyncEnabled: config.gitSyncEnabled,
      );

      // Register MCP tools on the internal MCP server (/mcp HTTP endpoint).
      server.registerTool(SessionsSendTool(delegate: sessionDelegate));
      server.registerTool(SessionsSpawnTool(delegate: sessionDelegate));
      server.registerTool(MemorySaveTool(handler: handlers.onSave));
      server.registerTool(MemorySearchTool(handler: handlers.onSearch));
      server.registerTool(MemoryReadTool(handler: handlers.onRead));

      // Detect orphaned turns from previous crash
      await server.turns.detectAndCleanOrphanedTurns();

      // Parse scheduled jobs from config
      final scheduledJobs = <ScheduledJob>[];
      for (final jobConfig in config.schedulingJobs) {
        try {
          scheduledJobs.add(ScheduledJob.fromConfig(jobConfig));
        } catch (e) {
          Logger('ServeCommand').warning('Invalid scheduled job config: $e — skipping');
        }
      }

      // Register memory pruner as a built-in scheduled job
      if (config.memoryPruningEnabled) {
        final pruner = MemoryPruner(
          workspaceDir: config.workspaceDir,
          memoryService: memory,
          archiveAfterDays: config.memoryArchiveAfterDays,
        );
        scheduledJobs.add(ScheduledJob(
          id: 'memory-pruner',
          scheduleType: ScheduleType.cron,
          cronExpression: CronExpression.parse(config.memoryPruningSchedule),
          onExecute: () async {
            final result = await pruner.prune();
            final msg = '${result.entriesArchived} archived, '
                '${result.duplicatesRemoved} deduped, '
                '${result.entriesRemaining} remaining (${result.finalSizeBytes}B)';
            Logger('MemoryPruner').info(msg);
            return msg;
          },
        ));
        displayJobs.add({
          'name': 'memory-pruner',
          'schedule': config.memoryPruningSchedule,
          'delivery': 'none',
          'status': 'active',
        });
        Logger('ServeCommand').info(
          'Memory pruner scheduled (${config.memoryPruningSchedule}, '
          'archive after ${config.memoryArchiveAfterDays}d)',
        );
      }

      // Start cron scheduler
      ScheduleService? scheduleService;
      if (scheduledJobs.isNotEmpty) {
        scheduleService = ScheduleService(turns: server.turns, sessions: sessions, jobs: scheduledJobs);
        scheduleService.start();
      }

      // Workspace git sync
      WorkspaceGitSync? gitSync;
      if (config.gitSyncEnabled) {
        gitSync = WorkspaceGitSync(workspaceDir: config.workspaceDir, pushEnabled: config.gitSyncPushEnabled);
        if (await gitSync.isGitAvailable()) {
          await gitSync.initIfNeeded();
          Logger('ServeCommand').info('Workspace git sync enabled');
        } else {
          gitSync = null;
        }
      }

      // Heartbeat scheduler
      HeartbeatScheduler? heartbeat;
      if (config.heartbeatEnabled) {
        heartbeat = HeartbeatScheduler(
          interval: Duration(minutes: config.heartbeatIntervalMinutes),
          workspaceDir: config.workspaceDir,
          dispatch: (sessionKey, message) async {
            final session = await sessions.getOrCreateByKey(sessionKey, type: SessionType.cron);
            final userMsg = <String, dynamic>{'role': 'user', 'content': message};
            await server!.turns.startTurn(session.id, [userMsg], source: 'heartbeat', agentName: 'heartbeat');
          },
          gitSync: gitSync,
        );
        heartbeat.start();
        Logger('ServeCommand').info('Heartbeat scheduler started (${config.heartbeatIntervalMinutes}m interval)');
      }

      // Inject runtime services BEFORE building the HTTP handler. The handler
      // getter constructs the router once; routes are registered conditionally
      // based on these services, so they must be wired before server.handler
      // is evaluated.
      server.setRuntimeServices(
        heartbeat: heartbeat,
        scheduleService: scheduleService,
        gitSync: gitSync,
        runtimeConfig: RuntimeConfig(
          heartbeatEnabled: config.heartbeatEnabled,
          gitSyncEnabled: config.gitSyncEnabled,
          gitSyncPushEnabled: config.gitSyncPushEnabled,
        ),
      );

      // Start HTTP server (handler built here — services are set above)
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
            await selfImprovement.dispose();
            await qmdManager?.stop();
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

  /// Builds the shared [ChannelManager] used by all messaging channels.
  ///
  /// The dispatcher closure captures [serverRef] (a lazy callback) so the
  /// server reference is resolved at dispatch time, after it's been assigned.
  ChannelManager _buildChannelManager({
    required DartclawConfig config,
    required SessionService sessions,
    required DartclawServer? Function() serverRef,
    MessageRedactor? redactor,
  }) {
    final messageQueue = MessageQueue(
      debounceWindow: config.channelConfig.debounceWindow,
      maxConcurrentTurns: config.maxParallelTurns,
      maxQueueDepth: config.channelConfig.maxQueueDepth,
      defaultRetryPolicy: config.channelConfig.defaultRetryPolicy,
      redactor: redactor,
      dispatcher: (sessionKey, message, {String? senderJid}) async {
        final session = await sessions.getOrCreateByKey(sessionKey, type: SessionType.channel);
        final userMsg = <String, dynamic>{'role': 'user', 'content': message};
        final srv = serverRef()!;
        final turnId = await srv.turns.startTurn(session.id, [userMsg], source: 'channel');
        final outcome = await srv.turns.waitForOutcome(session.id, turnId);
        return outcome.status == TurnStatus.completed ? 'OK' : 'Failed: ${outcome.errorMessage}';
      },
    );
    return ChannelManager(queue: messageQueue, config: config.channelConfig);
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
