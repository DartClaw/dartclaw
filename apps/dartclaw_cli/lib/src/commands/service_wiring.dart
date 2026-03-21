// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dartclaw_config/dartclaw_config.dart' as config_tools;
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_core/src/container/credential_proxy.dart';
import 'package:dartclaw_core/src/container/docker_validator.dart';
import 'package:dartclaw_core/src/container/security_profile.dart';
import 'package:dartclaw_core/src/events/session_lifecycle_subscriber.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
import 'package:dartclaw_server/src/behavior/behavior_file_service.dart';
import 'package:dartclaw_server/src/behavior/heartbeat_scheduler.dart';
import 'package:dartclaw_server/src/behavior/self_improvement_service.dart';
import 'package:dartclaw_server/src/maintenance/session_maintenance_service.dart';
import 'package:dartclaw_server/src/observability/usage_tracker.dart';
import 'package:dartclaw_server/src/workspace/workspace_git_sync.dart';
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
  final TaskService taskService;
  final AgentHarness harness;
  final HarnessPool pool;
  final HeartbeatScheduler? heartbeat;
  final ScheduleService? scheduleService;
  final KvService kvService;
  final SessionResetService resetService;
  final SelfImprovementService selfImprovement;
  final QmdManager? qmdManager;
  final ChannelManager? channelManager;
  final bool authEnabled;
  final TokenService? tokenService;
  final EventBus eventBus;
  final Map<String, ContainerManager> containerManagers;
  final Future<void> Function() shutdownExtras;

  const WiringResult({
    required this.server,
    required this.searchDb,
    required this.taskService,
    required this.harness,
    required this.pool,
    required this.heartbeat,
    required this.scheduleService,
    required this.kvService,
    required this.resetService,
    required this.selfImprovement,
    required this.qmdManager,
    required this.channelManager,
    required this.authEnabled,
    required this.tokenService,
    required this.eventBus,
    required this.containerManagers,
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
  final TaskDbFactory taskDbFactory;
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
    required this.taskDbFactory,
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
    // Event bus — constructed early, disposed on shutdown. S11 will inject
    // into services that fire events.
    final eventBus = EventBus();

    // Construct file-based services
    Directory(config.sessionsDir).createSync(recursive: true);

    ensureDartclawGoogleChatRegistered();

    final sessions = SessionService(baseDir: config.sessionsDir, eventBus: eventBus);
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

    Database taskDb;
    try {
      taskDb = taskDbFactory(config.tasksDbPath);
    } catch (_) {
      try {
        searchDb.close();
      } catch (_) {}
      _log.severe('Cannot open task database at ${config.tasksDbPath}');
      exitFn(1);
    }

    final taskRepository = SqliteTaskRepository(taskDb);
    final goalRepository = SqliteGoalRepository(taskDb);
    final goalService = GoalService(goalRepository);
    final taskService = TaskService(taskRepository);

    late final TurnStateStore turnStateStore;
    final stateDbPath = p.join(config.server.dataDir, 'state.db');
    try {
      Directory(config.server.dataDir).createSync(recursive: true);
      final stateDb = sqlite3.open(stateDbPath);
      try {
        turnStateStore = TurnStateStore(stateDb);
      } catch (_) {
        stateDb.close();
        rethrow;
      }
    } catch (_) {
      await taskService.dispose();
      searchDb.close();
      _log.severe('Cannot open turn state database at $stateDbPath');
      exitFn(1);
    }

    // Memory stack (MEMORY.md now lives in workspace/)
    final memoryFile = MemoryFileService(baseDir: config.workspaceDir);
    final memory = MemoryService(searchDb);

    // QMD hybrid search (optional -- requires `qmd` binary)
    QmdManager? qmdManager;
    if (config.search.backend == 'qmd') {
      final mgr = QmdManager(host: config.search.qmdHost, port: config.search.qmdPort, workspaceDir: config.workspaceDir);
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
      backend: config.search.backend,
      memoryService: memory,
      qmdManager: qmdManager,
      defaultDepth: config.search.defaultDepth,
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
      maxMemoryBytes: config.memory.maxBytes,
      compactInstructions: config.context.compactInstructions,
    );

    final staticPrompt = await behavior.composeStaticPrompt();

    // Build agent definitions before HarnessConfig so default search agent
    // model is included in the initialize handshake.
    final agentDefs = config.agent.definitions.isNotEmpty ? config.agent.definitions : [AgentDefinition.searchAgent()];
    final agentMap = {for (final a in agentDefs) a.id: a};
    final agentsPayload = {for (final a in agentDefs) a.id: a.toInitializePayload()};

    // Resolve gateway token early so it's available for MCP config in HarnessConfig.
    final authEnabled = config.gateway.authMode != 'none';
    String? resolvedGatewayToken;
    if (authEnabled) {
      resolvedGatewayToken = config.gateway.token ?? TokenService.loadFromFile(dataDir);
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
        userDisallowed: config.agent.disallowedTools,
      ),
      maxTurns: config.agent.maxTurns,
      model: config.agent.model,
      effort: config.agent.effort,
      agents: agentsPayload,
      appendSystemPrompt: staticPrompt,
      mcpServerUrl: resolvedGatewayToken != null ? 'http://127.0.0.1:$port/mcp' : null,
      mcpGatewayToken: resolvedGatewayToken,
    );

    CredentialProxy? credentialProxy;
    ContainerHealthMonitor? containerHealthMonitor;
    final containerManagers = <String, ContainerManager>{};
    if (config.container.enabled) {
      final validationErrors = DockerValidator.validate(config.container);
      if (validationErrors.isNotEmpty) {
        for (final err in validationErrors) {
          _log.severe('Container config rejected: $err');
        }
        exitFn(1);
      }

      final apiKey = Platform.environment['ANTHROPIC_API_KEY']?.trim();
      String? hostClaudeJsonPath;
      if (apiKey == null || apiKey.isEmpty) {
        final authResult = await Process.run(config.server.claudeExecutable, ['auth', 'status']);
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

      final profiles = [
        SecurityProfile.workspace(workspaceDir: config.workspaceDir, projectDir: Directory.current.path),
        SecurityProfile.restricted,
      ];
      final proxySocketDir = p.join(dataDir, 'proxy');
      for (final profile in profiles) {
        containerManagers[profile.id] = ContainerManager(
          config: config.container,
          containerName: ContainerManager.generateName(dataDir, profile.id),
          profileId: profile.id,
          workspaceMounts: profile.workspaceMounts,
          proxySocketDir: proxySocketDir,
          hostClaudeJsonPath: hostClaudeJsonPath,
          buildContextDir: Directory.current.path,
          workingDir: profile.id == SecurityProfile.restricted.id ? '/tmp' : '/project',
        );
      }
      final workspaceContainerManager = containerManagers['workspace']!;

      if (!await workspaceContainerManager.isDockerAvailable()) {
        _log.severe('Docker is required when container.enabled: true');
        _log.severe('Install or start Docker: https://docs.docker.com/get-docker/');
        exitFn(1);
      }

      credentialProxy = CredentialProxy(socketPath: p.join(dataDir, 'proxy', 'proxy.sock'), apiKey: apiKey);
      await credentialProxy.start();

      try {
        await workspaceContainerManager.ensureImage();
        for (final entry in containerManagers.entries) {
          await entry.value.start();
          eventBus.fire(
            ContainerStartedEvent(
              profileId: entry.key,
              containerName: entry.value.containerName,
              timestamp: DateTime.now(),
            ),
          );
        }
      } catch (e) {
        for (final manager in containerManagers.values) {
          try {
            await manager.stop();
          } catch (_) {}
        }
        await credentialProxy.stop();
        rethrow;
      }

      containerHealthMonitor = ContainerHealthMonitor(containerManagers: containerManagers, eventBus: eventBus);
      containerHealthMonitor.start();

      _log.info(
        'Container isolation enabled — ${containerManagers.length} profiles (image: ${config.container.image})',
      );
    } else {
      _log.warning(
        'Container isolation disabled — agent has full host access. '
        'Guards are the only security boundary. '
        'Enable container isolation for production use (see docs/guide/security.md).',
      );
    }

    final harness = harnessFactory(
      Directory.current.path,
      claudeExecutable: config.server.claudeExecutable,
      turnTimeout: Duration(seconds: config.server.workerTimeout),
      onMemorySave: handlers.onSave,
      onMemorySearch: handlers.onSearch,
      onMemoryRead: handlers.onRead,
      harnessConfig: harnessConfig,
      containerManager: containerManagers['workspace'],
    );
    try {
      await harness.start();
    } catch (e) {
      _log.severe('Failed to start harness: $e');
      await memoryFile.dispose();
      await turnStateStore.dispose();
      for (final manager in containerManagers.values) {
        try {
          await manager.stop();
        } catch (_) {}
      }
      await credentialProxy?.stop();
      await teardown(null, searchDb, harness, taskService);
      exitFn(1);
    }

    // Create additional harnesses for background task execution.
    // `tasks.max_concurrent` excludes the primary interactive runner.
    final taskHarnesses = <AgentHarness>[];
    final taskProfileIds = <String>[];
    final maxConcurrent = config.tasks.maxConcurrent;
    final profileIds = containerManagers.isEmpty ? ['workspace'] : ['workspace', 'restricted'];
    final taskRunnerCount = maxConcurrent == 0
        ? 0
        : (containerManagers.isEmpty ? maxConcurrent : max(maxConcurrent, profileIds.length));
    for (var i = 0; i < taskRunnerCount; i++) {
      final profileId = profileIds[i % profileIds.length];
      final containerManager = containerManagers[profileId] ?? containerManagers['workspace'];
      final taskHarness = harnessFactory(
        Directory.current.path,
        claudeExecutable: config.server.claudeExecutable,
        turnTimeout: Duration(seconds: config.server.workerTimeout),
        onMemorySave: handlers.onSave,
        onMemorySearch: handlers.onSearch,
        onMemoryRead: handlers.onRead,
        harnessConfig: harnessConfig,
        containerManager: containerManager,
      );
      try {
        await taskHarness.start();
        taskHarnesses.add(taskHarness);
        taskProfileIds.add(profileId);
      } catch (e) {
        _log.warning('Failed to start task harness ${i + 1} of $taskRunnerCount: $e');
        // Degraded mode: continue with fewer task runners.
      }
    }
    if (taskHarnesses.isNotEmpty) {
      _log.info('Task pool: ${taskHarnesses.length} task runner(s) + 1 primary');
    }

    // Build ToolPolicyCascade from agent definitions
    final agentAllow = <String, Set<String>>{};
    final agentDeny = <String, Set<String>>{};
    for (final agent in agentDefs) {
      if (agent.allowedTools.isNotEmpty) agentAllow[agent.id] = agent.allowedTools;
      if (agent.deniedTools.isNotEmpty) agentDeny[agent.id] = agent.deniedTools;
    }
    final toolPolicyCascade = ToolPolicyCascade(
      globalDeny: config.agent.disallowedTools.toSet(),
      agentDeny: agentDeny,
      agentAllow: agentAllow,
    );

    // Construct guard chain with per-guard YAML configs
    final auditLogger = GuardAuditLogger(dataDir: dataDir);
    final guardChain = config.security.guards.enabled
        ? GuardChain(
            failOpen: config.security.guards.failOpen,
            guards: [
              InputSanitizer(
                config: config.security.guardsYaml['input_sanitizer'] is Map
                    ? InputSanitizerConfig.fromYaml(
                        Map<String, dynamic>.from(config.security.guardsYaml['input_sanitizer'] as Map),
                      )
                    : InputSanitizerConfig(
                        enabled: config.security.inputSanitizerEnabled,
                        channelsOnly: config.security.inputSanitizerChannelsOnly,
                        patterns: InputSanitizerConfig.defaults().patterns,
                      ),
              ),
              CommandGuard(
                config: config.security.guardsYaml['command'] is Map
                    ? CommandGuardConfig.fromYaml(Map<String, dynamic>.from(config.security.guardsYaml['command'] as Map))
                    : CommandGuardConfig.defaults(),
              ),
              FileGuard(
                config:
                    (config.security.guardsYaml['file'] is Map
                            ? FileGuardConfig.fromYaml(Map<String, dynamic>.from(config.security.guardsYaml['file'] as Map))
                            : FileGuardConfig.defaults())
                        .withSelfProtection(p.join(dataDir, 'dartclaw.yaml')),
              ),
              NetworkGuard(
                config: config.security.guardsYaml['network'] is Map
                    ? NetworkGuardConfig.fromYaml(Map<String, dynamic>.from(config.security.guardsYaml['network'] as Map))
                    : NetworkGuardConfig.defaults(),
              ),
              ToolPolicyGuard(cascade: toolPolicyCascade),
            ],
            onVerdict: (name, category, verdict, message, ctx) {
              eventBus.fire(
                GuardBlockEvent(
                  guardName: name,
                  guardCategory: category,
                  verdict: verdict,
                  verdictMessage: message,
                  hookPoint: ctx.hookPoint,
                  sessionId: ctx.sessionId,
                  channel: ctx.source,
                  peerId: ctx.peerId,
                  timestamp: ctx.timestamp,
                ),
              );
            },
          )
        : null;

    // Wire guard audit subscriber — bridges GuardBlockEvent to NDJSON logger.
    final guardAuditSubscriber = GuardAuditSubscriber(auditLogger);
    guardAuditSubscriber.subscribe(eventBus);

    // Wire session lifecycle subscriber — structured logging for create/end.
    final sessionLifecycleSubscriber = SessionLifecycleSubscriber();
    sessionLifecycleSubscriber.subscribe(eventBus);

    // ContentGuard: classifier selection based on config
    ContentClassifier? contentClassifier;
    var contentGuardFailOpen = false;
    ContentGuard? contentGuard;
    if (config.security.contentGuardEnabled) {
      if (config.security.contentGuardClassifier == 'anthropic_api') {
        final apiKey = Platform.environment['ANTHROPIC_API_KEY'];
        if (apiKey != null && apiKey.isNotEmpty) {
          contentClassifier = AnthropicApiClassifier(apiKey: apiKey, model: config.security.contentGuardModel);
        } else {
          _log.warning(
            'ANTHROPIC_API_KEY not set — content guard disabled. '
            'Set the environment variable or switch to classifier: claude_binary.',
          );
        }
      } else {
        // Default: claude_binary -- works with OAuth, no API key needed
        contentClassifier = ClaudeBinaryClassifier(
          claudeExecutable: config.server.claudeExecutable,
          model: config.security.contentGuardModel,
        );
        contentGuardFailOpen = true;
      }

      if (contentClassifier != null) {
        contentGuard = ContentGuard(
          classifier: contentClassifier,
          maxContentBytes: config.security.contentGuardMaxBytes,
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

    try {
      final legacyTurnState = await kvService.getByPrefix('turn:');
      if (legacyTurnState.isNotEmpty) {
        for (final key in legacyTurnState.keys) {
          await kvService.delete(key);
        }
        _log.info('Removed ${legacyTurnState.length} legacy turn-state KV key(s)');
      }
    } catch (e, st) {
      _log.warning('Failed to remove legacy turn-state KV keys', e, st);
    }

    // Usage tracking (fire-and-forget, never blocks turns)
    final usageTracker = UsageTracker(
      dataDir: dataDir,
      kv: kvService,
      budgetWarningTokens: config.usage.budgetWarningTokens,
      maxFileSizeBytes: config.usage.maxFileSizeBytes,
    );

    // Health service
    final healthService = HealthService(
      worker: harness,
      searchDbPath: config.searchDbPath,
      sessionsDir: config.sessionsDir,
      tasksDir: p.join(config.server.dataDir, 'tasks'),
      usageTracker: usageTracker,
    );

    // Gateway auth (token already resolved earlier for HarnessConfig MCP wiring).
    TokenService? tokenService;

    if (authEnabled) {
      tokenService = TokenService(token: resolvedGatewayToken!);
    } else {
      final host = config.server.host;
      final isLoopback = host == 'localhost' || host == '127.0.0.1';
      if (isLoopback) {
        _log.warning('Auth disabled on loopback — acceptable for local dev only');
      } else {
        _log.severe('CRITICAL: Auth disabled on network-accessible host $host');
      }
    }

    // Context management
    final contextMonitor = ContextMonitor(
      reserveTokens: config.context.reserveTokens,
      warningThreshold: config.context.warningThreshold,
    );
    final explorationSummarizer = ExplorationSummarizer(
      trimmer: ResultTrimmer(maxBytes: config.context.maxResultBytes),
      thresholdTokens: config.context.explorationSummaryThreshold,
    );

    // Concurrency + reset
    final lockManager = SessionLockManager(maxParallel: config.server.maxParallelTurns);
    final resetService = SessionResetService(
      sessions: sessions,
      messages: messages,
      resetHour: config.sessions.resetHour,
      idleTimeoutMinutes: config.sessions.idleTimeoutMinutes,
    );

    final mergeExecutor = MergeExecutor(
      projectDir: Directory.current.path,
      defaultStrategy: config.tasks.worktreeMergeStrategy == 'merge' ? MergeStrategy.merge : MergeStrategy.squash,
    );
    final taskFileGuard = TaskFileGuard();
    final worktreeManager = WorktreeManager(
      dataDir: dataDir,
      projectDir: Directory.current.path,
      baseRef: config.tasks.worktreeBaseRef,
      staleTimeoutHours: config.tasks.worktreeStaleTimeoutHours,
      worktreesDir: p.join(config.workspaceDir, '.dartclaw', 'worktrees'),
    );
    await worktreeManager.detectStaleWorktrees();
    final taskReviewService = TaskReviewService(
      tasks: taskService,
      eventBus: eventBus,
      worktreeManager: worktreeManager,
      taskFileGuard: taskFileGuard,
      mergeExecutor: mergeExecutor,
      dataDir: dataDir,
      mergeStrategy: config.tasks.worktreeMergeStrategy,
      baseRef: config.tasks.worktreeBaseRef,
    );
    final reviewHandler = taskReviewService.channelReviewHandler(trigger: 'channel');

    // Channel + message queue (H-01: S14-S15 wiring)
    final waConfig = config.channels.channelConfigs['whatsapp'];
    final sigConfig = config.channels.channelConfigs['signal'];
    final googleChatConfig = config.getChannelConfig<GoogleChatConfig>(ChannelType.googlechat);
    WhatsAppConfig? parsedWhatsAppConfig;
    SignalConfig? parsedSignalConfig;
    if (waConfig != null) {
      final warns = <String>[];
      parsedWhatsAppConfig = WhatsAppConfig.fromYaml(waConfig, warns);
      for (final w in warns) {
        _log.warning(w);
      }
    }
    if (sigConfig != null) {
      final warns = <String>[];
      parsedSignalConfig = SignalConfig.fromYaml(sigConfig, warns);
      for (final w in warns) {
        _log.warning('Signal config: $w');
      }
    }
    final googleChatEnabled = googleChatConfig.enabled;
    final waEnabled = parsedWhatsAppConfig?.enabled ?? false;
    final sigEnabled = parsedSignalConfig?.enabled ?? false;
    final taskTriggerConfigs = <ChannelType, TaskTriggerConfig>{
      if (parsedWhatsAppConfig != null) ChannelType.whatsapp: parsedWhatsAppConfig.taskTrigger,
      if (parsedSignalConfig != null) ChannelType.signal: parsedSignalConfig.taskTrigger,
      ChannelType.googlechat: googleChatConfig.taskTrigger,
    };

    ChannelManager? channelManager;
    WhatsAppChannel? whatsAppChannel;
    GoogleChatChannel? googleChatChannel;
    GoogleChatWebhookHandler? googleChatWebhookHandler;
    SignalChannel? signalChannel;
    String? webhookSecret;
    final liveScopeConfig = LiveScopeConfig(config.sessions.scopeConfig);

    if (waEnabled || sigEnabled || googleChatEnabled) {
      channelManager = _buildChannelManager(
        config: config,
        liveScopeConfig: liveScopeConfig,
        sessions: sessions,
        messages: messages,
        serverRef: () => serverRef,
        redactor: messageRedactor,
        taskCreator: taskService.create,
        taskLister: taskService.list,
        reviewCommandParser: const ReviewCommandParser(),
        reviewHandler: reviewHandler,
        eventBus: eventBus,
        taskTriggerConfigs: taskTriggerConfigs,
      );
    }

    if (waEnabled && channelManager != null) {
      try {
        final parsedConfig = parsedWhatsAppConfig!;
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
          osName: config.server.name,
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

    GoogleChatSpaceEventsWiring? spaceEventsWiring;
    if (googleChatEnabled && channelManager != null) {
      try {
        final activeChannelManager = channelManager;
        final audience = googleChatConfig.audience;
        if (audience == null) {
          throw StateError('Google Chat audience is required when the channel is enabled');
        }

        final credentialJson = await GcpAuthService.resolveCredentialJsonAsync(
          configValue: googleChatConfig.serviceAccount,
        );
        if (credentialJson == null) {
          throw StateError('Google Chat service account credentials could not be resolved');
        }

        final authClient = await GcpAuthService(
          serviceAccountJson: credentialJson,
          scopes: const ['https://www.googleapis.com/auth/chat.bot'],
        ).initialize();
        final googleChatDmAccess = DmAccessController(
          mode: googleChatConfig.dmAccess,
          allowlist: googleChatConfig.dmAllowlist.toSet(),
        );
        final googleChatMentionGating = MentionGating(
          requireMention: googleChatConfig.requireMention,
          mentionPatterns: const [],
          ownJid: googleChatConfig.botUser ?? '',
        );
        final channel = GoogleChatChannel(
          config: googleChatConfig,
          restClient: GoogleChatRestClient(authClient: authClient),
          channelManager: activeChannelManager,
          dmAccess: googleChatDmAccess,
          mentionGating: googleChatMentionGating,
        );
        final slashCommandParser = const SlashCommandParser();
        final slashCommandHandler = SlashCommandHandler(
          taskService: taskService,
          sessionService: sessions,
          eventBus: eventBus,
          channelManager: activeChannelManager,
          defaultTaskType: googleChatConfig.taskTrigger.defaultType,
          autoStartTasks: googleChatConfig.taskTrigger.autoStart,
        );

        // Phase 1: Create dedup + subscription manager before webhook handler
        // so they can be passed as optional dependencies.
        MessageDeduplicator? deduplicator;
        WorkspaceEventsManager? subscriptionManager;
        if (googleChatConfig.spaceEvents.enabled && googleChatConfig.pubsub.isConfigured) {
          try {
            deduplicator = MessageDeduplicator();
            final pubsubAuthClient = await GcpAuthService(
              serviceAccountJson: credentialJson,
              scopes: const [
                'https://www.googleapis.com/auth/chat.bot',
                'https://www.googleapis.com/auth/chat.spaces.readonly',
                'https://www.googleapis.com/auth/pubsub',
              ],
            ).initialize();
            subscriptionManager = WorkspaceEventsManager(
              authClient: pubsubAuthClient,
              config: googleChatConfig.spaceEvents,
              dataDir: dataDir,
            );
            _log.info('Space Events infrastructure initialized (dedup + subscription manager)');
          } catch (e) {
            _log.warning('Failed to initialize Space Events infrastructure: $e — space events disabled');
            deduplicator = null;
            subscriptionManager = null;
          }
        } else if (googleChatConfig.spaceEvents.enabled && !googleChatConfig.pubsub.isConfigured) {
          _log.warning(
            'space_events.enabled is true but pubsub is not configured — '
            'Space Events disabled. Configure pubsub.project_id and pubsub.subscription.',
          );
        }

        final webhookHandler = GoogleChatWebhookHandler(
          channel: channel,
          jwtVerifier: GoogleJwtVerifier(audience: audience),
          config: googleChatConfig,
          channelManager: activeChannelManager,
          reviewHandler: reviewHandler,
          dmAccess: googleChatDmAccess,
          mentionGating: googleChatMentionGating,
          eventBus: eventBus,
          trustedProxies: config.auth.trustedProxies,
          slashCommandParser: slashCommandParser,
          slashCommandHandler: slashCommandHandler,
          deduplicator: deduplicator,
          subscriptionManager: subscriptionManager,
          dispatchMessage: (message) => _dispatchInboundChannelMessage(
            channelManager: activeChannelManager,
            sessions: sessions,
            messages: messages,
            serverRef: () => serverRef,
            message: message,
          ),
        );

        // Phase 2: Create PubSubClient + full wiring (needs dedup, adapter, channelManager).
        if (deduplicator != null && subscriptionManager != null) {
          try {
            final adapter = CloudEventAdapter(botUser: googleChatConfig.botUser);
            // Auth client for PubSub was already created above; subscription manager holds it.
            // Create a fresh PubSub-scoped auth client here using the same credentials.
            final pubsubAuthClient = await GcpAuthService(
              serviceAccountJson: credentialJson,
              scopes: const [
                'https://www.googleapis.com/auth/chat.bot',
                'https://www.googleapis.com/auth/chat.spaces.readonly',
                'https://www.googleapis.com/auth/pubsub',
              ],
            ).initialize();
            final pubSubClient = PubSubClient.fromConfig(
              authClient: pubsubAuthClient,
              config: googleChatConfig.pubsub,
              onMessage: (message) async {
                final wiring = spaceEventsWiring;
                if (wiring == null) return true;
                return wiring.processMessage(message);
              },
            );
            spaceEventsWiring = GoogleChatSpaceEventsWiring(
              pubSubClient: pubSubClient,
              subscriptionManager: subscriptionManager,
              adapter: adapter,
              deduplicator: deduplicator,
              channelManager: activeChannelManager,
            );
            _log.info('Space Events Pub/Sub wiring created');

            // Inject Pub/Sub health reporter now that wiring is available.
            final activeSubManager = subscriptionManager;
            healthService.pubsubReporter = PubSubHealthReporter(
              client: pubSubClient,
              subscriptionCount: () => activeSubManager.activeSubscriptionCount,
              enabled: true,
            );
          } catch (e) {
            _log.warning('Failed to create Space Events Pub/Sub wiring: $e');
          }
        }

        activeChannelManager.registerChannel(channel);
        googleChatChannel = channel;
        googleChatWebhookHandler = webhookHandler;
        _log.info('Google Chat channel registered');
      } catch (e) {
        _log.warning('Failed to initialize Google Chat channel: $e');
      }
    }

    // Create ConfigWriter for persistent config editing.
    final configWriter = config_tools.ConfigWriter(configPath: resolvedConfigPath);

    // Signal channel wiring
    if (sigEnabled && channelManager != null) {
      try {
        final activeSignalConfig = parsedSignalConfig!;

        final sidecar = SignalCliManager(
          executable: activeSignalConfig.executable,
          host: activeSignalConfig.host,
          port: activeSignalConfig.port,
          phoneNumber: activeSignalConfig.phoneNumber,
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
          mode: activeSignalConfig.dmAccess,
          allowlist: activeSignalConfig.dmAllowlist.toSet(),
        );
        final sigMentionGating = SignalMentionGating(
          requireMention: activeSignalConfig.requireMention,
          mentionPatterns: activeSignalConfig.mentionPatterns,
          ownNumber: activeSignalConfig.phoneNumber,
        );

        final sigChannel = SignalChannel(
          sidecar: sidecar,
          config: activeSignalConfig,
          dmAccess: sigDmAccess,
          mentionGating: sigMentionGating,
          channelManager: channelManager,
          dataDir: dataDir,
        );
        channelManager.registerChannel(sigChannel);
        signalChannel = sigChannel;
        _log.info('Signal channel registered');
      } catch (e) {
        _log.warning('Failed to initialize Signal channel: $e');
      }
    }

    TaskNotificationSubscriber? taskNotificationSubscriber;
    if (channelManager != null) {
      taskNotificationSubscriber = TaskNotificationSubscriber(tasks: taskService, channelManager: channelManager);
      taskNotificationSubscriber.subscribe(eventBus);
    }

    // Mutable display list for scheduling UI (includes both user-configured
    // and built-in jobs). Starts as a copy of the raw config maps, excluding
    // task-type entries (those appear in the scheduledTasks section instead).
    final displayJobs = config.scheduling.jobs
        .where((j) => (j['type'] as String?) != 'task')
        .map((j) => Map<String, dynamic>.of(j))
        .toList();
    // Names of system-registered jobs (rendered read-only with SYSTEM badge).
    final systemJobNames = <String>['heartbeat'];

    // SSE broadcast instance — shared across runners so any runner can emit
    // global events (e.g., context_warning) to all connected web clients.
    final sseBroadcast = SseBroadcast();

    // Build HarnessPool: primary runner (index 0) + task runners (1..N-1).
    // All runners share the same service instances (SessionLockManager prevents
    // concurrent turns on the same session across runners).
    final runners = <TurnRunner>[
      TurnRunner(
        harness: harness,
        messages: messages,
        behavior: behavior,
        memoryFile: memoryFile,
        sessions: sessions,
        turnState: turnStateStore,
        kv: kvService,
        guardChain: guardChain,
        lockManager: lockManager,
        resetService: resetService,
        contextMonitor: contextMonitor,
        explorationSummarizer: explorationSummarizer,
        redactor: messageRedactor,
        selfImprovement: selfImprovement,
        usageTracker: usageTracker,
        sseBroadcast: sseBroadcast,
      ),
      for (var i = 0; i < taskHarnesses.length; i++)
        TurnRunner(
          harness: taskHarnesses[i],
          messages: messages,
          behavior: behavior,
          memoryFile: memoryFile,
          sessions: sessions,
          turnState: turnStateStore,
          kv: kvService,
          guardChain: guardChain,
          lockManager: lockManager,
          resetService: resetService,
          contextMonitor: contextMonitor,
          explorationSummarizer: explorationSummarizer,
          redactor: messageRedactor,
          selfImprovement: selfImprovement,
          usageTracker: usageTracker,
          sseBroadcast: sseBroadcast,
          profileId: taskProfileIds[i],
        ),
    ];
    final pool = HarnessPool(runners: runners, maxConcurrentTasks: maxConcurrent);

    final server = serverFactory(
      sessions: sessions,
      messages: messages,
      worker: harness,
      staticDir: config.server.staticDir,
      behavior: behavior,
      memoryFile: memoryFile,
      guardChain: guardChain,
      kv: kvService,
      healthService: healthService,
      tokenService: tokenService,
      lockManager: lockManager,
      resetService: resetService,
      contextMonitor: contextMonitor,
      explorationSummarizer: explorationSummarizer,
      channelManager: channelManager,
      whatsAppChannel: whatsAppChannel,
      googleChatWebhookHandler: googleChatWebhookHandler,
      signalChannel: signalChannel,
      webhookSecret: webhookSecret,
      redactor: messageRedactor,
      gatewayToken: resolvedGatewayToken,
      selfImprovement: selfImprovement,
      usageTracker: usageTracker,
      eventBus: eventBus,
      authEnabled: authEnabled,
      pool: pool,
      contentGuardDisplay: ContentGuardDisplayParams(
        enabled: config.security.contentGuardEnabled,
        classifier: config.security.contentGuardClassifier,
        model: config.security.contentGuardModel,
        maxBytes: config.security.contentGuardMaxBytes,
        apiKeyConfigured:
            config.security.contentGuardClassifier == 'claude_binary' ||
            (Platform.environment['ANTHROPIC_API_KEY']?.isNotEmpty ?? false),
        failOpen: contentGuardFailOpen,
      ),
      heartbeatDisplay: HeartbeatDisplayParams(
        enabled: config.scheduling.heartbeatEnabled,
        intervalMinutes: config.scheduling.heartbeatIntervalMinutes,
      ),
      schedulingDisplay: SchedulingDisplayParams(
        jobs: displayJobs,
        systemJobNames: systemJobNames,
        scheduledTasks: config.scheduling.taskDefinitions,
      ),
      workspaceDisplay: WorkspaceDisplayParams(path: config.workspaceDir),
      appDisplay: AppDisplayParams(name: config.server.name, dataDir: dataDir),
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
    for (final entry in config.search.providers.entries) {
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

    // Parse scheduled jobs from config.
    // Task-type jobs are handled by ScheduledTaskRunner below — skip them here.
    final scheduledJobs = <ScheduledJob>[];
    for (final jobConfig in config.scheduling.jobs) {
      try {
        final job = ScheduledJob.fromConfig(jobConfig);
        if (job.jobType != ScheduledJobType.task) {
          scheduledJobs.add(job);
        }
      } catch (e) {
        _log.warning('Invalid scheduled job config: $e — skipping');
      }
    }

    // Register memory pruner as a built-in scheduled job
    MemoryPruner? memoryPruner;
    if (config.memory.pruningEnabled) {
      final pruner = memoryPruner = MemoryPruner(
        workspaceDir: config.workspaceDir,
        memoryService: memory,
        archiveAfterDays: config.memory.archiveAfterDays,
      );
      scheduledJobs.add(
        ScheduledJob(
          id: 'memory-pruner',
          scheduleType: ScheduleType.cron,
          cronExpression: CronExpression.parse(config.memory.pruningSchedule),
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
        'schedule': config.memory.pruningSchedule,
        'delivery': 'none',
        'status': 'active',
      });
      systemJobNames.add('memory-pruner');
      _log.info(
        'Memory pruner scheduled (${config.memory.pruningSchedule}, '
        'archive after ${config.memory.archiveAfterDays}d)',
      );
    }

    // Register session maintenance as a built-in scheduled job (F13)
    final maintSchedule = config.sessions.maintenanceConfig.schedule;
    if (maintSchedule.isNotEmpty && maintSchedule != 'disabled') {
      try {
        final cronExpr = CronExpression.parse(maintSchedule);
        scheduledJobs.add(
          ScheduledJob(
            id: 'session-maintenance',
            scheduleType: ScheduleType.cron,
            cronExpression: cronExpr,
            onExecute: () async {
              // Protect ALL channel-type sessions when any channel is active
              final channelSessions = await sessions.listSessions(type: SessionType.channel);
              final activeChannelKeys = <String>{};
              if (channelManager != null && channelManager.channels.isNotEmpty) {
                for (final s in channelSessions) {
                  if (s.channelKey != null) {
                    activeChannelKeys.add(s.channelKey!);
                  }
                }
              }

              final maintenance = SessionMaintenanceService(
                sessions: sessions,
                config: config.sessions.maintenanceConfig,
                activeChannelKeys: activeChannelKeys,
                activeJobIds: scheduledJobs.map((j) => j.id).toSet(),
                sessionsDir: config.sessionsDir,
                taskService: taskService,
                artifactRetentionDays: config.tasks.artifactRetentionDays,
                dataDir: config.server.dataDir,
              );
              final report = await maintenance.run();
              _log.info(
                'Maintenance complete: '
                '${report.sessionsArchived} archived, '
                '${report.sessionsDeleted} deleted, '
                '${_formatBytes(report.diskReclaimedBytes)} reclaimed, '
                '${report.artifactsDeleted} artifacts deleted '
                '(${_formatBytes(report.artifactDiskReclaimedBytes)} reclaimed)',
              );
              for (final w in report.warnings) {
                _log.warning('Maintenance warning: $w');
              }
              if (config.security.guardAuditMaxRetentionDays > 0) {
                final deletedAuditFiles = await auditLogger.cleanOldFiles(config.security.guardAuditMaxRetentionDays);
                _log.info('Audit cleanup: $deletedAuditFiles old files deleted');
              }
              return 'archived=${report.sessionsArchived} deleted=${report.sessionsDeleted}';
            },
          ),
        );
        displayJobs.add({
          'name': 'session-maintenance',
          'schedule': maintSchedule,
          'delivery': 'none',
          'status': 'active',
        });
        systemJobNames.add('session-maintenance');
        _log.info('Session maintenance scheduled ($maintSchedule)');
      } on FormatException catch (e) {
        _log.warning('Invalid maintenance schedule "$maintSchedule": $e — maintenance disabled');
      }
    }

    // Register automation scheduled tasks (S13).
    // Task definitions are displayed in the scheduledTasks section of the
    // scheduling template (via config.scheduling.taskDefinitions), so no
    // displayJobs entries are added here.
    if (config.scheduling.taskDefinitions.isNotEmpty) {
      final taskRunner = ScheduledTaskRunner(
        taskService: taskService,
        definitions: config.scheduling.taskDefinitions,
        eventBus: eventBus,
      );
      final taskJobs = taskRunner.buildJobs();
      scheduledJobs.addAll(taskJobs);
      if (taskJobs.isNotEmpty) {
        _log.info('Registered ${taskJobs.length} automation scheduled task(s)');
      }
    }

    Future<void> dispatchSystemTurn(String sessionKey, String message) async {
      await _dispatchTurn(
        sessions,
        () => server,
        sessionKey,
        message,
        type: SessionType.cron,
        source: 'heartbeat',
        agentName: 'heartbeat',
      );
    }

    final memoryConsolidator = MemoryConsolidator(
      workspaceDir: config.workspaceDir,
      dispatch: dispatchSystemTurn,
      threshold: config.memory.maxBytes,
    );

    // Start cron scheduler
    ScheduleService? scheduleService;
    ChannelManager? fallbackDeliveryChannelManager;
    if (scheduledJobs.isNotEmpty) {
      final deliveryChannelManager =
          channelManager ??
          (fallbackDeliveryChannelManager = ChannelManager(
            queue: MessageQueue(dispatcher: (sessionKey, message, {senderJid}) async => ''),
            config: const ChannelConfig.defaults(),
          ));
      final deliveryService = DeliveryService(
        channelManager: deliveryChannelManager,
        sseBroadcast: sseBroadcast,
        sessions: sessions,
      );
      scheduleService = ScheduleService(
        turns: server.turns,
        sessions: sessions,
        jobs: scheduledJobs,
        delivery: deliveryService,
        consolidator: memoryConsolidator,
      );
      scheduleService.start();
    }

    // Workspace git sync
    WorkspaceGitSync? gitSync;
    if (config.workspace.gitSyncEnabled) {
      gitSync = WorkspaceGitSync(workspaceDir: config.workspaceDir, pushEnabled: config.workspace.gitSyncPushEnabled);
      if (await gitSync.isGitAvailable()) {
        await gitSync.initIfNeeded();
        _log.info('Workspace git sync enabled');
      } else {
        gitSync = null;
      }
    }

    // Heartbeat scheduler
    HeartbeatScheduler? heartbeat;
    if (config.scheduling.heartbeatEnabled) {
      heartbeat = HeartbeatScheduler(
        interval: Duration(minutes: config.scheduling.heartbeatIntervalMinutes),
        workspaceDir: config.workspaceDir,
        dispatch: dispatchSystemTurn,
        gitSync: gitSync,
        consolidator: memoryConsolidator,
      );
      heartbeat.start();
      _log.info('Heartbeat scheduler started (${config.scheduling.heartbeatIntervalMinutes}m interval)');
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

    final diffGenerator = DiffGenerator(projectDir: Directory.current.path);
    final artifactCollector = ArtifactCollector(
      tasks: taskService,
      messages: messages,
      sessionsDir: config.sessionsDir,
      dataDir: dataDir,
      workspaceDir: Directory.current.path,
      diffGenerator: diffGenerator,
      baseRef: config.tasks.worktreeBaseRef,
    );
    final containerTaskFailureSubscriber = ContainerTaskFailureSubscriber(tasks: taskService);
    containerTaskFailureSubscriber.subscribe(eventBus);
    final agentObserver = AgentObserver(pool: pool, eventBus: eventBus);
    final taskExecutor = TaskExecutor(
      tasks: taskService,
      goals: goalService,
      sessions: sessions,
      messages: messages,
      turns: server.turns,
      artifactCollector: artifactCollector,
      eventBus: eventBus,
      worktreeManager: worktreeManager,
      taskFileGuard: taskFileGuard,
      observer: agentObserver,
    );
    taskExecutor.start();

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

    // Create restart service.
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
    final runtimeConfig = RuntimeConfig(
      heartbeatEnabled: config.scheduling.heartbeatEnabled,
      gitSyncEnabled: config.workspace.gitSyncEnabled,
      gitSyncPushEnabled: config.workspace.gitSyncPushEnabled,
    );

    // Wire config change subscriber — handles live field side-effects.
    final configChangeSubscriber = ConfigChangeSubscriber(
      runtimeConfig: runtimeConfig,
      heartbeat: heartbeat,
      gitSync: gitSync,
      contextMonitor: contextMonitor,
    );
    configChangeSubscriber.subscribe(eventBus);
    final scopeReconciler = config_tools.ScopeReconciler(liveScopeConfig: liveScopeConfig);
    scopeReconciler.subscribe(eventBus);

    // Pre-create sessions for allowlisted groups so they appear in sidebar immediately.
    final channelGroupConfigs = <ChannelGroupConfig>[];
    if (whatsAppChannel != null) {
      final waConf = whatsAppChannel.config;
      channelGroupConfigs.add(
        ChannelGroupConfig(
          channelType: 'whatsapp',
          groupAccessEnabled: waConf.groupAccess != GroupAccessMode.disabled,
          groupAllowlist: waConf.groupAllowlist,
        ),
      );
    }
    if (signalChannel != null) {
      final sigConf = signalChannel.config;
      channelGroupConfigs.add(
        ChannelGroupConfig(
          channelType: 'signal',
          groupAccessEnabled: sigConf.groupAccess != SignalGroupAccessMode.disabled,
          groupAllowlist: sigConf.groupAllowlist,
        ),
      );
    }
    if (googleChatChannel != null) {
      final gcConf = googleChatChannel.config;
      channelGroupConfigs.add(
        ChannelGroupConfig(
          channelType: 'googlechat',
          groupAccessEnabled: gcConf.groupAccess != GroupAccessMode.disabled,
          groupAllowlist: gcConf.groupAllowlist,
        ),
      );
    }
    final groupSessionInit = GroupSessionInitializer(
      sessions: sessions,
      eventBus: eventBus,
      channelConfigs: channelGroupConfigs,
    );
    await groupSessionInit.initialize();

    server.setRuntimeServices(
      heartbeat: heartbeat,
      scheduleService: scheduleService,
      gitSync: gitSync,
      runtimeConfig: runtimeConfig,
      memoryStatusService: memoryStatusService,
      memoryPruner: memoryPruner,
      kvService: kvService,
      configWriter: configWriter,
      config: config,
      restartService: restartService,
      sseBroadcast: sseBroadcast,
      eventBus: eventBus,
      goalService: goalService,
      taskService: taskService,
      taskReviewService: taskReviewService,
      worktreeManager: worktreeManager,
      taskFileGuard: taskFileGuard,
      agentObserver: agentObserver,
      mergeExecutor: mergeExecutor,
      mergeStrategy: config.tasks.worktreeMergeStrategy,
      baseRef: config.tasks.worktreeBaseRef,
      spaceEventsWiring: spaceEventsWiring,
    );

    // Start Space Events pipeline (Pub/Sub pull loop + subscription reconciliation).
    if (spaceEventsWiring != null) {
      await spaceEventsWiring.start();
    }

    return WiringResult(
      server: server,
      searchDb: searchDb,
      taskService: taskService,
      harness: harness,
      pool: pool,
      heartbeat: heartbeat,
      scheduleService: scheduleService,
      kvService: kvService,
      resetService: resetService,
      selfImprovement: selfImprovement,
      qmdManager: qmdManager,
      channelManager: channelManager,
      authEnabled: authEnabled,
      tokenService: tokenService,
      eventBus: eventBus,
      containerManagers: containerManagers,
      shutdownExtras: () async {
        await spaceEventsWiring?.dispose();
        await taskExecutor.stop();
        agentObserver.dispose();
        await taskNotificationSubscriber?.dispose();
        await containerTaskFailureSubscriber.dispose();
        await containerHealthMonitor?.stop();
        groupSessionInit.dispose();
        await scopeReconciler.cancel();
        await turnStateStore.dispose();
        for (final entry in containerManagers.entries) {
          try {
            await entry.value.stop();
            eventBus.fire(
              ContainerStoppedEvent(
                profileId: entry.key,
                containerName: entry.value.containerName,
                timestamp: DateTime.now(),
              ),
            );
          } catch (_) {}
        }
        await fallbackDeliveryChannelManager?.dispose();
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
    required LiveScopeConfig liveScopeConfig,
    required SessionService sessions,
    required MessageService messages,
    required DartclawServer? Function() serverRef,
    MessageRedactor? redactor,
    TaskCreator? taskCreator,
    TaskLister? taskLister,
    ReviewCommandParser? reviewCommandParser,
    ChannelReviewHandler? reviewHandler,
    EventBus? eventBus,
    Map<ChannelType, TaskTriggerConfig> taskTriggerConfigs = const {},
  }) {
    final messageQueue = MessageQueue(
      debounceWindow: config.channels.debounceWindow,
      maxConcurrentTurns: config.server.maxParallelTurns,
      maxQueueDepth: config.channels.maxQueueDepth,
      defaultRetryPolicy: config.channels.defaultRetryPolicy,
      redactor: redactor,
      dispatcher: (sessionKey, message, {String? senderJid}) async {
        return _dispatchChannelTurn(
          sessions: sessions,
          messages: messages,
          serverRef: serverRef,
          sessionKey: sessionKey,
          message: message,
          senderJid: senderJid,
        );
      },
    );
    return ChannelManager(
      queue: messageQueue,
      config: config.channels,
      liveScopeConfig: liveScopeConfig,
      taskCreator: taskCreator,
      taskLister: taskLister,
      reviewCommandParser: reviewCommandParser,
      reviewHandler: reviewHandler,
      triggerParser: const TaskTriggerParser(),
      eventBus: eventBus,
      taskTriggerConfigs: taskTriggerConfigs,
    );
  }

  static Future<String> _dispatchInboundChannelMessage({
    required ChannelManager channelManager,
    required SessionService sessions,
    required MessageService messages,
    required DartclawServer? Function() serverRef,
    required ChannelMessage message,
  }) {
    return _dispatchChannelTurn(
      sessions: sessions,
      messages: messages,
      serverRef: serverRef,
      sessionKey: channelManager.deriveSessionKey(message),
      message: message.text,
      senderJid: message.senderJid,
    );
  }

  static Future<String> _dispatchChannelTurn({
    required SessionService sessions,
    required MessageService messages,
    required DartclawServer? Function() serverRef,
    required String sessionKey,
    required String message,
    String? senderJid,
  }) async {
    final session = await sessions.getOrCreateByKey(sessionKey, type: SessionType.channel);
    await messages.insertMessage(sessionId: session.id, role: 'user', content: message);

    if (session.title == null && senderJid != null) {
      await sessions.updateTitle(session.id, _channelSessionTitle(senderJid));
    }

    final userMsg = <String, dynamic>{'role': 'user', 'content': message};
    final srv = serverRef()!;
    final turnId = await srv.turns.startTurn(session.id, [userMsg], source: 'channel');
    final outcome = await srv.turns.waitForOutcome(session.id, turnId);
    return outcome.responseText ?? '';
  }

  static String _channelSessionTitle(String senderJid) {
    if (senderJid.contains('@')) {
      return 'WA › ${senderJid.split('@').first}';
    }
    if (senderJid.startsWith('users/')) {
      return 'Google Chat › ${senderJid.substring('users/'.length)}';
    }
    if (senderJid.startsWith('spaces/')) {
      return 'Google Chat › ${senderJid.substring('spaces/'.length)}';
    }
    if (senderJid.startsWith('+')) {
      return 'Signal › $senderJid';
    }
    return 'Signal › ${senderJid.substring(0, min(8, senderJid.length))}';
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

  /// Tears down server + DB-backed services without HTTP server (used when bind fails).
  ///
  /// Also used by [ServeCommand] for the same purpose.
  static Future<void> teardown(
    DartclawServer? server,
    Database? searchDb,
    AgentHarness? harness,
    TaskService? taskService,
  ) async {
    try {
      if (server != null) {
        await server.shutdown();
      } else if (harness != null) {
        await harness.stop();
      }
    } catch (_) {}
    try {
      await taskService?.dispose();
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
  return config.search.providers.values.any((p) => p.enabled && p.apiKey.isNotEmpty);
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
