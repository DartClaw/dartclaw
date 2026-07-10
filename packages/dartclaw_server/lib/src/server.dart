import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart'
    show
        MemoryPruner,
        MemoryService,
        TaskEventService,
        TemporalKnowledgeGraphService,
        TurnTraceService,
        WebhookDeliveryStore,
        openWebhookDeliveryStore;
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowDefinitionSource, WorkflowService;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';

import 'api/agent_routes.dart';
import 'api/chat_command_handler.dart';
import 'api/config_api_routes.dart';
import 'api/workflow_routes.dart';
import 'api/config_routes.dart';
import 'api/event_bus_sse_bridge.dart';
import 'api/google_chat_space_events_wiring.dart';
import 'api/google_chat_subscription_routes.dart';
import 'api/google_chat_webhook.dart';
import 'api/github_webhook.dart';
import 'api/goal_routes.dart';
import 'api/memory_routes.dart';
import 'api/project_routes.dart';
import 'api/provider_routes.dart';
import 'api/session_routes.dart';
import 'api/sse_broadcast.dart';
import 'api/task_routes.dart';
import 'api/task_sse_routes.dart';
import 'api/trace_routes.dart';
import 'api/webhook_routes.dart';
import 'audit/audit_log_reader.dart';
import 'auth/auth_middleware.dart';
import 'auth/auth_rate_limiter.dart';
import 'auth/origin_host_guard.dart';
import 'auth/security_headers.dart';
import 'auth/token_service.dart';
import 'asset_resolver.dart';
import 'behavior/heartbeat_scheduler.dart';
import 'health/health_service.dart';
import 'generated/embedded_assets.g.dart';
import 'memory/memory_status_service.dart';
import 'mcp/mcp_router.dart';
import 'mcp/mcp_server.dart';
import 'params/display_params.dart';
import 'provider_status_service.dart';
import 'restart_service.dart';
import 'runtime_config.dart';
import 'scheduling/schedule_service.dart';
import 'session/session_reset_service.dart';
import 'task/agent_observer.dart';
import 'task/goal_service.dart';
import 'task/merge_executor.dart';
import 'task/task_event_recorder.dart';
import 'task/task_progress_tracker.dart';
import 'task/task_file_guard.dart';
import 'task/task_review_service.dart';
import 'task/task_service.dart';
import 'task/worktree_manager.dart';
import 'templates/error_page.dart';
import 'embedded_static_handler.dart';
import 'templates/sidebar.dart' show NavItem, SidebarData, buildSidebar;
import 'turn_manager.dart' show TurnManager;
import 'web/dashboard_page.dart';
import 'web/page_registry.dart';
import 'web/sidebar_data_builder.dart';
import 'web/sidebar_feature_visibility.dart';
import 'web/signal_pairing_routes.dart';
import 'web/system_pages.dart';
import 'web/web_routes.dart';
import 'web/web_utils.dart';
import 'web/whatsapp_pairing_routes.dart';
import 'workspace/workspace_git_sync.dart';

part 'server_deps.dart';

/// Shelf-based HTTP server composing all DartClaw routes and middleware.
class DartclawServer {
  final ServerCoreDeps _core;
  final ServerTurnDeps _turn;
  final ServerChannelDeps _channels;
  final ServerTaskDeps _tasks;
  final ServerObservabilityDeps _observability;
  final ServerWebDeps _web;

  final McpProtocolHandler _mcpHandler;
  final PageRegistry _pageRegistry = PageRegistry();
  final AuthRateLimiter _authRateLimiter = AuthRateLimiter();
  Handler? _builtHandler;
  Handler? _requestHandler;
  bool _registrationLocked = false;

  TurnManager get turns => _turn.turns;
  ProviderStatusService? get providerStatus => _observability.providerStatus;
  TaskEventService? get taskEventService => _tasks.taskEventService;
  TaskEventRecorder? get taskEventRecorder => _tasks.taskEventRecorder;

  /// Internal constructor — prefer [DartclawServerBuilder] to assemble instances.
  DartclawServer.fromDeps({
    required ServerCoreDeps core,
    required ServerTurnDeps turn,
    required ServerChannelDeps channels,
    required ServerTaskDeps tasks,
    required ServerObservabilityDeps observability,
    required ServerWebDeps web,
  }) : _core = core,
       _turn = turn,
       _channels = channels,
       _tasks = tasks,
       _observability = observability,
       _web = web,
       _mcpHandler = McpProtocolHandler();

  /// Register an MCP tool that will be exposed to agents via the MCP endpoint.
  ///
  /// Must be called before the server starts handling requests. Throws
  /// [StateError] if called after the first MCP request has been processed.
  ///
  /// Duplicate tool names are silently skipped (first registration wins) with
  /// a warning logged. Registered tools appear in the MCP `tools/list`
  /// response and are dispatched via `tools/call`.
  void registerTool(McpTool tool) => _mcpHandler.registerTool(tool);

  /// Register a dashboard page that will appear in the sidebar nav.
  ///
  /// Must be called before the server starts handling requests.
  void registerDashboardPage(DashboardPage page) {
    if (_registrationLocked) {
      throw StateError('Cannot register dashboard pages after the server has started handling requests');
    }
    _pageRegistry.register(page);
  }

  /// Register a guard that is appended after the existing guard chain.
  ///
  /// Must be called before the server starts handling requests.
  void registerGuard(Guard guard) {
    if (_registrationLocked) {
      throw StateError('Cannot register guards after the server has started handling requests');
    }

    final guardChain = _core.guardChain;
    if (guardChain == null) {
      throw StateError('Cannot register guards without a guard chain');
    }

    guardChain.addGuard(guard);
  }

  /// Register a channel with the configured [ChannelManager].
  ///
  /// This only adds the channel to the manager. It does not auto-connect the
  /// channel or add any extra routes.
  ///
  /// Must be called before the server starts handling requests.
  void registerChannel(Channel channel) {
    if (_registrationLocked) {
      throw StateError('Cannot register channels after the server has started handling requests');
    }

    final channelManager = _channels.channelManager;
    if (channelManager == null) {
      throw StateError('Cannot register channels without a channel manager');
    }

    channelManager.registerChannel(channel);
  }

  /// Subscribe to runtime events emitted by the configured [EventBus].
  ///
  /// Must be called before the server starts handling requests.
  StreamSubscription<T> onEvent<T extends DartclawEvent>(void Function(T event) callback) {
    if (_registrationLocked) {
      throw StateError('Cannot register event listeners after the server has started handling requests');
    }

    final eventBus = _observability.eventBus;
    if (eventBus == null) {
      throw StateError('Cannot register event listeners without an event bus');
    }

    return eventBus.on<T>().listen(callback);
  }

  /// The MCP protocol handler, exposed for testing.
  McpProtocolHandler get mcpHandler => _mcpHandler;

  Future<void> _seedAndStartProgressTracker(TaskProgressTracker tracker) async {
    final taskService = _tasks.taskService;
    final taskEventService = _tasks.taskEventService;
    if (taskService == null || taskEventService == null) return;
    try {
      final runningTasks = await taskService.list(status: TaskStatus.running);
      for (final task in runningTasks) {
        final tokenBudget =
            (task.configJson['tokenBudget'] as num?)?.toInt() ?? (task.configJson['budget'] as num?)?.toInt();
        final events = taskEventService.listForTask(task.id);
        tracker.seedFromEvents(
          task.id,
          events.map((e) => {'kind': e.kind.name, 'details': Map<String, dynamic>.from(e.details)}).toList(),
          tokenBudget: tokenBudget,
        );
      }
    } catch (e) {
      // Non-critical — tracker still starts and processes new events.
    }
    tracker.start();
  }

  Future<void> shutdown() async {
    _tasks.progressTracker?.dispose();
    for (final sessionId in _turn.turns.activeSessionIds.toList()) {
      await _turn.turns.cancelTurn(sessionId);
    }
    await _channels.spaceEventsWiring?.dispose();
    await _observability.eventBusSseBridge?.cancel();
    await _observability.sseBroadcast?.dispose();
    await _channels.channelManager?.dispose();
    final pool = _turn.pool;
    if (pool != null) {
      await pool.dispose();
    } else {
      await _core.worker.dispose();
    }
    await _core.messages.dispose();
    await _observability.memoryFile?.dispose();
    await _core.configWriter?.dispose();
  }

  Handler get handler => _requestHandler ??= (Request request) {
    _builtHandler ??= _buildHandler();
    return _builtHandler!(request);
  };

  void _validateDependencies() {
    if (_tasks.taskService != null) {
      if (_tasks.worktreeManager == null) {
        throw StateError('taskService requires worktreeManager');
      }
      if (_tasks.taskFileGuard == null) {
        throw StateError('taskService requires taskFileGuard');
      }
      if (_tasks.mergeExecutor == null) {
        throw StateError('taskService requires mergeExecutor');
      }
      if (_tasks.agentObserver == null) {
        throw StateError('taskService requires agentObserver');
      }
    }

    if (_core.configWriter != null) {
      if (_core.restartService == null) {
        throw StateError('configWriter requires restartService');
      }
      if (_observability.sseBroadcast == null) {
        throw StateError('configWriter requires sseBroadcast');
      }
    }
  }

  Handler _buildHandler() {
    _validateDependencies();
    _registrationLocked = true;

    // Seed and start the progress tracker if available.
    final tracker = _tasks.progressTracker;
    if (tracker != null) {
      unawaited(_seedAndStartProgressTracker(tracker));
    }

    final router = Router();

    _mountHealthRoutes(router);
    _mountMcpRoutes(router);
    _mountStaticRoutes(router);
    _mountWebhookRoutes(router);
    _mountWhatsAppPairingRoutes(router);
    _mountSignalPairingRoutes(router);
    _mountConfigRoutes(router);
    _mountConfigApiRoutes(router);
    _mountProviderRoutes(router);
    _mountMemoryRoutes(router);
    _mountGoalRoutes(router);
    _mountProjectRoutes(router);
    _mountTaskRoutes(router);
    _mountWorkflowRoutes(router);
    _mountGoogleChatSubscriptionRoutes(router);
    _mountAgentRoutes(router);
    _mountSessionRoutes(router);
    _mountWebRoutes(router);

    return _buildPipeline(router);
  }

  void _mountHealthRoutes(Router router) {
    final hs = _core.healthService;
    if (hs != null) {
      router.get('/health', (Request request) async {
        final status = await hs.getStatus();
        return Response.ok(jsonEncode(status), headers: {'Content-Type': 'application/json'});
      });
    }
  }

  void _mountMcpRoutes(Router router) {
    final gt = _core.gatewayToken;
    if (gt != null) {
      router.post('/mcp', mcpRoute(_mcpHandler, gatewayToken: gt));
    }
  }

  void _mountStaticRoutes(Router router) {
    final handler = _core.assetSource == AssetSource.embedded
        ? createEmbeddedStaticHandler(embeddedServerAssets)
        : _filesystemStaticHandler();
    router.mount('/static/', handler);
  }

  Handler _filesystemStaticHandler() {
    final staticHandler = createStaticHandler(_core.staticDir!, defaultDocument: null);

    return (Request request) async {
      final response = await staticHandler(request);
      if (response.statusCode != 200) {
        return response;
      }

      final headers = Map<String, String>.from(response.headers);
      headers['Cache-Control'] = 'public, max-age=86400';
      return response.change(headers: headers);
    };
  }

  void _mountWebhookRoutes(Router router) {
    final githubWebhookHandler = _buildGitHubWebhookHandler();
    final webhookRouter = webhookRoutes(
      whatsApp: _channels.whatsAppChannel,
      webhookSecret: _core.webhookSecret,
      googleChat: _channels.googleChatWebhookHandler,
      github: githubWebhookHandler,
      eventBus: _observability.eventBus,
      trustedProxies: _core.config?.auth.trustedProxies ?? const [],
    );
    router.mount('/', webhookRouter.call);
  }

  GitHubWebhookHandler? _buildGitHubWebhookHandler() {
    final config = _core.config;
    final workflows = _web.workflowService;
    final definitions = _web.workflowDefinitionSource;
    if (config == null || workflows == null || definitions == null) {
      return null;
    }
    GitHubWebhookConfig? githubConfig;
    try {
      githubConfig = config.extension<GitHubWebhookConfig>('github');
    } catch (_) {
      githubConfig = null; // Extension absent or malformed — GitHub webhook disabled.
    }
    if (githubConfig == null || !githubConfig.enabled) {
      return null;
    }
    WebhookDeliveryStore? deliveryStore;
    final dataDir = _web.appDisplay.dataDir;
    if (dataDir != null) {
      deliveryStore = openWebhookDeliveryStore(p.join(dataDir, 'webhook_deliveries.db'));
    }
    return GitHubWebhookHandler(
      config: githubConfig,
      workflows: workflows,
      definitions: definitions,
      projects: _tasks.projectService,
      eventBus: _observability.eventBus,
      trustedProxies: config.auth.trustedProxies,
      deliveryStore: deliveryStore,
    );
  }

  void _mountWhatsAppPairingRoutes(Router router) {
    final waChannel = _channels.whatsAppChannel;
    if (waChannel != null) {
      final waRouter = whatsappPairingRoutes(
        whatsAppChannel: waChannel,
        sessions: _core.sessions,
        pageRegistry: _pageRegistry,
        tasksEnabled: _tasks.taskService != null && _observability.eventBus != null,
        appName: _web.appDisplay.name,
      );
      router.mount('/whatsapp', waRouter.call);
    }
  }

  void _mountSignalPairingRoutes(Router router) {
    final sigChannel = _channels.signalChannel;
    if (sigChannel != null) {
      final sigRouter = signalPairingRoutes(
        signalChannel: sigChannel,
        sessions: _core.sessions,
        pageRegistry: _pageRegistry,
        tasksEnabled: _tasks.taskService != null && _observability.eventBus != null,
        appName: _web.appDisplay.name,
      );
      router.mount('/signal', sigRouter.call);
    }
  }

  void _mountConfigRoutes(Router router) {
    final rc = _core.runtimeConfig;
    if (rc != null) {
      final cfgRouter = configRoutes(
        runtimeConfig: rc,
        heartbeat: _observability.heartbeat,
        scheduleService: _observability.scheduleService,
        gitSync: _observability.gitSync,
        heartbeatIntervalMinutes: _web.heartbeatDisplay.intervalMinutes,
        scheduledJobs: _web.schedulingDisplay.jobs,
      );
      router.mount('/', cfgRouter.call);
    }
  }

  void _mountConfigApiRoutes(Router router) {
    final cw = _core.configWriter;
    final cfg = _core.config;
    final rc = _core.runtimeConfig;
    final dd = _web.appDisplay.dataDir;
    if (cw != null && cfg != null && rc != null && dd != null) {
      final cfgApiRouter = configApiRoutes(
        config: cfg,
        writer: cw,
        validator: const ConfigValidator(),
        runtimeConfig: rc,
        dataDir: dd,
        restartService: _core.restartService,
        sseBroadcast: _observability.sseBroadcast,
        scheduleService: _observability.scheduleService,
        whatsAppChannel: _channels.whatsAppChannel,
        signalChannel: _channels.signalChannel,
        googleChatChannel: _channels.googleChatWebhookHandler?.channel,
        eventBus: _observability.eventBus,
        configNotifier: _core.configNotifier,
        guardChain: _core.guardChain,
      );
      router.mount('/', cfgApiRouter.call);
    }
  }

  void _mountMemoryRoutes(Router router) {
    final memStatus = _observability.memoryStatusService;
    final wp = _web.workspaceDisplay.path;
    if (memStatus != null && wp != null) {
      final memRouter = memoryRoutes(
        statusService: memStatus,
        workspaceDir: wp,
        pruner: _observability.memoryPruner,
        kvService: _core.kvService,
      );
      router.mount('/', memRouter.call);
    }
  }

  void _mountProviderRoutes(Router router) {
    final providerStatus = _observability.providerStatus;
    if (providerStatus != null) {
      final providerRouter = providerRoutes(providerStatus: providerStatus);
      router.mount('/', providerRouter.call);
    }
  }

  void _mountGoalRoutes(Router router) {
    final goalService = _tasks.goalService;
    if (goalService != null) {
      final goalRouter = goalRoutes(goalService);
      router.mount('/', goalRouter.call);
    }
  }

  void _mountProjectRoutes(Router router) {
    final ps = _tasks.projectService;
    if (ps != null) {
      final projectRouter = projectRoutes(
        ps,
        projectConfig: _core.config?.projects ?? const ProjectConfig.defaults(),
        containerEnabled: _core.config?.container.enabled ?? false,
        containerMountRoots: _projectRouteContainerMountRoots(),
        tasks: _tasks.taskService,
        worktreeManager: _tasks.worktreeManager,
        taskFileGuard: _tasks.taskFileGuard,
        turns: _turn.turns,
      );
      router.mount('/', projectRouter.call);
    }
  }

  List<String> _projectRouteContainerMountRoots() {
    final config = _core.config;
    if (config == null) {
      return [p.normalize(p.absolute(Directory.current.path))];
    }

    final roots = <String>{
      p.normalize(p.absolute(Directory.current.path)),
      if (config.workspaceDir.trim().isNotEmpty) p.normalize(p.absolute(config.workspaceDir)),
      if (config.projectsClonesDir.trim().isNotEmpty) p.normalize(p.absolute(config.projectsClonesDir)),
      ...config.container.extraMounts
          .map(_hostRootFromMount)
          .whereType<String>()
          .map((root) => p.normalize(p.absolute(root))),
      ..._configuredLocalPathRoots(config),
    };
    return roots.toList(growable: false);
  }

  Iterable<String> _configuredLocalPathRoots(DartclawConfig config) sync* {
    final clonesDir = p.normalize(p.absolute(config.projectsClonesDir));
    for (final definition in config.projects.definitions.values) {
      final localPath = definition.localPath?.trim();
      if (localPath == null || localPath.isEmpty) {
        continue;
      }
      final normalizedLocalPath = p.normalize(p.absolute(localPath));
      if (p.equals(normalizedLocalPath, clonesDir) || p.isWithin(clonesDir, normalizedLocalPath)) {
        continue;
      }
      yield normalizedLocalPath;
    }
  }

  String? _hostRootFromMount(String mount) {
    final parts = mount.split(':');
    if (parts.length < 2) {
      return null;
    }
    final hostPath = parts.first.trim();
    if (hostPath.isEmpty || !p.isAbsolute(hostPath)) {
      return null;
    }
    return hostPath;
  }

  void _mountTaskRoutes(Router router) {
    final taskService = _tasks.taskService;
    final eventBus = _observability.eventBus;
    if (taskService != null && eventBus != null) {
      final taskSseRouter = taskSseRoutes(
        taskService,
        eventBus,
        observer: _tasks.agentObserver,
        projects: _tasks.projectService,
        progressTracker: _tasks.progressTracker,
        workflows: _web.workflowService,
      );
      router.mount('/', taskSseRouter.call);
      final taskRouter = taskRoutes(
        taskService,
        turns: _turn.turns,
        reviewService: _tasks.taskReviewService,
        worktreeManager: _tasks.worktreeManager,
        taskFileGuard: _tasks.taskFileGuard,
        mergeExecutor: _tasks.mergeExecutor,
        projectService: _tasks.projectService,
        dataDir: _web.appDisplay.dataDir,
        threadBindingStore: _channels.threadBindingStore,
        mergeStrategy: _tasks.mergeStrategy ?? 'squash',
        baseRef: _tasks.baseRef ?? 'main',
      );
      router.mount('/', taskRouter.call);
    }
    final ts = _tasks.traceService;
    if (ts != null) {
      router.mount('/', traceRoutes(ts).call);
    }
  }

  void _mountWorkflowRoutes(Router router) {
    final wf = _web.workflowService;
    final ts = _tasks.taskService;
    final ds = _web.workflowDefinitionSource;
    if (wf != null && ts != null && ds != null) {
      final workflowRouter = workflowRoutes(wf, ts, ds, eventBus: _observability.eventBus);
      router.mount('/', workflowRouter.call);
    }
  }

  void _mountGoogleChatSubscriptionRoutes(Router router) {
    final subRouter = googleChatSubscriptionRoutes(
      subscriptionManager: _channels.spaceEventsWiring?.subscriptionManager,
    );
    router.mount('/', subRouter.call);
  }

  void _mountAgentRoutes(Router router) {
    final agentObs = _tasks.agentObserver;
    if (agentObs != null) {
      final agentRouter = agentRoutes(agentObs);
      router.mount('/', agentRouter.call);
    }
  }

  void _mountSessionRoutes(Router router) {
    final configuredProvider = _core.config?.agent.provider.trim().toLowerCase();
    final defaultProvider = configuredProvider == null || configuredProvider.isEmpty ? 'claude' : configuredProvider;
    final showChannels =
        _channels.whatsAppChannel != null ||
        _channels.signalChannel != null ||
        _channels.googleChatWebhookHandler?.channel != null;
    final tasksEnabled = _tasks.taskService != null && _observability.eventBus != null;
    final sidebarBuilder = SidebarDataBuilder(
      sessions: _core.sessions,
      kvService: _core.kvService,
      defaultProvider: defaultProvider,
      showChannels: showChannels,
      tasksEnabled: tasksEnabled,
    );
    String buildSidebarHtml({required SidebarData sidebarData, List<NavItem> navItems = const []}) {
      final resolvedNavItems = navItems.isEmpty ? _pageRegistry.navItems(activePage: '') : navItems;
      return buildSidebar(sidebarData: sidebarData, navItems: resolvedNavItems, appName: _web.appDisplay.name);
    }

    final sessionRouter = sessionRoutes(
      _core.sessions,
      _core.messages,
      _turn.turns,
      _core.worker,
      resetService: _core.resetService,
      redactor: _core.redactor,
      chatCommandHandler: () {
        final wf = _web.workflowService;
        final ds = _web.workflowDefinitionSource;
        return (wf != null && ds != null) ? ChatCommandHandler(workflows: wf, definitions: ds) : null;
      }(),
      projectService: _tasks.projectService,
      sidebarData: sidebarBuilder.build,
      buildSidebarHtml: buildSidebarHtml,
    );
    router.mount('/', sessionRouter.call);
  }

  void _mountWebRoutes(Router router) {
    final webRouter = webRoutes(
      _core.sessions,
      _core.messages,
      workerStateGetter: () => _core.worker.state,
      tokenService: _core.tokenService,
      gatewayToken: _core.gatewayToken,
      healthService: _core.healthService,
      whatsAppChannel: _channels.whatsAppChannel,
      signalChannel: _channels.signalChannel,
      googleChatChannel: _channels.googleChatWebhookHandler?.channel,
      guardChain: _core.guardChain,
      turns: _turn.turns,
      runtimeConfig: _core.runtimeConfig,
      memoryStatusService: _observability.memoryStatusService,
      memoryService: _observability.memoryService,
      kgService: _web.kgService,
      cookieSecure: _core.config?.auth.cookieSecure ?? false,
      trustedProxies: _core.config?.auth.trustedProxies ?? const [],
      contentGuardDisplay: _web.contentGuardDisplay,
      heartbeatDisplay: _web.heartbeatDisplay,
      schedulingDisplay: _web.schedulingDisplay,
      workspaceDisplay: _web.workspaceDisplay,
      appDisplay: _web.appDisplay,
      pageRegistry: _pageRegistry,
      config: _core.config,
      taskService: _tasks.taskService,
      goalService: _tasks.goalService,
      projectService: _tasks.projectService,
      eventBus: _observability.eventBus,
      agentObserver: _tasks.agentObserver,
      kvService: _core.kvService,
      traceService: _tasks.traceService,
      taskEventService: _tasks.taskEventService,
      progressTracker: _tasks.progressTracker,
      threadBindingStore: _channels.threadBindingStore,
      workflowService: _web.workflowService,
      workflowDefinitionSource: _web.workflowDefinitionSource,
    );
    router.mount('/', webRouter.call);
  }

  Handler _buildPipeline(Router router) {
    var pipeline = const Pipeline()
        .addMiddleware(logRequests(logger: _sanitizedLogger))
        .addMiddleware(securityHeadersMiddleware(enableHsts: _core.config?.gateway.hsts ?? false))
        .addMiddleware(_corsMiddleware());
    final tokenService = _core.tokenService;
    final gatewayToken = _core.gatewayToken;
    if (tokenService != null && gatewayToken != null) {
      String? githubPublicPath;
      try {
        final githubConfig = _core.config?.extension<GitHubWebhookConfig>('github');
        if (githubConfig != null && githubConfig.enabled) {
          githubPublicPath = githubConfig.webhookPath;
        }
      } catch (_) {
        githubPublicPath = null; // Extension absent or malformed — omit public webhook path.
      }
      pipeline = pipeline.addMiddleware(
        authMiddleware(
          tokenService: tokenService,
          gatewayToken: gatewayToken,
          enabled: _core.authEnabled,
          cookieSecure: _core.config?.auth.cookieSecure ?? false,
          trustedProxies: _core.config?.auth.trustedProxies ?? const [],
          eventBus: _observability.eventBus,
          rateLimiter: _authRateLimiter,
          publicPaths: [
            ...?(_channels.googleChatWebhookHandler == null
                ? null
                : [_channels.googleChatWebhookHandler!.config.webhookPath]),
            ...?(githubPublicPath == null ? null : [githubPublicPath]),
          ],
          publicPrefixes: const [],
        ),
      );
    } else if (!_core.authEnabled) {
      // No-auth mode (`auth_mode: none`): single-user local instance — grant
      // every request admin context so admin-gated routes remain usable.
      pipeline = pipeline.addMiddleware(localAdminMiddleware());
    }
    // Origin/Host guard: enforces same-origin writes for cookie-authenticated
    // sessions. Must run after auth middleware so the cookie-auth context flag
    // is set. Bearer-token and no-auth requests are automatically exempt.
    pipeline = pipeline.addMiddleware(originHostGuardMiddleware());
    // Cascade: pass through to styled 404 when router finds no matching route.
    final cascade = Cascade()
        .add(router.call)
        .add(
          (_) => Response.notFound(
            errorPageTemplate(404, 'Page Not Found', 'The requested page does not exist.'),
            headers: htmlHeaders,
          ),
        );
    return pipeline.addHandler(cascade.handler);
  }
}
