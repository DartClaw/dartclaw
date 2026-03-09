import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'serve_command.dart';

/// Immutable holder for services needed by [ServeCommand.run] after
/// [ServiceWiring.wire] completes.
///
/// Contains only the references required for HTTP server startup, startup
/// banner, channel connection, and graceful shutdown. All other services are
/// wired internally by [ServiceWiring.wire] and do not leak out.
class WiringResult {
  final DartclawServer server;
  final Database searchDb;
  final AgentHarness harness;
  final HeartbeatScheduler? heartbeat;
  final ScheduleService? scheduleService;
  final KvService kvService;
  final SessionResetService resetService;
  final SelfImprovementService selfImprovement;
  final QmdManager? qmdManager;
  final ChannelManager? channelManager;
  final bool authEnabled;
  final TokenService? tokenService;
  final Future<void> Function() shutdownExtras;

  const WiringResult({
    required this.server,
    required this.searchDb,
    required this.harness,
    required this.heartbeat,
    required this.scheduleService,
    required this.kvService,
    required this.resetService,
    required this.selfImprovement,
    required this.qmdManager,
    required this.channelManager,
    required this.authEnabled,
    required this.tokenService,
    required this.shutdownExtras,
  });
}

/// Encapsulates service construction and wiring for the DartClaw server.
///
/// Extracted from [ServeCommand.run] to separate CLI concerns (arg parsing,
/// config resolution, logging, shutdown) from service initialization (DB,
/// harness, guards, channels, scheduling, memory, etc.).
class ServiceWiring {
  final DartclawConfig config;
  final String dataDir;
  final int port;
  final HarnessFactory harnessFactory;
  final ServerFactory serverFactory;
  final SearchDbFactory searchDbFactory;
  final WriteLine stderrLine;
  final ExitFn exitFn;
  final String resolvedConfigPath;
  final LogService logService;
  final MessageRedactor messageRedactor;

  static final _log = Logger('ServiceWiring');

  ServiceWiring({
    required this.config,
    required this.dataDir,
    required this.port,
    required this.harnessFactory,
    required this.serverFactory,
    required this.searchDbFactory,
    required this.stderrLine,
    required this.exitFn,
    required this.resolvedConfigPath,
    required this.logService,
    required this.messageRedactor,
  });

  /// Constructs all services, wires them together, builds the server, registers
  /// MCP tools, and calls [DartclawServer.setRuntimeServices].
  ///
  /// Returns a [WiringResult] containing everything [ServeCommand.run] needs
  /// to start the HTTP server, print the startup banner, and wire shutdown.
  Future<WiringResult> wire() async {
    // Construct file-based services
    Directory(config.sessionsDir).createSync(recursive: true);

    final sessions = SessionService(baseDir: config.sessionsDir);
    final messages = MessageService(baseDir: config.sessionsDir);

    // Ensure main session exists on startup
    await sessions.getOrCreateMain();

    // Search DB
    Database searchDb;
    try {
      searchDb = searchDbFactory(config.searchDbPath);
    } catch (_) {
      _log.severe('Cannot open search database at ${config.searchDbPath}');
      exitFn(1);
    }

    // Memory stack (MEMORY.md now lives in workspace/)
    final memoryFile = MemoryFileService(baseDir: config.workspaceDir);
    final memory = MemoryService(searchDb);

    // QMD hybrid search (optional -- requires `qmd` binary)
    QmdManager? qmdManager;
    if (config.searchBackend == 'qmd') {
      final mgr = QmdManager(host: config.searchQmdHost, port: config.searchQmdPort, workspaceDir: config.workspaceDir);
      if (await mgr.isAvailable()) {
        try {
          await mgr.start();
          qmdManager = mgr;
          _log.info('QMD hybrid search active on ${mgr.baseUrl}');
        } catch (e) {
          _log.warning('QMD daemon failed to start, falling back to FTS5: $e');
        }
      } else {
        _log.warning('search.backend is "qmd" but qmd binary not found — falling back to FTS5');
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

    final mcpEnabled = resolvedGatewayToken != null;
    final harnessConfig = HarnessConfig(
      disallowedTools: mcpDisallowedTools(
        mcpEnabled: mcpEnabled,
        searchEnabled: _hasSearchProvider(config),
        userDisallowed: config.agentDisallowedTools,
      ),
      maxTurns: config.agentMaxTurns,
      model: config.agentModel,
      agents: agentsPayload,
      context1m: config.agentContext1m,
      appendSystemPrompt: staticPrompt,
      mcpServerUrl: resolvedGatewayToken != null ? 'http://127.0.0.1:$port/mcp' : null,
      mcpGatewayToken: resolvedGatewayToken,
    );

    CredentialProxy? credentialProxy;
    ContainerManager? containerManager;
    if (config.containerConfig.enabled) {
      final validationErrors = DockerValidator.validate(config.containerConfig);
      if (validationErrors.isNotEmpty) {
        for (final err in validationErrors) {
          _log.severe('Container config rejected: $err');
        }
        exitFn(1);
      }

      final apiKey = Platform.environment['ANTHROPIC_API_KEY']?.trim();
      String? hostClaudeJsonPath;
      if (apiKey == null || apiKey.isEmpty) {
        final authResult = await Process.run(config.claudeExecutable, ['auth', 'status']);
        if (authResult.exitCode != 0) {
          _log.severe('Container mode requires ANTHROPIC_API_KEY or Claude OAuth/setup-token auth');
          _log.severe('Configure auth with `claude login`, `claude setup-token`, or ANTHROPIC_API_KEY');
          exitFn(1);
        }
        try {
          final status = jsonDecode(authResult.stdout as String) as Map<String, dynamic>;
          if (status['loggedIn'] != true) {
            _log.severe('Container mode requires ANTHROPIC_API_KEY or Claude OAuth/setup-token auth');
            _log.severe('Configure auth with `claude login`, `claude setup-token`, or ANTHROPIC_API_KEY');
            exitFn(1);
          }
        } on FormatException {
          _log.severe('Unable to verify Claude auth status for container mode');
          exitFn(1);
        }

        final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
        if (home == null) {
          _log.severe('Cannot locate HOME to mount Claude OAuth credentials into the container');
          exitFn(1);
        }
        final claudeJson = File(p.join(home, '.claude.json'));
        if (!claudeJson.existsSync()) {
          _log.severe('Claude OAuth appears configured, but ~/.claude.json was not found');
          exitFn(1);
        }
        hostClaudeJsonPath = claudeJson.path;
      }

      containerManager = ContainerManager(
        config: config.containerConfig,
        workspaceDir: config.workspaceDir,
        projectDir: Directory.current.path,
        proxySocketDir: p.join(dataDir, 'proxy'),
        hostClaudeJsonPath: hostClaudeJsonPath,
      );

      if (!await containerManager.isDockerAvailable()) {
        _log.severe('Docker is required when container.enabled: true');
        _log.severe('Install or start Docker: https://docs.docker.com/get-docker/');
        exitFn(1);
      }

      credentialProxy = CredentialProxy(socketPath: p.join(dataDir, 'proxy', 'proxy.sock'), apiKey: apiKey);
      await credentialProxy.start();

      try {
        await containerManager.ensureImage();
        await containerManager.start();
      } catch (e) {
        await credentialProxy.stop();
        rethrow;
      }

      _log.info('Container isolation enabled (image: ${config.containerConfig.image})');
    } else {
      _log.warning(
        'Container isolation disabled — agent has full host access. '
        'Guards are the only security boundary. '
        'Enable container isolation for production use (see docs/guide/security.md).',
      );
    }

    final harness = harnessFactory(
      Directory.current.path,
      claudeExecutable: config.claudeExecutable,
      turnTimeout: Duration(seconds: config.workerTimeout),
      onMemorySave: handlers.onSave,
      onMemorySearch: handlers.onSearch,
      onMemoryRead: handlers.onRead,
      harnessConfig: harnessConfig,
      containerManager: containerManager,
    );
    try {
      await harness.start();
    } catch (e) {
      _log.severe('Failed to start harness: $e');
      await memoryFile.dispose();
      await credentialProxy?.stop();
      await containerManager?.stop();
      await teardown(null, searchDb, harness);
      exitFn(1);
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
    final auditLogger = GuardAuditLogger(dataDir: dataDir);
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
    ContentClassifier? contentClassifier;
    var contentGuardFailOpen = false;
    ContentGuard? contentGuard;
    if (config.contentGuardEnabled) {
      if (config.contentGuardClassifier == 'anthropic_api') {
        final apiKey = Platform.environment['ANTHROPIC_API_KEY'];
        if (apiKey != null && apiKey.isNotEmpty) {
          contentClassifier = AnthropicApiClassifier(apiKey: apiKey, model: config.contentGuardModel);
        } else {
          _log.warning(
            'ANTHROPIC_API_KEY not set — content guard disabled. '
            'Set the environment variable or switch to classifier: claude_binary.',
          );
        }
      } else {
        // Default: claude_binary -- works with OAuth, no API key needed
        contentClassifier = ClaudeBinaryClassifier(
          claudeExecutable: config.claudeExecutable,
          model: config.contentGuardModel,
        );
        contentGuardFailOpen = true;
      }

      if (contentClassifier != null) {
        contentGuard = ContentGuard(
          classifier: contentClassifier,
          maxContentBytes: config.contentGuardMaxBytes,
          failOpen: contentGuardFailOpen,
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

    // Use a mutable reference so the delegate closure captures the final server.
    DartclawServer? serverRef;

    final sessionDelegate = SessionDelegate(
      dispatch: ({required sessionId, required message, required agentId}) async {
        final session = await sessions.getOrCreateByKey(sessionId);
        final userMsg = <String, dynamic>{'role': 'user', 'content': message};
        final srv = serverRef!;
        final turnId = await srv.turns.startTurn(session.id, [userMsg], agentName: agentId);
        final outcome = await srv.turns.waitForOutcome(session.id, turnId);
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
    final healthService = HealthService(
      worker: harness,
      searchDbPath: config.searchDbPath,
      sessionsDir: config.sessionsDir,
      usageTracker: usageTracker,
    );

    // Gateway auth (token already resolved earlier for HarnessConfig MCP wiring).
    TokenService? tokenService;

    if (authEnabled) {
      tokenService = TokenService(token: resolvedGatewayToken!);
    } else {
      final host = config.host;
      final isLoopback = host == 'localhost' || host == '127.0.0.1';
      if (isLoopback) {
        _log.warning('Auth disabled on loopback — acceptable for local dev only');
      } else {
        _log.severe('CRITICAL: Auth disabled on network-accessible host $host');
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
      channelManager = _buildChannelManager(
        config: config,
        sessions: sessions,
        messages: messages,
        serverRef: () => serverRef,
        redactor: messageRedactor,
      );
    }

    if (waEnabled && channelManager != null) {
      try {
        final warns = <String>[];
        final parsedConfig = WhatsAppConfig.fromYaml(waConfig, warns);
        for (final w in warns) {
          _log.warning('WhatsApp config: $w');
        }
        // Generate shared webhook secret for GOWA->DartClaw webhook auth
        final webhookSecretBytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
        webhookSecret = base64Url.encode(webhookSecretBytes).replaceAll('=', '');
        final webhookUrl = 'http://localhost:$port/webhook/whatsapp?secret=$webhookSecret';

        final gowaManager = GowaManager(
          executable: parsedConfig.gowaExecutable,
          host: parsedConfig.gowaHost,
          port: parsedConfig.gowaPort,
          dbUri: parsedConfig.gowaDbUri,
          webhookUrl: webhookUrl,
          osName: config.name,
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
        _log.info('WhatsApp channel registered');
      } catch (e) {
        _log.warning('Failed to initialize WhatsApp channel: $e');
      }
    }

    // Create ConfigWriter for persistent config editing.
    final configWriter = ConfigWriter(configPath: resolvedConfigPath);

    // Signal channel wiring
    if (sigEnabled && channelManager != null) {
      try {
        final warns = <String>[];
        final parsedSignalConfig = SignalConfig.fromYaml(sigConfig, warns);
        for (final w in warns) {
          _log.warning('Signal config: $w');
        }

        final sidecar = SignalCliManager(
          executable: parsedSignalConfig.executable,
          host: parsedSignalConfig.host,
          port: parsedSignalConfig.port,
          phoneNumber: parsedSignalConfig.phoneNumber,
          onRegistered: (phone) {
            _log.info('Signal: writing registered phone $phone to config');
            unawaited(
              configWriter
                  .updateFields({'channels.signal.phone_number': phone})
                  .catchError((Object e) => _log.warning('Failed to write Signal phone to config', e)),
            );
          },
        );

        final sigDmAccess = DmAccessController(
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
        _log.info('Signal channel registered');
      } catch (e) {
        _log.warning('Failed to initialize Signal channel: $e');
      }
    }

    // Mutable display list for scheduling UI (includes both user-configured
    // and built-in jobs). Starts as a copy of the raw config maps.
    final displayJobs = config.schedulingJobs.map((j) => Map<String, dynamic>.of(j)).toList();
    // Names of system-registered jobs (rendered read-only with SYSTEM badge).
    final systemJobNames = <String>['heartbeat'];

    final server = serverFactory(
      sessions: sessions,
      messages: messages,
      worker: harness,
      staticDir: config.staticDir,
      behavior: behavior,
      memoryFile: memoryFile,
      guardChain: guardChain,
      kv: kvService,
      healthService: healthService,
      tokenService: tokenService,
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
      contentGuardDisplay: ContentGuardDisplayParams(
        enabled: config.contentGuardEnabled,
        classifier: config.contentGuardClassifier,
        model: config.contentGuardModel,
        maxBytes: config.contentGuardMaxBytes,
        apiKeyConfigured:
            config.contentGuardClassifier == 'claude_binary' ||
            (Platform.environment['ANTHROPIC_API_KEY']?.isNotEmpty ?? false),
        failOpen: contentGuardFailOpen,
      ),
      heartbeatDisplay: HeartbeatDisplayParams(
        enabled: config.heartbeatEnabled,
        intervalMinutes: config.heartbeatIntervalMinutes,
      ),
      schedulingDisplay: SchedulingDisplayParams(jobs: displayJobs, systemJobNames: systemJobNames),
      workspaceDisplay: WorkspaceDisplayParams(path: config.workspaceDir),
      appDisplay: AppDisplayParams(name: config.name, dataDir: dataDir),
    );

    // Set the mutable reference so the delegate closure can resolve it.
    serverRef = server;

    // Register MCP tools on the internal MCP server (/mcp HTTP endpoint).
    server.registerTool(SessionsSendTool(delegate: sessionDelegate));
    server.registerTool(SessionsSpawnTool(delegate: sessionDelegate));
    server.registerTool(MemorySaveTool(handler: handlers.onSave));
    server.registerTool(MemorySearchTool(handler: handlers.onSearch));
    server.registerTool(MemoryReadTool(handler: handlers.onRead));
    server.registerTool(WebFetchTool(classifier: contentClassifier, failOpenOnClassification: contentGuardFailOpen));

    // Register search tools based on config
    for (final entry in config.searchProviders.entries) {
      final providerName = entry.key;
      final providerConfig = entry.value;
      if (!providerConfig.enabled || providerConfig.apiKey.isEmpty) continue;

      switch (providerName) {
        case 'brave':
          server.registerTool(
            BraveSearchTool(
              provider: BraveSearchProvider(apiKey: providerConfig.apiKey),
              contentGuard: contentGuard,
            ),
          );
          _log.info('Registered brave_search MCP tool');
        case 'tavily':
          server.registerTool(
            TavilySearchTool(
              provider: TavilySearchProvider(apiKey: providerConfig.apiKey),
              contentGuard: contentGuard,
            ),
          );
          _log.info('Registered tavily_search MCP tool');
        default:
          _log.warning('Unknown search provider: $providerName — skipping');
      }
    }

    // Detect orphaned turns from previous crash
    await server.turns.detectAndCleanOrphanedTurns();

    // Parse scheduled jobs from config
    final scheduledJobs = <ScheduledJob>[];
    for (final jobConfig in config.schedulingJobs) {
      try {
        scheduledJobs.add(ScheduledJob.fromConfig(jobConfig));
      } catch (e) {
        _log.warning('Invalid scheduled job config: $e — skipping');
      }
    }

    // Register memory pruner as a built-in scheduled job
    MemoryPruner? memoryPruner;
    if (config.memoryPruningEnabled) {
      final pruner = memoryPruner = MemoryPruner(
        workspaceDir: config.workspaceDir,
        memoryService: memory,
        archiveAfterDays: config.memoryArchiveAfterDays,
      );
      scheduledJobs.add(
        ScheduledJob(
          id: 'memory-pruner',
          scheduleType: ScheduleType.cron,
          cronExpression: CronExpression.parse(config.memoryPruningSchedule),
          onExecute: () async {
            final result = await pruner.prune();
            await _persistPruneResult(kvService, result);
            final msg =
                '${result.entriesArchived} archived, '
                '${result.duplicatesRemoved} deduped, '
                '${result.entriesRemaining} remaining (${result.finalSizeBytes}B)';
            Logger('MemoryPruner').info(msg);
            return msg;
          },
        ),
      );
      displayJobs.add({
        'name': 'memory-pruner',
        'schedule': config.memoryPruningSchedule,
        'delivery': 'none',
        'status': 'active',
      });
      systemJobNames.add('memory-pruner');
      _log.info(
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
        _log.info('Workspace git sync enabled');
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
          await _dispatchTurn(
            sessions,
            () => server,
            sessionKey,
            message,
            type: SessionType.cron,
            source: 'heartbeat',
            agentName: 'heartbeat',
          );
        },
        gitSync: gitSync,
      );
      heartbeat.start();
      _log.info('Heartbeat scheduler started (${config.heartbeatIntervalMinutes}m interval)');
    }

    // Memory status service -- gathers metrics for the dashboard API.
    final memoryStatusService = MemoryStatusService(
      workspaceDir: config.workspaceDir,
      config: config,
      kvService: kvService,
      searchIndexCounter: (source) {
        final result = searchDb.select('SELECT COUNT(*) as cnt FROM memory_chunks WHERE source = ?', [source]);
        return result.first['cnt'] as int;
      },
      scheduleService: scheduleService,
    );

    // Detect and clear restart.pending from previous graceful restart.
    final restartPendingFile = File(p.join(dataDir, 'restart.pending'));
    if (restartPendingFile.existsSync()) {
      try {
        final content = jsonDecode(restartPendingFile.readAsStringSync()) as Map<String, dynamic>;
        final fields = (content['fields'] as List?)?.join(', ') ?? 'unknown';
        stderrLine('Restarted after config change (pending: $fields)');
      } catch (_) {
        stderrLine('Restarted after config change');
      }
      restartPendingFile.deleteSync();
    }

    // Create SSE broadcast and restart service.
    final sseBroadcast = SseBroadcast();
    final restartService = RestartService(
      turns: server.turns,
      drainDeadline: const Duration(seconds: 30),
      exit: exitFn,
      broadcastSse: sseBroadcast.broadcast,
      writeRestartPending: writeRestartPending,
      dataDir: dataDir,
    );

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
      memoryStatusService: memoryStatusService,
      memoryPruner: memoryPruner,
      kvService: kvService,
      configWriter: configWriter,
      config: config,
      restartService: restartService,
      sseBroadcast: sseBroadcast,
    );

    return WiringResult(
      server: server,
      searchDb: searchDb,
      harness: harness,
      heartbeat: heartbeat,
      scheduleService: scheduleService,
      kvService: kvService,
      resetService: resetService,
      selfImprovement: selfImprovement,
      qmdManager: qmdManager,
      channelManager: channelManager,
      authEnabled: authEnabled,
      tokenService: tokenService,
      shutdownExtras: () async {
        await containerManager?.stop();
        await credentialProxy?.stop();
      },
    );
  }

  /// Builds the shared [ChannelManager] used by all messaging channels.
  ///
  /// The dispatcher closure captures [serverRef] (a lazy callback) so the
  /// server reference is resolved at dispatch time, after it's been assigned.
  ChannelManager _buildChannelManager({
    required DartclawConfig config,
    required SessionService sessions,
    required MessageService messages,
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

        // Persist user message so it appears in the web UI conversation view
        await messages.insertMessage(sessionId: session.id, role: 'user', content: message);

        // Auto-name session on first message using channel type + sender identifier
        if (session.title == null && senderJid != null) {
          final String channelPrefix;
          final String identifier;
          if (senderJid.contains('@')) {
            // WhatsApp JID: e.g. "46701234567@s.whatsapp.net"
            channelPrefix = 'WA';
            identifier = senderJid.split('@').first;
          } else if (senderJid.startsWith('+')) {
            // Signal phone number
            channelPrefix = 'Signal';
            identifier = senderJid;
          } else {
            // Signal ACI UUID (sealed sender — phone not available)
            channelPrefix = 'Signal';
            identifier = senderJid.substring(0, 8); // first 8 chars of UUID
          }
          await sessions.updateTitle(session.id, '$channelPrefix › $identifier');
        }

        final userMsg = <String, dynamic>{'role': 'user', 'content': message};
        final srv = serverRef()!;
        final turnId = await srv.turns.startTurn(session.id, [userMsg], source: 'channel');
        final outcome = await srv.turns.waitForOutcome(session.id, turnId);
        return outcome.responseText ?? '';
      },
    );
    return ChannelManager(queue: messageQueue, config: config.channelConfig);
  }

  /// Resolves a session by key, creates a user message, and starts a turn.
  ///
  /// Shared by the channel dispatcher and heartbeat scheduler to avoid
  /// duplicating the session-resolution + turn-start pattern.
  static Future<({String sessionId, String turnId})> _dispatchTurn(
    SessionService sessions,
    DartclawServer? Function() serverRef,
    String sessionKey,
    String message, {
    required SessionType type,
    required String source,
    String? agentName,
  }) async {
    final session = await sessions.getOrCreateByKey(sessionKey, type: type);
    final userMsg = <String, dynamic>{'role': 'user', 'content': message};
    final srv = serverRef()!;
    final turnId = await srv.turns.startTurn(session.id, [userMsg], source: source, agentName: agentName ?? 'main');
    return (sessionId: session.id, turnId: turnId);
  }

  /// Persists a prune result to KV store, keeping the last 10 entries.
  static Future<void> _persistPruneResult(KvService kv, PruneResult result) async {
    final entry = {
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'entriesArchived': result.entriesArchived,
      'duplicatesRemoved': result.duplicatesRemoved,
      'entriesRemaining': result.entriesRemaining,
      'finalSizeBytes': result.finalSizeBytes,
    };

    List<dynamic> history = [];
    try {
      final existing = await kv.get('prune_history');
      if (existing != null) {
        final parsed = jsonDecode(existing);
        if (parsed is List) history = parsed;
      }
    } catch (_) {
      // Corrupt history -- reset
    }

    history.add(entry);
    if (history.length > 10) {
      history = history.sublist(history.length - 10);
    }

    await kv.set('prune_history', jsonEncode(history));
  }

  /// Tears down server + search DB without HTTP server (used when bind fails).
  ///
  /// Also used by [ServeCommand] for the same purpose.
  static Future<void> teardown(DartclawServer? server, Database? searchDb, AgentHarness? harness) async {
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

  /// Writes sample log rotation configs for newsyslog (macOS) and logrotate
  /// (Linux).
  static void writeLogRotationSamples(String logsDir) {
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

    _log.info('Log rotation configs generated in $logsDir');
  }
}

/// Whether any search provider is enabled with a non-empty API key.
bool _hasSearchProvider(DartclawConfig config) {
  return config.searchProviders.values.any((p) => p.enabled && p.apiKey.isNotEmpty);
}
