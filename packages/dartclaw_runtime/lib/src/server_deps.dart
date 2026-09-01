part of 'server.dart';

// ---- Dependency-group structs -----------------------------------------------
//
// These are intentionally not exported from the package barrel — they are the
// composition surface between a composer in this package and DartclawServer.
// Every member outside ServerCoreDeps' three required services is optional, so
// a composer names only what its deployment actually has.

class ServerCoreDeps {
  final SessionService sessions;
  final MessageService messages;
  final AgentHarness worker;
  final String? dataDir;
  final String? staticDir;
  final AssetSource assetSource;
  final bool authEnabled;
  final String? gatewayToken;
  final RuntimeConfig? runtimeConfig;
  final KvService? kvService;
  final ConfigWriter? configWriter;
  final DartclawConfig? config;
  final ConfigNotifier? configNotifier;
  final RestartService? restartService;
  final HealthService? healthService;
  final TokenService? tokenService;
  final SessionResetService? resetService;
  final MessageRedactor? redactor;
  final GuardChain? guardChain;

  /// Audit sink for the MCP dispatch seam's one entry per `tools/call`.
  ///
  /// Read at [DartclawServer.fromDeps]: `registerTool` refuses registration
  /// after the handler starts, so the sink must exist at construction.
  final GuardAuditLogger? auditLogger;

  /// Registered tool name to canonical tool, for scoping a caller's view.
  final Map<String, CanonicalTool> mcpToolCanonicals;
  final String? webhookSecret;

  final ResultTrimmer? resultTrimmer;

  const new({
    required this.sessions,
    required this.messages,
    required this.worker,
    this.dataDir,
    this.staticDir,
    this.assetSource = AssetSource.sourceTreeDefault,
    this.authEnabled = true,
    this.gatewayToken,
    this.runtimeConfig,
    this.kvService,
    this.configWriter,
    this.config,
    this.configNotifier,
    this.restartService,
    this.healthService,
    this.tokenService,
    this.resetService,
    this.redactor,
    this.guardChain,
    this.auditLogger,
    this.mcpToolCanonicals = const {},
    this.webhookSecret,
    this.resultTrimmer,
  });
}

class ServerTurnDeps {
  final ExecutionCoordinator? executions;
  final TurnManager turns;

  const new({required this.turns, this.executions});
}

class ServerChannelDeps {
  final ChannelManager? channelManager;
  final WhatsAppChannel? whatsAppChannel;
  final SignalChannel? signalChannel;
  final GoogleChatWebhookHandler? googleChatWebhookHandler;
  final GoogleChatSpaceEventsWiring? spaceEventsWiring;
  final ThreadBindingStore? threadBindingStore;

  const new({
    this.channelManager,
    this.whatsAppChannel,
    this.signalChannel,
    this.googleChatWebhookHandler,
    this.spaceEventsWiring,
    this.threadBindingStore,
  });
}

class ServerTaskDeps {
  final ProjectService? projectService;
  final GoalService? goalService;
  final TaskService? taskService;
  final TaskReviewService? taskReviewService;
  final WorktreeManager? worktreeManager;
  final TaskFileGuard? taskFileGuard;
  final RunnerObserver? runnerObserver;
  final MergeExecutor? mergeExecutor;
  final String? mergeStrategy;
  final String? baseRef;
  final TurnTraceService? traceService;
  final TaskEventService? taskEventService;
  final TaskEventRecorder? taskEventRecorder;
  final TaskProgressTracker? progressTracker;
  final Future<void> Function()? executionDrainer;

  /// [taskEventRecorder] and [progressTracker] are derived from
  /// [taskEventService], [taskService] and [eventBus] when the composer does
  /// not supply its own. [eventBus] is read for that derivation only — the
  /// server's own bus is the one in [ServerObservabilityDeps].
  new({
    this.projectService,
    this.goalService,
    TaskService? taskService,
    this.taskReviewService,
    this.worktreeManager,
    this.taskFileGuard,
    this.runnerObserver,
    this.mergeExecutor,
    this.mergeStrategy,
    this.baseRef,
    this.traceService,
    TaskEventService? taskEventService,
    TaskEventRecorder? taskEventRecorder,
    TaskProgressTracker? progressTracker,
    this.executionDrainer,
    EventBus? eventBus,
  }) : taskService = taskService,
       taskEventService = taskEventService,
       taskEventRecorder =
           taskEventRecorder ??
           (taskEventService != null ? TaskEventRecorder(eventService: taskEventService, eventBus: eventBus) : null),
       progressTracker =
           progressTracker ??
           ((taskEventService != null && taskService != null && eventBus != null)
               ? TaskProgressTracker(eventBus: eventBus, tasks: taskService)
               : null);
}

class ServerObservabilityDeps {
  final EventBus? eventBus;
  final SseBroadcast? sseBroadcast;
  final ProviderStatusService? providerStatus;
  final MemoryFileService? memoryFile;
  final MemoryStatusService? memoryStatusService;
  final MemoryPruner? memoryPruner;
  final MemoryService? memoryService;
  final SearchBackend? searchBackend;
  final MemoryCorpusService? memoryCorpus;
  final ScheduleService? scheduleService;
  final WorkspaceGitSync? gitSync;
  final EventBusSseBridge? eventBusSseBridge;

  /// [eventBusSseBridge] is derived from [eventBus] and [sseBroadcast] when the
  /// composer does not supply its own.
  new({
    EventBus? eventBus,
    SseBroadcast? sseBroadcast,
    this.providerStatus,
    this.memoryFile,
    this.memoryStatusService,
    this.memoryPruner,
    this.memoryService,
    this.searchBackend,
    this.memoryCorpus,
    this.scheduleService,
    this.gitSync,
    EventBusSseBridge? eventBusSseBridge,
  }) : eventBus = eventBus,
       sseBroadcast = sseBroadcast,
       eventBusSseBridge =
           eventBusSseBridge ??
           ((eventBus != null && sseBroadcast != null)
               ? EventBusSseBridge(bus: eventBus, broadcast: sseBroadcast)
               : null);
}

class ServerWebDeps {
  final WorkflowService? workflowService;
  final WorkflowDefinitionSource? workflowDefinitionSource;
  final TemporalKnowledgeGraphService? kgService;
  final bool contentGuardApiKeyConfigured;
  final bool contentGuardFailOpen;
  final List<Map<String, dynamic>> schedulingJobs;
  final List<String> systemJobNames;

  const new({
    this.workflowService,
    this.workflowDefinitionSource,
    this.kgService,
    this.contentGuardApiKeyConfigured = false,
    this.contentGuardFailOpen = false,
    this.schedulingJobs = const [],
    this.systemJobNames = const [],
  });
}

// ---- Helpers exposed for the composition root -------------------------------

SidebarFeatureVisibility computeServerSidebarVisibility({
  required DartclawConfig? config,
  required bool hasChannels,
  required bool hasTaskService,
  required List<Map<String, dynamic>> schedulingJobs,
}) => computeSidebarFeatureVisibility(
  config: config,
  hasChannels: hasChannels,
  hasTaskService: hasTaskService,
  schedulingJobs: schedulingJobs,
);

/// Registers system dashboard pages on the given server's page registry.
///
/// Called by `composeServer` after constructing the server so the
/// post-construction side-effects happen in one place.
void registerServerSystemPages(
  DartclawServer server, {
  required HealthService? healthService,
  required AgentHarness worker,
  required WhatsAppChannel? whatsAppChannel,
  required SignalChannel? signalChannel,
  required GoogleChatWebhookHandler? googleChatWebhookHandler,
  required GuardChain? guardChain,
  required ProviderStatusService? providerStatus,
  required ConfigWriter? configWriter,
  required WorkflowService? workflowService,
  required ProjectService? projectService,
  required DartclawConfig? config,
  required SidebarFeatureVisibility visibility,
}) {
  registerSystemDashboardPages(
    server._pageRegistry,
    healthService: healthService,
    workerStateGetter: () => worker.state,
    whatsAppChannel: whatsAppChannel,
    signalChannel: signalChannel,
    googleChatChannel: googleChatWebhookHandler?.channel,
    guardChain: guardChain,
    providerStatus: providerStatus,
    runtimeConfigGetter: () => server._core.runtimeConfig,
    configWriter: configWriter,
    memoryStatusServiceGetter: () => server._observability.memoryStatusService,
    memoryPruneServiceGetter: () => server._memoryPruneService,
    memoryServiceGetter: () => server._observability.memoryService,
    searchBackendGetter: () => server._observability.searchBackend,
    memoryCorpusGetter: () => server._observability.memoryCorpus,
    scheduleServiceGetter: () => server._observability.scheduleService,
    kgServiceGetter: () => server._web.kgService,
    config: config,
    auditReader: server._core.dataDir != null ? AuditLogReader(dataDir: server._core.dataDir!) : null,
    settingsSurface: buildSettingsSurface(
      writer: configWriter,
      runtimeConfig: server._core.runtimeConfig,
      dataDir: server._core.dataDir,
      containerIsolationActive: config?.container.enabled ?? false,
      eventBus: server._observability.eventBus,
      configNotifier: server._core.configNotifier,
    ),
    channelAccessService: server._channelAccessService,
    guardEditorService: server._guardEditorService,
    pubsubHealthGetter: healthService != null
        ? () => healthService.pubsubHealth ?? const {'status': 'disabled', 'enabled': false}
        : null,
    showMemory: visibility.showMemory,
    showScheduling: visibility.showScheduling,
    showTasks: visibility.showTasks,
    showWorkflows: workflowService != null,
    projectService: projectService,
  );
}

// ---- Logger -----------------------------------------------------------------

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
