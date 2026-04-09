import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' as config_tools;
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart' show ensureDartclawGoogleChatRegistered;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'serve_command.dart';
import 'wiring/channel_wiring.dart';
import 'wiring/harness_wiring.dart';
import 'wiring/scheduling_wiring.dart';
import 'wiring/security_wiring.dart';
import 'wiring/storage_wiring.dart';
import 'wiring/task_wiring.dart';
import 'wiring/project_wiring.dart';

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
  final ProjectService projectService;
  final ConfigNotifier configNotifier;

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
    required this.projectService,
    required this.configNotifier,
  });
}

/// Thin coordinator that composes domain-specific wiring modules in dependency
/// order and returns a [WiringResult] for [ServeCommand].
///
/// Domain modules ([StorageWiring], [SecurityWiring], [HarnessWiring],
/// [ChannelWiring], [TaskWiring], [SchedulingWiring]) own service construction.
/// This class threads cross-domain dependencies and performs the final server
/// build and MCP tool registration.
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

  /// Constructs all services, wires them together via [DartclawServerBuilder],
  /// and registers MCP tools on the built server.
  ///
  /// Returns a [WiringResult] containing everything [ServeCommand.run] needs
  /// to start the HTTP server, print the startup banner, and wire shutdown.
  Future<WiringResult> wire() async {
    ensureDartclawGoogleChatRegistered();

    final eventBus = EventBus();
    // Create ConfigNotifier — holds live config, notifies registered services on reload.
    final configNotifier = ConfigNotifier(config);

    // 0. Projects — initialize before other services to allow project-aware wiring.
    final project = ProjectWiring(config: config, dataDir: dataDir, eventBus: eventBus);
    await project.wire();

    // 1. Storage — databases, sessions, messages, memory, KV, QMD.
    final storage = StorageWiring(
      config: config,
      eventBus: eventBus,
      searchDbFactory: searchDbFactory,
      taskDbFactory: taskDbFactory,
      exitFn: exitFn,
    );
    await storage.wire();

    // Derive agent definitions early — needed by both SecurityWiring (guard
    // chain per-agent policies) and HarnessWiring (MCP initialize payload).
    final agentDefs = config.agent.definitions.isNotEmpty ? config.agent.definitions : [AgentDefinition.searchAgent()];

    // 2. Security — guards, audit, content classifier, container setup.
    final security = SecurityWiring(
      config: config,
      dataDir: dataDir,
      eventBus: eventBus,
      exitFn: exitFn,
      configNotifier: configNotifier,
      messageRedactor: messageRedactor,
    );
    await security.wire(agentDefs: agentDefs);

    // 3. Harness — agent harness pool, turn runners, behavior, context, auth.
    final harness = HarnessWiring(
      config: config,
      dataDir: dataDir,
      port: port,
      harnessFactory: harnessFactory,
      exitFn: exitFn,
      storage: storage,
      security: security,
      messageRedactor: messageRedactor,
      eventBus: eventBus,
      configNotifier: configNotifier,
    );
    // Server ref resolved lazily — closures in harness capture the getter.
    late DartclawServer serverRef;
    // TurnManager resolved lazily — built after channel wiring completes but
    // before any inbound channel messages arrive.
    late TurnManager serverTurns;
    await harness.wire(serverRefGetter: () => serverRef);

    // 4. Tasks (pre-server) — review handler needed by ChannelWiring.
    final task = TaskWiring(config: config, dataDir: dataDir, eventBus: eventBus, storage: storage, project: project);
    await task.wirePreServer();

    // 5. Channels — channel manager, WhatsApp, Signal, Google Chat, space events.
    final channel = ChannelWiring(
      config: config,
      dataDir: dataDir,
      port: port,
      eventBus: eventBus,
      storage: storage,
      task: task,
      resolvedConfigPath: resolvedConfigPath,
    );
    await channel.wire(
      serverRefGetter: () => serverRef,
      turnManagerGetter: () => serverTurns,
      sseBroadcast: harness.sseBroadcast,
      messageRedactor: messageRedactor,
      healthService: harness.healthService,
      budgetEnforcer: harness.budgetEnforcer,
    );
    _configureBudgetWarningNotifiers(
      pool: harness.pool,
      sessions: storage.sessions,
      taskService: storage.taskService,
      channelManager: channel.channelManager,
    );
    _configureLoopDetectionNotifiers(
      pool: harness.pool,
      sessions: storage.sessions,
      taskService: storage.taskService,
      channelManager: channel.channelManager,
    );

    Channel? lookupAlertChannel(String channelTypeName) {
      final manager = channel.channelManager;
      if (manager == null) return null;
      for (final candidate in manager.channels) {
        if (candidate.type.name == channelTypeName) {
          return candidate;
        }
      }
      return null;
    }

    final alertRouter = AlertRouter(
      bus: eventBus,
      adapter: AlertDeliveryAdapter(lookupAlertChannel),
      config: config.alerts,
      taskLookup: storage.taskService.get,
    );
    configNotifier.register(alertRouter);

    // 6. Build server — all pre-server deps known, now create the HTTP server.
    final configWriter = config_tools.ConfigWriter(configPath: resolvedConfigPath);

    // Detect and clear restart.pending from previous graceful restart.
    final restartPendingFile = File(p.join(dataDir, 'restart.pending'));
    if (restartPendingFile.existsSync()) {
      try {
        final content = jsonDecode(restartPendingFile.readAsStringSync()) as Map<String, dynamic>;
        final fields = (content['fields'] as List?)?.join(', ') ?? 'unknown';
        stderrLine('Restarted after config change (pending: $fields)');
      } catch (e) {
        _log.fine('Could not parse restart.pending file, using generic message', e);
        stderrLine('Restarted after config change');
      }
      restartPendingFile.deleteSync();
    }

    final providerStatus = ProviderStatusService(
      providers: config.providers,
      registry: CredentialRegistry(credentials: config.credentials, env: Platform.environment),
      defaultProvider: config.agent.provider,
      pool: harness.pool,
    );
    await providerStatus.probe();
    final canvasService = config.canvas.enabled
        ? CanvasService(maxConnections: config.canvas.share.maxConnections)
        : null;
    WorkshopCanvasSubscriber? workshopCanvasSubscriber;
    AdvisorSubscriber? advisorSubscriber;

    final builder = DartclawServerBuilder()
      ..sessions = storage.sessions
      ..messages = storage.messages
      ..traceService = storage.traceService
      ..taskEventService = storage.taskEventService
      ..worker = harness.harness
      ..staticDir = config.server.staticDir
      ..behavior = harness.behavior
      ..memoryFile = storage.memoryFile
      ..guardChain = security.guardChain
      ..kv = storage.kvService
      ..healthService = harness.healthService
      ..tokenService = harness.tokenService
      ..lockManager = harness.lockManager
      ..resetService = harness.resetService
      ..contextMonitor = harness.contextMonitor
      ..explorationSummarizer = harness.explorationSummarizer
      ..channelManager = channel.channelManager
      ..whatsAppChannel = channel.whatsAppChannel
      ..googleChatWebhookHandler = channel.googleChatWebhookHandler
      ..signalChannel = channel.signalChannel
      ..webhookSecret = channel.webhookSecret
      ..redactor = messageRedactor
      ..gatewayToken = harness.resolvedGatewayToken
      ..selfImprovement = harness.selfImprovement
      ..usageTracker = harness.usageTracker
      ..eventBus = eventBus
      ..canvasService = canvasService
      ..authEnabled = harness.authEnabled
      ..pool = harness.pool
      ..contentGuardDisplay = ContentGuardDisplayParams(
        enabled: config.security.contentGuardEnabled,
        classifier: config.security.contentGuardClassifier,
        model: config.security.contentGuardModel,
        maxBytes: config.security.contentGuardMaxBytes,
        apiKeyConfigured:
            config.security.contentGuardClassifier == 'claude_binary' ||
            (Platform.environment['ANTHROPIC_API_KEY']?.isNotEmpty ?? false),
        failOpen: security.contentGuardFailOpen,
      )
      ..heartbeatDisplay = HeartbeatDisplayParams(
        enabled: config.scheduling.heartbeatEnabled,
        intervalMinutes: config.scheduling.heartbeatIntervalMinutes,
      )
      ..workspaceDisplay = WorkspaceDisplayParams(path: config.workspaceDir)
      ..appDisplay = AppDisplayParams(name: config.server.name, dataDir: dataDir);

    // TurnManager built here — needed by TaskWiring (post-server) and
    // SchedulingWiring. Assigned to the late variable captured by the
    // emergency stop closure in ChannelWiring.
    serverTurns = builder.buildTurns();
    await serverTurns.detectAndCleanOrphanedTurns();
    configNotifier.register(serverTurns);

    // 7. Tasks (post-server) — executor, artifacts, observer — need live turns.
    await task.wirePostServer(turns: serverTurns, pool: harness.pool, onSpawnNeeded: harness.onSpawnNeeded);

    // Workflow service — wired after task executor so TaskService is live.
    final workflowService = WorkflowService(
      repository: storage.workflowRunRepository,
      taskService: storage.taskService,
      messageService: storage.messages,
      turnManager: serverTurns,
      eventBus: eventBus,
      kvService: storage.kvService,
      dataDir: dataDir,
    );
    await workflowService.recoverIncompleteRuns();

    // Skill registry — discover Agent Skills from 6 prioritized sources.
    final skillRegistry = SkillRegistryImpl();
    final activeProject = config.projects.definitions.values.firstOrNull;
    skillRegistry.discover(
      projectDir: activeProject != null ? p.join(config.projectsClonesDir, activeProject.id) : null,
      workspaceDir: config.workspaceDir,
      dataDir: dataDir,
    );

    // Workflow registry — load built-in workflows, then discover custom ones
    // from workspace and per-project directories.
    final continuityProviders = harness.pool.runners
        .where((r) => r.harness.supportsSessionContinuity)
        .map((r) => r.providerId)
        .toSet();
    final workflowRegistry = WorkflowRegistry(
      parser: WorkflowDefinitionParser(),
      validator: WorkflowDefinitionValidator(),
      continuityProviders: continuityProviders,
    );
    workflowRegistry.skillRegistry = skillRegistry;
    workflowRegistry.loadBuiltIn();
    await workflowRegistry.loadFromDirectory(p.join(config.workspaceDir, 'workflows'));
    for (final projectDef in config.projects.definitions.values) {
      final projectCloneDir = p.join(config.projectsClonesDir, projectDef.id);
      await workflowRegistry.loadFromDirectory(p.join(projectCloneDir, 'workflows'));
    }

    // Thread binding reconciliation — prune bindings for terminal tasks.
    final threadBindingStore = channel.threadBindingStore;
    ThreadBindingLifecycleManager? lifecycleManager;
    if (threadBindingStore != null) {
      final allTasks = await storage.taskService.list();
      final activeIds = allTasks.where((t) => !t.status.terminal).map((t) => t.id).toSet();
      final pruned = await threadBindingStore.reconcile(activeIds);
      if (pruned > 0) {
        _log.info('Pruned $pruned stale thread binding(s) during startup reconciliation');
      }

      // Start lifecycle manager — auto-unbind on terminal task states + idle timeout cleanup.
      final idleTimeoutMinutes = config.features.threadBinding.idleTimeoutMinutes;
      lifecycleManager = ThreadBindingLifecycleManager(
        store: threadBindingStore,
        eventBus: eventBus,
        idleTimeout: Duration(minutes: idleTimeoutMinutes),
      );
      lifecycleManager.start();
      _log.info('ThreadBindingLifecycleManager started (idle timeout: ${idleTimeoutMinutes}m)');
    }

    // Push-back feedback delivery — delivers feedback as a new turn to the task's session.
    // Only available when thread binding is enabled (threadBindingStore is non-null).
    PushBackFeedbackDelivery? pushBackFeedbackDelivery;
    if (threadBindingStore != null) {
      pushBackFeedbackDelivery = ({required taskId, required sessionKey, required feedback}) async {
        final session = await storage.sessions.getOrCreateByKey(sessionKey, type: SessionType.channel);
        final messages = [
          {'role': 'user', 'content': feedback},
        ];
        await serverRef.turns.startTurn(session.id, messages, source: 'push-back');
      };
    }
    task.setPushBackFeedbackDelivery(pushBackFeedbackDelivery);

    // 8. Scheduling — cron, heartbeat, maintenance, delivery, git sync.
    final scheduling = SchedulingWiring(
      config: config,
      eventBus: eventBus,
      storage: storage,
      channel: channel,
      security: security,
      sseBroadcast: harness.sseBroadcast,
      configNotifier: configNotifier,
    );
    await scheduling.wire(serverRefGetter: () => serverRef, turns: serverTurns, contextMonitor: harness.contextMonitor);

    // Scope reconciler — reacts to ConfigChangedEvent to update live scope.
    final scopeReconciler = config_tools.ScopeReconciler(liveScopeConfig: LiveScopeConfig(config.sessions.scopeConfig));
    scopeReconciler.subscribe(eventBus);

    // Pre-create group sessions for allowlisted groups.
    final groupSessionInit = GroupSessionInitializer(
      sessions: storage.sessions,
      eventBus: eventBus,
      channelConfigs: channel.channelGroupConfigs,
      displayNameResolver: (channelType, groupId) async {
        if (channelType != 'googlechat') return null;
        final googleChatChannel = channel.googleChatChannel;
        if (googleChatChannel == null) return null;
        final space = await googleChatChannel.restClient.getSpace(groupId);
        return space?.displayName;
      },
    );
    await groupSessionInit.initialize();

    // Set remaining runtime deps on the builder and build the server.
    final restartService = RestartService(
      turns: serverTurns,
      drainDeadline: const Duration(seconds: 30),
      exit: exitFn,
      broadcastSse: harness.sseBroadcast.broadcast,
      writeRestartPending: writeRestartPending,
      dataDir: dataDir,
    );

    builder
      ..heartbeat = scheduling.heartbeat
      ..scheduleService = scheduling.scheduleService
      ..gitSync = scheduling.gitSync
      ..runtimeConfig = scheduling.runtimeConfig
      ..memoryStatusService = scheduling.memoryStatusService
      ..memoryPruner = scheduling.memoryPruner
      ..configWriter = configWriter
      ..config = config
      ..configNotifier = configNotifier
      ..restartService = restartService
      ..sseBroadcast = harness.sseBroadcast
      ..providerStatus = providerStatus
      ..projectService = project.projectService
      ..goalService = storage.goalService
      ..taskService = storage.taskService
      ..taskReviewService = task.taskReviewService
      ..worktreeManager = task.worktreeManager
      ..taskFileGuard = task.taskFileGuard
      ..agentObserver = task.agentObserver
      ..mergeExecutor = task.mergeExecutor
      ..mergeStrategy = config.tasks.worktreeMergeStrategy
      ..baseRef = config.tasks.worktreeBaseRef
      ..spaceEventsWiring = channel.spaceEventsWiring
      ..threadBindingStore = channel.threadBindingStore
      ..workflowService = workflowService
      ..workflowDefinitionSource = workflowRegistry
      ..skillRegistry = skillRegistry
      ..schedulingDisplay = SchedulingDisplayParams(
        jobs: scheduling.displayJobs,
        systemJobNames: scheduling.systemJobNames,
        scheduledTasks: config.scheduling.taskDefinitions,
      );

    final server = serverFactory(builder);
    serverRef = server;

    // Register MCP tools on the internal MCP server (/mcp HTTP endpoint).
    final handlers = harness.memoryHandlers;
    server.registerTool(SessionsSendTool(delegate: harness.sessionDelegate));
    server.registerTool(SessionsSpawnTool(delegate: harness.sessionDelegate));
    server.registerTool(MemorySaveTool(handler: handlers.onSave));
    server.registerTool(MemorySearchTool(handler: handlers.onSearch));
    server.registerTool(MemoryReadTool(handler: handlers.onRead));
    server.registerTool(
      WebFetchTool(classifier: security.contentClassifier, failOpenOnClassification: security.contentGuardFailOpen),
    );
    if (canvasService != null) {
      server.registerTool(
        CanvasTool(
          canvasService: canvasService,
          sessionKey: SessionKey.webSession(),
          baseUrl: config.server.baseUrl,
          defaultPermission: config.canvas.share.defaultPermission == 'view'
              ? CanvasPermission.view
              : CanvasPermission.interact,
          defaultTtl: Duration(minutes: config.canvas.share.defaultTtlMinutes),
        ),
      );
    }

    if (canvasService != null &&
        (config.canvas.workshopMode.taskBoard ||
            config.canvas.workshopMode.showContributorStats ||
            config.canvas.workshopMode.showBudgetBar)) {
      workshopCanvasSubscriber = WorkshopCanvasSubscriber(
        canvasService: canvasService,
        taskService: storage.taskService,
        usageTracker: harness.usageTracker,
        sessionKey: SessionKey.webSession(),
        dailyBudgetTokens: config.governance.budget.dailyTokens,
        serverStartTime: DateTime.now(),
        taskBoardEnabled: config.canvas.workshopMode.taskBoard,
        statsBarEnabled: config.canvas.workshopMode.showContributorStats || config.canvas.workshopMode.showBudgetBar,
        threadBindings: channel.threadBindingStore,
      );
      workshopCanvasSubscriber.subscribe(eventBus);
    }

    if (config.advisor.enabled) {
      advisorSubscriber = AdvisorSubscriber(
        pool: harness.pool,
        sessions: storage.sessions,
        taskService: storage.taskService,
        channelManager: channel.channelManager,
        eventBus: eventBus,
        traceService: storage.traceService,
        threadBindings: channel.threadBindingStore,
        canvasService: canvasService,
        canvasSessionKey: SessionKey.webSession(),
        triggers: config.advisor.triggers,
        periodicIntervalMinutes: config.advisor.periodicIntervalMinutes,
        maxWindowTurns: config.advisor.maxWindowTurns,
        maxPriorReflections: config.advisor.maxPriorReflections,
        model: config.advisor.model,
        effort: config.advisor.effort,
      );
      advisorSubscriber.subscribe();
    }

    // Register search tools based on config.
    for (final entry in config.search.providers.entries) {
      final providerName = entry.key;
      final providerConfig = entry.value;
      if (!providerConfig.enabled || providerConfig.apiKey.isEmpty) continue;

      switch (providerName) {
        case 'brave':
          server.registerTool(
            BraveSearchTool(
              provider: BraveSearchProvider(apiKey: providerConfig.apiKey),
              contentGuard: security.contentGuard,
            ),
          );
          _log.info('Registered brave_search MCP tool');
        case 'tavily':
          server.registerTool(
            TavilySearchTool(
              provider: TavilySearchProvider(apiKey: providerConfig.apiKey),
              contentGuard: security.contentGuard,
            ),
          );
          _log.info('Registered tavily_search MCP tool');
        default:
          _log.warning('Unknown search provider: $providerName — skipping');
      }
    }

    // Start Space Events Pub/Sub pipeline.
    if (channel.spaceEventsWiring != null) {
      await channel.spaceEventsWiring!.start();
    }

    return WiringResult(
      server: server,
      searchDb: storage.searchDb,
      taskService: storage.taskService,
      harness: harness.harness,
      pool: harness.pool,
      heartbeat: scheduling.heartbeat,
      scheduleService: scheduling.scheduleService,
      kvService: storage.kvService,
      resetService: harness.resetService,
      selfImprovement: harness.selfImprovement,
      qmdManager: storage.qmdManager,
      channelManager: channel.channelManager,
      authEnabled: harness.authEnabled,
      tokenService: harness.tokenService,
      eventBus: eventBus,
      containerManagers: security.containerManagers,
      projectService: project.projectService,
      configNotifier: configNotifier,
      shutdownExtras: () async {
        lifecycleManager?.dispose();
        await workflowService.dispose();
        await task.dispose();
        await alertRouter.cancel();
        await channel.taskNotificationSubscriber?.dispose();
        await security.dispose();
        groupSessionInit.dispose();
        await scopeReconciler.cancel();
        await storage.turnStateStore.dispose();
        await scheduling.dispose();
        await project.dispose();
        await workshopCanvasSubscriber?.dispose();
        await advisorSubscriber?.dispose();
      },
    );
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
    } catch (e) {
      _log.fine('Error during server/harness shutdown', e);
    }
    try {
      await taskService?.dispose();
    } catch (e) {
      _log.fine('Error disposing task service', e);
    }
    try {
      searchDb?.close();
    } catch (e) {
      _log.fine('Error closing search database', e);
    }
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

  void _configureBudgetWarningNotifiers({
    required HarnessPool pool,
    required SessionService sessions,
    required TaskService taskService,
    required ChannelManager? channelManager,
  }) {
    if (channelManager == null) {
      return;
    }

    for (final runner in pool.runners) {
      runner.budgetWarningNotifier = (sessionId, result) async {
        await _notifyChannelBudgetWarning(
          sessionId: sessionId,
          result: result,
          sessions: sessions,
          taskService: taskService,
          channelManager: channelManager,
        );
      };
    }
  }

  Future<void> _notifyChannelBudgetWarning({
    required String sessionId,
    required BudgetCheckResult result,
    required SessionService sessions,
    required TaskService taskService,
    required ChannelManager channelManager,
  }) async {
    final suffix = result.decision == BudgetDecision.block ? ' New turns will be blocked until the budget resets.' : '';
    final text =
        'Warning: daily token budget is at ${result.percentage}% (${result.tokensUsed}/${result.budget} tokens).$suffix';
    await _sendNotificationToOriginChannel(
      sessionId: sessionId,
      text: text,
      label: 'budget warning',
      sessions: sessions,
      taskService: taskService,
      channelManager: channelManager,
    );
  }

  /// Sends a best-effort notification to the channel that originated [sessionId].
  ///
  /// Resolves the originating channel via task origin or session key fallback.
  /// Failures are logged and swallowed — notifications are non-critical.
  Future<void> _sendNotificationToOriginChannel({
    required String sessionId,
    required String text,
    required String label,
    required SessionService sessions,
    required TaskService taskService,
    required ChannelManager channelManager,
  }) async {
    final route = await _resolveChannelRoute(sessionId: sessionId, sessions: sessions, taskService: taskService);
    if (route == null) return;

    Channel? targetChannel;
    for (final candidate in channelManager.channels) {
      if (candidate.type == route.channelType) {
        targetChannel = candidate;
        break;
      }
    }
    if (targetChannel == null) return;

    try {
      await targetChannel.sendMessage(route.recipientId, ChannelResponse(text: text));
    } catch (error, stackTrace) {
      _log.warning(
        'Failed to send $label notification to ${route.channelType.name}:${route.recipientId}',
        error,
        stackTrace,
      );
    }
  }

  Future<({ChannelType channelType, String recipientId})?> _resolveChannelRoute({
    required String sessionId,
    required SessionService sessions,
    required TaskService taskService,
  }) async {
    final tasks = await taskService.list();
    for (final task in tasks) {
      if (task.sessionId != sessionId) continue;

      final origin = TaskOrigin.fromConfigJson(task.configJson);
      if (origin == null) continue;

      final channelType = ChannelType.values.asNameMap()[origin.channelType];
      if (channelType != null) {
        return (channelType: channelType, recipientId: origin.recipientId);
      }
    }

    final session = await sessions.getSession(sessionId);
    final channelKey = session?.channelKey;
    if (channelKey == null || channelKey.isEmpty) return null;

    try {
      final parsed = SessionKey.parse(channelKey);
      final parts = parsed.identifiers.split(':');
      if (parts.isEmpty) return null;

      final channelTypeName = Uri.decodeComponent(parts.first);
      final channelType = ChannelType.values.asNameMap()[channelTypeName];
      if (channelType == null) return null;

      return switch (parsed.scope) {
        'dm' when parts.length == 2 && parts.first != 'contact' => (
          channelType: channelType,
          recipientId: Uri.decodeComponent(parts[1]),
        ),
        'group' when parts.length >= 2 => (channelType: channelType, recipientId: Uri.decodeComponent(parts[1])),
        _ => null,
      };
    } on FormatException catch (error, stackTrace) {
      _log.warning('Failed to parse session key for channel route: $channelKey', error, stackTrace);
      return null;
    }
  }

  void _configureLoopDetectionNotifiers({
    required HarnessPool pool,
    required SessionService sessions,
    required TaskService taskService,
    required ChannelManager? channelManager,
  }) {
    if (channelManager == null) {
      return;
    }

    for (final runner in pool.runners) {
      runner.loopDetectionNotifier = (sessionId, detection, action) async {
        await _notifyChannelLoopDetection(
          sessionId: sessionId,
          detection: detection,
          action: action,
          sessions: sessions,
          taskService: taskService,
          channelManager: channelManager,
        );
      };
    }
  }

  Future<void> _notifyChannelLoopDetection({
    required String sessionId,
    required LoopDetection detection,
    required String action,
    required SessionService sessions,
    required TaskService taskService,
    required ChannelManager channelManager,
  }) async {
    final suffix = action == 'abort' ? ' The task has been cancelled.' : '';
    final text = 'Loop detected: ${detection.message}. Action: $action.$suffix';
    await _sendNotificationToOriginChannel(
      sessionId: sessionId,
      text: text,
      label: 'loop detection',
      sessions: sessions,
      taskService: taskService,
      channelManager: channelManager,
    );
  }
}
