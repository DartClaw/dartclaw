import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart' show MemoryPruner, TaskEventService, TurnTraceService;
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';

import 'api/agent_routes.dart';
import 'api/config_api_routes.dart';
import 'api/config_routes.dart';
import 'api/google_chat_space_events_wiring.dart';
import 'api/google_chat_subscription_routes.dart';
import 'api/google_chat_webhook.dart';
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
import 'auth/security_headers.dart';
import 'auth/token_service.dart';
import 'behavior/behavior_file_service.dart';
import 'behavior/heartbeat_scheduler.dart';
import 'behavior/self_improvement_service.dart';
import 'canvas/canvas_admin_routes.dart';
import 'canvas/canvas_routes.dart';
import 'canvas/canvas_service.dart';
import 'concurrency/session_lock_manager.dart';
import 'context/context_monitor.dart';
import 'context/exploration_summarizer.dart';
import 'harness_pool.dart';
import 'health/health_service.dart';
import 'memory/memory_status_service.dart';
import 'mcp/mcp_router.dart';
import 'mcp/mcp_server.dart';
import 'observability/usage_tracker.dart';
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
import 'templates/sidebar.dart' show NavItem, SidebarData, sidebarTemplate;
import 'turn_manager.dart';
import 'web/dashboard_page.dart';
import 'web/page_registry.dart';
import 'web/sidebar_feature_visibility.dart';
import 'web/signal_pairing_routes.dart';
import 'web/system_pages.dart';
import 'web/web_routes.dart';
import 'web/web_utils.dart';
import 'web/whatsapp_pairing_routes.dart';
import 'workspace/workspace_git_sync.dart';

/// Builder for [DartclawServer].
///
/// Collects all dependencies in domain-grouped sections and produces a
/// fully-initialized server. Replaces the two-phase factory +
/// setRuntimeServices() pattern.
class DartclawServerBuilder {
  // Required core services
  SessionService? sessions;
  MessageService? messages;
  AgentHarness? worker;
  String? staticDir;
  BehaviorFileService? behavior;

  // Turn management (optional — if not set, uses sessions/worker/behavior)
  HarnessPool? pool;
  SessionService? sessionsForTurns;
  SessionLockManager? lockManager;
  ContextMonitor? contextMonitor;
  ExplorationSummarizer? explorationSummarizer;

  // Optional services (null = feature disabled)
  MemoryFileService? memoryFile;
  HealthService? healthService;
  TokenService? tokenService;
  SessionResetService? resetService;
  GuardChain? guardChain;
  KvService? kv;
  MessageRedactor? redactor;
  SelfImprovementService? selfImprovement;
  UsageTracker? usageTracker;
  EventBus? eventBus;
  CanvasService? canvasService;

  // Channels
  ChannelManager? channelManager;
  WhatsAppChannel? whatsAppChannel;
  GoogleChatWebhookHandler? googleChatWebhookHandler;
  SignalChannel? signalChannel;
  String? webhookSecret;

  // Runtime services
  RuntimeConfig? runtimeConfig;
  HeartbeatScheduler? heartbeat;
  ScheduleService? scheduleService;
  WorkspaceGitSync? gitSync;
  MemoryStatusService? memoryStatusService;
  MemoryPruner? memoryPruner;
  ConfigWriter? configWriter;
  DartclawConfig? config;
  RestartService? restartService;
  SseBroadcast? sseBroadcast;
  ProviderStatusService? providerStatus;

  // Projects
  ProjectService? projectService;

  // Tasks
  GoalService? goalService;
  TaskService? taskService;
  TaskReviewService? taskReviewService;
  WorktreeManager? worktreeManager;
  TaskFileGuard? taskFileGuard;
  AgentObserver? agentObserver;
  MergeExecutor? mergeExecutor;
  String? mergeStrategy;
  String? baseRef;
  TurnTraceService? traceService;
  TaskEventService? taskEventService;
  TaskEventRecorder? taskEventRecorder;

  // Google Chat
  GoogleChatSpaceEventsWiring? spaceEventsWiring;

  // Auth & gateway
  String? gatewayToken;
  bool authEnabled = true;

  // Display params
  ContentGuardDisplayParams contentGuardDisplay = const ContentGuardDisplayParams();
  HeartbeatDisplayParams heartbeatDisplay = const HeartbeatDisplayParams();
  SchedulingDisplayParams schedulingDisplay = const SchedulingDisplayParams();
  WorkspaceDisplayParams workspaceDisplay = const WorkspaceDisplayParams();
  AppDisplayParams appDisplay = const AppDisplayParams();

  TurnManager? _cachedTurns;

  /// Returns the [TurnManager] that will be used by the built server.
  ///
  /// May be called before [build] to wire services that need turn access.
  /// Caches the result — calling multiple times returns the same instance.
  ///
  /// Throws [StateError] if required deps (sessions, messages, worker,
  /// behavior) are not yet set.
  TurnManager buildTurns() {
    if (_cachedTurns != null) return _cachedTurns!;
    final s = sessions ?? (throw StateError('sessions is required'));
    final m = messages ?? (throw StateError('messages is required'));
    final w = worker ?? (throw StateError('worker is required'));
    final b = behavior ?? (throw StateError('behavior is required'));
    _cachedTurns = pool != null
        ? TurnManager.fromPool(pool: pool!, sessions: sessionsForTurns ?? s)
        : TurnManager(
            messages: m,
            worker: w,
            behavior: b,
            memoryFile: memoryFile,
            sessions: sessionsForTurns ?? s,
            kv: kv,
            guardChain: guardChain,
            lockManager: lockManager,
            resetService: resetService,
            contextMonitor: contextMonitor,
            explorationSummarizer: explorationSummarizer,
            redactor: redactor,
            selfImprovement: selfImprovement,
            usageTracker: usageTracker,
          );
    return _cachedTurns!;
  }

  /// Build the [DartclawServer] with all configured dependencies.
  ///
  /// Throws [StateError] if required dependencies are missing.
  DartclawServer build() {
    final s = sessions ?? (throw StateError('sessions is required'));
    final m = messages ?? (throw StateError('messages is required'));
    final w = worker ?? (throw StateError('worker is required'));
    final sd = staticDir ?? (throw StateError('staticDir is required'));

    final turns = buildTurns();

    final eventRecorder =
        taskEventRecorder ??
        (taskEventService != null ? TaskEventRecorder(eventService: taskEventService!, eventBus: eventBus) : null);

    // Create progress tracker when task event infrastructure is available.
    final progressTracker = (taskEventService != null && taskService != null && eventBus != null)
        ? TaskProgressTracker(eventBus: eventBus!, tasks: taskService!)
        : null;

    final server = DartclawServer._(
      sessions: s,
      messages: m,
      worker: w,
      pool: pool,
      turns: turns,
      memoryFile: memoryFile,
      healthService: healthService,
      tokenService: tokenService,
      resetService: resetService,
      authEnabled: authEnabled,
      staticDir: sd,
      channelManager: channelManager,
      whatsAppChannel: whatsAppChannel,
      googleChatWebhookHandler: googleChatWebhookHandler,
      signalChannel: signalChannel,
      guardChain: guardChain,
      webhookSecret: webhookSecret,
      redactor: redactor,
      gatewayToken: gatewayToken,
      runtimeConfig: runtimeConfig,
      heartbeat: heartbeat,
      scheduleService: scheduleService,
      gitSync: gitSync,
      memoryStatusService: memoryStatusService,
      memoryPruner: memoryPruner,
      kvService: kv,
      configWriter: configWriter,
      config: config,
      restartService: restartService,
      sseBroadcast: sseBroadcast,
      providerStatus: providerStatus,
      eventBus: eventBus,
      canvasService: canvasService,
      projectService: projectService,
      goalService: goalService,
      taskService: taskService,
      taskReviewService: taskReviewService,
      worktreeManager: worktreeManager,
      taskFileGuard: taskFileGuard,
      agentObserver: agentObserver,
      mergeExecutor: mergeExecutor,
      mergeStrategy: mergeStrategy,
      baseRef: baseRef,
      traceService: traceService,
      taskEventService: taskEventService,
      taskEventRecorder: eventRecorder,
      progressTracker: progressTracker,
      spaceEventsWiring: spaceEventsWiring,
      contentGuardDisplay: contentGuardDisplay,
      heartbeatDisplay: heartbeatDisplay,
      schedulingDisplay: schedulingDisplay,
      workspaceDisplay: workspaceDisplay,
      appDisplay: appDisplay,
    );
    final visibility = computeSidebarFeatureVisibility(
      config: config,
      hasChannels: whatsAppChannel != null || signalChannel != null || googleChatWebhookHandler?.channel != null,
      guardChain: guardChain,
      hasHealthService: healthService != null,
      hasTaskService: taskService != null,
      hasPubSubHealth: healthService?.pubsubHealth != null,
      heartbeatDisplay: heartbeatDisplay,
      schedulingDisplay: schedulingDisplay,
      workspaceDisplay: workspaceDisplay,
    );

    registerSystemDashboardPages(
      server._pageRegistry,
      healthService: healthService,
      workerStateGetter: () => w.state,
      whatsAppChannel: whatsAppChannel,
      signalChannel: signalChannel,
      googleChatChannel: googleChatWebhookHandler?.channel,
      guardChain: guardChain,
      providerStatus: providerStatus,
      runtimeConfigGetter: () => server._runtimeConfig,
      memoryStatusServiceGetter: () => server._memoryStatusService,
      contentGuardDisplay: contentGuardDisplay,
      heartbeatDisplay: heartbeatDisplay,
      schedulingDisplay: schedulingDisplay,
      workspaceDisplay: workspaceDisplay,
      auditReader: appDisplay.dataDir != null ? AuditLogReader(dataDir: appDisplay.dataDir!) : null,
      pubsubHealthGetter: healthService != null
          ? () => healthService!.pubsubHealth ?? const {'status': 'disabled', 'enabled': false}
          : null,
      showHealth: visibility.showHealth,
      showMemory: visibility.showMemory,
      showScheduling: visibility.showScheduling,
      showTasks: visibility.showTasks,
      projectService: projectService,
    );

    return server;
  }
}

/// Shelf-based HTTP server composing all DartClaw routes and middleware.
class DartclawServer {
  // Core services — all final
  final SessionService _sessions;
  final MessageService _messages;
  final AgentHarness _worker;
  final HarnessPool? _pool;
  final TurnManager _turns;
  final MemoryFileService? _memoryFile;
  final HealthService? _healthService;
  final TokenService? _tokenService;
  final SessionResetService? _resetService;
  final bool _authEnabled;
  final String _staticDir;
  final ChannelManager? _channelManager;
  final WhatsAppChannel? _whatsAppChannel;
  final GoogleChatWebhookHandler? _googleChatWebhookHandler;
  final SignalChannel? _signalChannel;
  final GuardChain? _guardChain;
  final String? _webhookSecret;
  final MessageRedactor? _redactor;
  final McpProtocolHandler _mcpHandler;
  final String? _gatewayToken;

  // Runtime services — all final
  final RuntimeConfig? _runtimeConfig;
  final HeartbeatScheduler? _heartbeat;
  final ScheduleService? _scheduleService;
  final WorkspaceGitSync? _gitSync;
  final MemoryStatusService? _memoryStatusService;
  final MemoryPruner? _memoryPruner;
  final KvService? _kvService;
  final ConfigWriter? _configWriter;
  final DartclawConfig? _config;
  final RestartService? _restartService;
  final SseBroadcast? _sseBroadcast;
  final ProviderStatusService? _providerStatus;
  final EventBus? _eventBus;
  final CanvasService? _canvasService;
  final ProjectService? _projectService;
  final GoalService? _goalService;
  final TaskService? _taskService;
  final TaskReviewService? _taskReviewService;
  final WorktreeManager? _worktreeManager;
  final TaskFileGuard? _taskFileGuard;
  final AgentObserver? _agentObserver;
  final MergeExecutor? _mergeExecutor;
  final String? _mergeStrategy;
  final String? _baseRef;
  final TurnTraceService? _traceService;
  final TaskEventService? _taskEventService;
  final TaskEventRecorder? _taskEventRecorder;
  final TaskProgressTracker? _progressTracker;
  final GoogleChatSpaceEventsWiring? _spaceEventsWiring;

  // Display params — all final
  final ContentGuardDisplayParams _contentGuardDisplay;
  final HeartbeatDisplayParams _heartbeatDisplay;
  final SchedulingDisplayParams _schedulingDisplay;
  final WorkspaceDisplayParams _workspaceDisplay;
  final AppDisplayParams _appDisplay;

  final PageRegistry _pageRegistry = PageRegistry();
  final AuthRateLimiter _authRateLimiter = AuthRateLimiter();
  Handler? _builtHandler;
  Handler? _requestHandler;
  bool _registrationLocked = false;

  TurnManager get turns => _turns;
  ProviderStatusService? get providerStatus => _providerStatus;
  TaskEventService? get taskEventService => _taskEventService;
  TaskEventRecorder? get taskEventRecorder => _taskEventRecorder;

  /// Internal constructor — use [DartclawServerBuilder] to create instances.
  DartclawServer._({
    required SessionService sessions,
    required MessageService messages,
    required AgentHarness worker,
    required HarnessPool? pool,
    required TurnManager turns,
    required MemoryFileService? memoryFile,
    required HealthService? healthService,
    required TokenService? tokenService,
    required SessionResetService? resetService,
    required bool authEnabled,
    required String staticDir,
    required ChannelManager? channelManager,
    required WhatsAppChannel? whatsAppChannel,
    required GoogleChatWebhookHandler? googleChatWebhookHandler,
    required SignalChannel? signalChannel,
    required GuardChain? guardChain,
    required String? webhookSecret,
    required MessageRedactor? redactor,
    required String? gatewayToken,
    required RuntimeConfig? runtimeConfig,
    required HeartbeatScheduler? heartbeat,
    required ScheduleService? scheduleService,
    required WorkspaceGitSync? gitSync,
    required MemoryStatusService? memoryStatusService,
    required MemoryPruner? memoryPruner,
    required KvService? kvService,
    required ConfigWriter? configWriter,
    required DartclawConfig? config,
    required RestartService? restartService,
    required SseBroadcast? sseBroadcast,
    required ProviderStatusService? providerStatus,
    required EventBus? eventBus,
    required CanvasService? canvasService,
    required ProjectService? projectService,
    required GoalService? goalService,
    required TaskService? taskService,
    required TaskReviewService? taskReviewService,
    required WorktreeManager? worktreeManager,
    required TaskFileGuard? taskFileGuard,
    required AgentObserver? agentObserver,
    required MergeExecutor? mergeExecutor,
    required String? mergeStrategy,
    required String? baseRef,
    required TurnTraceService? traceService,
    required TaskEventService? taskEventService,
    required TaskEventRecorder? taskEventRecorder,
    required TaskProgressTracker? progressTracker,
    required GoogleChatSpaceEventsWiring? spaceEventsWiring,
    required ContentGuardDisplayParams contentGuardDisplay,
    required HeartbeatDisplayParams heartbeatDisplay,
    required SchedulingDisplayParams schedulingDisplay,
    required WorkspaceDisplayParams workspaceDisplay,
    required AppDisplayParams appDisplay,
  }) : _sessions = sessions,
       _messages = messages,
       _worker = worker,
       _pool = pool,
       _turns = turns,
       _memoryFile = memoryFile,
       _healthService = healthService,
       _tokenService = tokenService,
       _resetService = resetService,
       _authEnabled = authEnabled,
       _staticDir = staticDir,
       _channelManager = channelManager,
       _whatsAppChannel = whatsAppChannel,
       _googleChatWebhookHandler = googleChatWebhookHandler,
       _signalChannel = signalChannel,
       _guardChain = guardChain,
       _webhookSecret = webhookSecret,
       _redactor = redactor,
       _gatewayToken = gatewayToken,
       _mcpHandler = McpProtocolHandler(),
       _runtimeConfig = runtimeConfig,
       _heartbeat = heartbeat,
       _scheduleService = scheduleService,
       _gitSync = gitSync,
       _memoryStatusService = memoryStatusService,
       _memoryPruner = memoryPruner,
       _kvService = kvService,
       _configWriter = configWriter,
       _config = config,
       _restartService = restartService,
       _sseBroadcast = sseBroadcast,
       _providerStatus = providerStatus,
       _eventBus = eventBus,
       _canvasService = canvasService,
       _projectService = projectService,
       _goalService = goalService,
       _taskService = taskService,
       _taskReviewService = taskReviewService,
       _worktreeManager = worktreeManager,
       _taskFileGuard = taskFileGuard,
       _agentObserver = agentObserver,
       _mergeExecutor = mergeExecutor,
       _mergeStrategy = mergeStrategy,
       _baseRef = baseRef,
       _traceService = traceService,
       _taskEventService = taskEventService,
       _taskEventRecorder = taskEventRecorder,
       _progressTracker = progressTracker,
       _spaceEventsWiring = spaceEventsWiring,
       _contentGuardDisplay = contentGuardDisplay,
       _heartbeatDisplay = heartbeatDisplay,
       _schedulingDisplay = schedulingDisplay,
       _workspaceDisplay = workspaceDisplay,
       _appDisplay = appDisplay;

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

    final guardChain = _guardChain;
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

    final channelManager = _channelManager;
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

    final eventBus = _eventBus;
    if (eventBus == null) {
      throw StateError('Cannot register event listeners without an event bus');
    }

    return eventBus.on<T>().listen(callback);
  }

  /// The MCP protocol handler, exposed for testing.
  McpProtocolHandler get mcpHandler => _mcpHandler;

  Future<void> _seedAndStartProgressTracker(TaskProgressTracker tracker) async {
    final taskService = _taskService;
    final taskEventService = _taskEventService;
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
    _progressTracker?.dispose();
    for (final sessionId in _turns.activeSessionIds.toList()) {
      await _turns.cancelTurn(sessionId);
    }
    await _spaceEventsWiring?.dispose();
    await _sseBroadcast?.dispose();
    await _canvasService?.dispose();
    await _channelManager?.dispose();
    if (_pool != null) {
      await _pool.dispose();
    } else {
      await _worker.dispose();
    }
    await _messages.dispose();
    await _memoryFile?.dispose();
    await _configWriter?.dispose();
  }

  Handler get handler => _requestHandler ??= (Request request) {
    _builtHandler ??= _buildHandler();
    return _builtHandler!(request);
  };

  void _validateDependencies() {
    if (_taskService != null) {
      if (_worktreeManager == null) {
        throw StateError('taskService requires worktreeManager');
      }
      if (_taskFileGuard == null) {
        throw StateError('taskService requires taskFileGuard');
      }
      if (_mergeExecutor == null) {
        throw StateError('taskService requires mergeExecutor');
      }
      if (_agentObserver == null) {
        throw StateError('taskService requires agentObserver');
      }
    }

    if (_configWriter != null) {
      if (_restartService == null) {
        throw StateError('configWriter requires restartService');
      }
      if (_sseBroadcast == null) {
        throw StateError('configWriter requires sseBroadcast');
      }
    }
  }

  Handler _buildHandler() {
    _validateDependencies();
    _registrationLocked = true;

    // Seed and start the progress tracker if available.
    final tracker = _progressTracker;
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
    _mountGoogleChatSubscriptionRoutes(router);
    _mountAgentRoutes(router);
    _mountSessionRoutes(router);
    _mountCanvasRoutes(router);
    _mountCanvasAdminRoutes(router);
    _mountWebRoutes(router);

    return _buildPipeline(router);
  }

  void _mountHealthRoutes(Router router) {
    final hs = _healthService;
    if (hs != null) {
      router.get('/health', (Request request) async {
        final status = await hs.getStatus();
        return Response.ok(jsonEncode(status), headers: {'Content-Type': 'application/json'});
      });
    }
  }

  void _mountMcpRoutes(Router router) {
    final gt = _gatewayToken;
    if (gt != null) {
      router.post('/mcp', mcpRoute(_mcpHandler, gatewayToken: gt));
    }
  }

  void _mountStaticRoutes(Router router) {
    final staticHandler = createStaticHandler(_staticDir, defaultDocument: null);
    router.mount('/static/', staticHandler);
  }

  void _mountWebhookRoutes(Router router) {
    final webhookRouter = webhookRoutes(
      whatsApp: _whatsAppChannel,
      webhookSecret: _webhookSecret,
      googleChat: _googleChatWebhookHandler,
      eventBus: _eventBus,
      trustedProxies: _config?.auth.trustedProxies ?? const [],
    );
    router.mount('/', webhookRouter.call);
  }

  void _mountWhatsAppPairingRoutes(Router router) {
    final waChannel = _whatsAppChannel;
    if (waChannel != null) {
      final waRouter = whatsappPairingRoutes(
        whatsAppChannel: waChannel,
        sessions: _sessions,
        pageRegistry: _pageRegistry,
        tasksEnabled: _taskService != null && _eventBus != null,
        appName: _appDisplay.name,
      );
      router.mount('/whatsapp', waRouter.call);
    }
  }

  void _mountSignalPairingRoutes(Router router) {
    final sigChannel = _signalChannel;
    if (sigChannel != null) {
      final sigRouter = signalPairingRoutes(
        signalChannel: sigChannel,
        sessions: _sessions,
        pageRegistry: _pageRegistry,
        tasksEnabled: _taskService != null && _eventBus != null,
        appName: _appDisplay.name,
      );
      router.mount('/signal', sigRouter.call);
    }
  }

  void _mountConfigRoutes(Router router) {
    final rc = _runtimeConfig;
    if (rc != null) {
      final cfgRouter = configRoutes(
        runtimeConfig: rc,
        heartbeat: _heartbeat,
        scheduleService: _scheduleService,
        gitSync: _gitSync,
        heartbeatIntervalMinutes: _heartbeatDisplay.intervalMinutes,
        scheduledJobs: _schedulingDisplay.jobs,
      );
      router.mount('/', cfgRouter.call);
    }
  }

  void _mountConfigApiRoutes(Router router) {
    final cw = _configWriter;
    final cfg = _config;
    final rc = _runtimeConfig;
    final dd = _appDisplay.dataDir;
    if (cw != null && cfg != null && rc != null && dd != null) {
      final cfgApiRouter = configApiRoutes(
        config: cfg,
        writer: cw,
        validator: const ConfigValidator(),
        runtimeConfig: rc,
        dataDir: dd,
        restartService: _restartService,
        sseBroadcast: _sseBroadcast,
        scheduleService: _scheduleService,
        whatsAppChannel: _whatsAppChannel,
        signalChannel: _signalChannel,
        googleChatChannel: _googleChatWebhookHandler?.channel,
        eventBus: _eventBus,
      );
      router.mount('/', cfgApiRouter.call);
    }
  }

  void _mountMemoryRoutes(Router router) {
    final memStatus = _memoryStatusService;
    final wp = _workspaceDisplay.path;
    if (memStatus != null && wp != null) {
      final memRouter = memoryRoutes(
        statusService: memStatus,
        workspaceDir: wp,
        pruner: _memoryPruner,
        kvService: _kvService,
      );
      router.mount('/', memRouter.call);
    }
  }

  void _mountProviderRoutes(Router router) {
    final providerStatus = _providerStatus;
    if (providerStatus != null) {
      final providerRouter = providerRoutes(providerStatus: providerStatus);
      router.mount('/', providerRouter.call);
    }
  }

  void _mountGoalRoutes(Router router) {
    final goalService = _goalService;
    if (goalService != null) {
      final goalRouter = goalRoutes(goalService);
      router.mount('/', goalRouter.call);
    }
  }

  void _mountProjectRoutes(Router router) {
    final ps = _projectService;
    if (ps != null) {
      final projectRouter = projectRoutes(
        ps,
        tasks: _taskService,
        worktreeManager: _worktreeManager,
        taskFileGuard: _taskFileGuard,
        turns: _turns,
      );
      router.mount('/', projectRouter.call);
    }
  }

  void _mountTaskRoutes(Router router) {
    final taskService = _taskService;
    final eventBus = _eventBus;
    if (taskService != null && eventBus != null) {
      final taskSseRouter = taskSseRoutes(
        taskService,
        eventBus,
        observer: _agentObserver,
        projects: _projectService,
        progressTracker: _progressTracker,
      );
      router.mount('/', taskSseRouter.call);
      final taskRouter = taskRoutes(
        taskService,
        turns: _turns,
        reviewService: _taskReviewService,
        worktreeManager: _worktreeManager,
        taskFileGuard: _taskFileGuard,
        mergeExecutor: _mergeExecutor,
        projectService: _projectService,
        dataDir: _appDisplay.dataDir,
        mergeStrategy: _mergeStrategy ?? 'squash',
        baseRef: _baseRef ?? 'main',
      );
      router.mount('/', taskRouter.call);
    }
    final ts = _traceService;
    if (ts != null) {
      router.mount('/', traceRoutes(ts).call);
    }
  }

  void _mountGoogleChatSubscriptionRoutes(Router router) {
    final subRouter = googleChatSubscriptionRoutes(subscriptionManager: _spaceEventsWiring?.subscriptionManager);
    router.mount('/', subRouter.call);
  }

  void _mountAgentRoutes(Router router) {
    final agentObs = _agentObserver;
    if (agentObs != null) {
      final agentRouter = agentRoutes(agentObs);
      router.mount('/', agentRouter.call);
    }
  }

  void _mountSessionRoutes(Router router) {
    final configuredProvider = _config?.agent.provider.trim().toLowerCase();
    final defaultProvider = configuredProvider == null || configuredProvider.isEmpty ? 'claude' : configuredProvider;
    final showChannels =
        _whatsAppChannel != null || _signalChannel != null || _googleChatWebhookHandler?.channel != null;
    final tasksEnabled = _taskService != null && _eventBus != null;
    String buildSidebarHtml({
      required SidebarData sidebarData,
      String? activeSessionId,
      List<NavItem> navItems = const [],
    }) {
      final resolvedNavItems = navItems.isEmpty ? _pageRegistry.navItems(activePage: '') : navItems;
      return sidebarTemplate(
        mainSession: sidebarData.main,
        dmChannels: sidebarData.dmChannels,
        groupChannels: sidebarData.groupChannels,
        activeEntries: sidebarData.activeEntries,
        archivedEntries: sidebarData.archivedEntries,
        showChannels: sidebarData.showChannels,
        tasksEnabled: sidebarData.tasksEnabled,
        activeSessionId: activeSessionId,
        navItems: resolvedNavItems,
        appName: _appDisplay.name,
      );
    }

    final sessionRouter = sessionRoutes(
      _sessions,
      _messages,
      _turns,
      _worker,
      resetService: _resetService,
      redactor: _redactor,
      buildSidebarData: () => buildSidebarData(
        _sessions,
        kvService: _kvService,
        defaultProvider: defaultProvider,
        showChannels: showChannels,
        tasksEnabled: tasksEnabled,
      ),
      buildSidebarHtml: buildSidebarHtml,
    );
    router.mount('/', sessionRouter.call);
  }

  void _mountCanvasRoutes(Router router) {
    final canvasService = _canvasService;
    if (canvasService == null) return;

    final canvasRouter = canvasRoutes(canvasService: canvasService, turns: _turns, sessions: _sessions);
    router.mount('/canvas', canvasRouter.call);
  }

  void _mountCanvasAdminRoutes(Router router) {
    final canvasService = _canvasService;
    if (canvasService == null) return;

    final adminRouter = canvasAdminRoutes(canvasService: canvasService);
    router.mount('/', adminRouter.call);
  }

  void _mountWebRoutes(Router router) {
    final webRouter = webRoutes(
      _sessions,
      _messages,
      workerStateGetter: () => _worker.state,
      tokenService: _tokenService,
      gatewayToken: _gatewayToken,
      healthService: _healthService,
      whatsAppChannel: _whatsAppChannel,
      signalChannel: _signalChannel,
      googleChatChannel: _googleChatWebhookHandler?.channel,
      guardChain: _guardChain,
      turns: _turns,
      runtimeConfig: _runtimeConfig,
      memoryStatusService: _memoryStatusService,
      cookieSecure: _config?.auth.cookieSecure ?? false,
      trustedProxies: _config?.auth.trustedProxies ?? const [],
      contentGuardDisplay: _contentGuardDisplay,
      heartbeatDisplay: _heartbeatDisplay,
      schedulingDisplay: _schedulingDisplay,
      workspaceDisplay: _workspaceDisplay,
      appDisplay: _appDisplay,
      pageRegistry: _pageRegistry,
      config: _config,
      taskService: _taskService,
      goalService: _goalService,
      projectService: _projectService,
      eventBus: _eventBus,
      agentObserver: _agentObserver,
      kvService: _kvService,
      traceService: _traceService,
      taskEventService: _taskEventService,
      progressTracker: _progressTracker,
      canvasEnabled: _canvasService != null,
    );
    router.mount('/', webRouter.call);
  }

  Handler _buildPipeline(Router router) {
    var pipeline = const Pipeline()
        .addMiddleware(logRequests(logger: _sanitizedLogger))
        .addMiddleware(securityHeadersMiddleware(enableHsts: _config?.gateway.hsts ?? false))
        .addMiddleware(_corsMiddleware());
    if (_tokenService != null && _gatewayToken != null) {
      pipeline = pipeline.addMiddleware(
        authMiddleware(
          tokenService: _tokenService,
          gatewayToken: _gatewayToken,
          enabled: _authEnabled,
          cookieSecure: _config?.auth.cookieSecure ?? false,
          trustedProxies: _config?.auth.trustedProxies ?? const [],
          eventBus: _eventBus,
          rateLimiter: _authRateLimiter,
          publicPaths: [if (_googleChatWebhookHandler != null) _googleChatWebhookHandler.config.webhookPath],
          publicPrefixes: [if (_canvasService != null) '/canvas/'],
        ),
      );
    }
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

/// Redacts sensitive query parameters (e.g. `secret`) from request log lines.
///
/// Shelf's default `logRequests()` logs the full URI including query strings,
/// which would expose webhook secrets in plaintext. This logger strips the
/// `secret` parameter value before logging. Output goes through the standard
/// [Logger] so it gets colorized level/name and structured formatting.
final _httpLog = Logger('HTTP');

void _sanitizedLogger(String msg, bool isError) {
  final sanitized = msg.replaceAll(RegExp(r'([?&])secret=[^&\s]*'), r'$1secret=REDACTED');
  if (isError) {
    _httpLog.severe(sanitized);
  } else {
    _httpLog.info(sanitized);
  }
}

final _localhostOrigin = RegExp(r'^http://(localhost|127\.0\.0\.1)(:\d+)?$');

Middleware _corsMiddleware() {
  return (Handler inner) => (Request request) async {
    final origin = request.headers['origin'] ?? '';
    final allowed = _localhostOrigin.hasMatch(origin);
    final corsOrigin = allowed ? origin : 'http://localhost';

    if (request.method == 'OPTIONS') {
      return Response.ok(
        '',
        headers: {
          'Access-Control-Allow-Origin': corsOrigin,
          'Access-Control-Allow-Methods': 'GET, POST, PATCH, DELETE, OPTIONS',
          'Access-Control-Allow-Headers': 'Content-Type, Authorization',
        },
      );
    }
    final response = await inner(request);
    return response.change(headers: {'Access-Control-Allow-Origin': corsOrigin});
  };
}
