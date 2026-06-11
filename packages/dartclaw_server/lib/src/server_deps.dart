part of 'server.dart';

// ---- Dependency-group structs -----------------------------------------------
//
// These are intentionally not exported from the package barrel — they are an
// implementation detail of the DartclawServer/DartclawServerBuilder boundary.

class ServerCoreDeps {
  final SessionService sessions;
  final MessageService messages;
  final AgentHarness worker;
  final String staticDir;
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
  final String? webhookSecret;

  const ServerCoreDeps({
    required this.sessions,
    required this.messages,
    required this.worker,
    required this.staticDir,
    required this.authEnabled,
    required this.gatewayToken,
    required this.runtimeConfig,
    required this.kvService,
    required this.configWriter,
    required this.config,
    this.configNotifier,
    required this.restartService,
    required this.healthService,
    required this.tokenService,
    required this.resetService,
    required this.redactor,
    required this.guardChain,
    required this.webhookSecret,
  });
}

class ServerTurnDeps {
  final HarnessPool? pool;
  final TurnManager turns;

  const ServerTurnDeps({required this.pool, required this.turns});
}

class ServerChannelDeps {
  final ChannelManager? channelManager;
  final WhatsAppChannel? whatsAppChannel;
  final SignalChannel? signalChannel;
  final GoogleChatWebhookHandler? googleChatWebhookHandler;
  final GoogleChatSpaceEventsWiring? spaceEventsWiring;
  final ThreadBindingStore? threadBindingStore;

  const ServerChannelDeps({
    required this.channelManager,
    required this.whatsAppChannel,
    required this.signalChannel,
    required this.googleChatWebhookHandler,
    required this.spaceEventsWiring,
    required this.threadBindingStore,
  });
}

class ServerTaskDeps {
  final ProjectService? projectService;
  final GoalService? goalService;
  final TaskService? taskService;
  final TaskReviewService? taskReviewService;
  final WorktreeManager? worktreeManager;
  final TaskFileGuard? taskFileGuard;
  final AgentObserver? agentObserver;
  final MergeExecutor? mergeExecutor;
  final String? mergeStrategy;
  final String? baseRef;
  final TurnTraceService? traceService;
  final TaskEventService? taskEventService;
  final TaskEventRecorder? taskEventRecorder;
  final TaskProgressTracker? progressTracker;

  const ServerTaskDeps({
    required this.projectService,
    required this.goalService,
    required this.taskService,
    required this.taskReviewService,
    required this.worktreeManager,
    required this.taskFileGuard,
    required this.agentObserver,
    required this.mergeExecutor,
    required this.mergeStrategy,
    required this.baseRef,
    required this.traceService,
    required this.taskEventService,
    required this.taskEventRecorder,
    required this.progressTracker,
  });
}

class ServerObservabilityDeps {
  final EventBus? eventBus;
  final SseBroadcast? sseBroadcast;
  final ProviderStatusService? providerStatus;
  final MemoryFileService? memoryFile;
  final MemoryStatusService? memoryStatusService;
  final MemoryPruner? memoryPruner;
  final HeartbeatScheduler? heartbeat;
  final ScheduleService? scheduleService;
  final WorkspaceGitSync? gitSync;
  final EventBusSseBridge? eventBusSseBridge;

  const ServerObservabilityDeps({
    required this.eventBus,
    required this.sseBroadcast,
    required this.providerStatus,
    required this.memoryFile,
    required this.memoryStatusService,
    required this.memoryPruner,
    required this.heartbeat,
    required this.scheduleService,
    required this.gitSync,
    required this.eventBusSseBridge,
  });
}

class ServerWebDeps {
  final WorkflowService? workflowService;
  final WorkflowDefinitionSource? workflowDefinitionSource;
  final ContentGuardDisplayParams contentGuardDisplay;
  final HeartbeatDisplayParams heartbeatDisplay;
  final SchedulingDisplayParams schedulingDisplay;
  final WorkspaceDisplayParams workspaceDisplay;
  final AppDisplayParams appDisplay;

  const ServerWebDeps({
    required this.workflowService,
    required this.workflowDefinitionSource,
    required this.contentGuardDisplay,
    required this.heartbeatDisplay,
    required this.schedulingDisplay,
    required this.workspaceDisplay,
    required this.appDisplay,
  });
}

// ---- Helpers exposed for DartclawServerBuilder ------------------------------

SidebarFeatureVisibility computeServerSidebarVisibility({
  required DartclawConfig? config,
  required bool hasChannels,
  required GuardChain? guardChain,
  required bool hasHealthService,
  required bool hasTaskService,
  required bool hasPubSubHealth,
  required HeartbeatDisplayParams heartbeatDisplay,
  required SchedulingDisplayParams schedulingDisplay,
  required WorkspaceDisplayParams workspaceDisplay,
}) => computeSidebarFeatureVisibility(
  config: config,
  hasChannels: hasChannels,
  guardChain: guardChain,
  hasHealthService: hasHealthService,
  hasTaskService: hasTaskService,
  hasPubSubHealth: hasPubSubHealth,
  heartbeatDisplay: heartbeatDisplay,
  schedulingDisplay: schedulingDisplay,
  workspaceDisplay: workspaceDisplay,
);

/// Registers system dashboard pages on the given server's page registry.
///
/// Called by [DartclawServerBuilder.build] after constructing the server so
/// the post-construction side-effects happen in one place.
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
  required ContentGuardDisplayParams contentGuardDisplay,
  required HeartbeatDisplayParams heartbeatDisplay,
  required SchedulingDisplayParams schedulingDisplay,
  required WorkspaceDisplayParams workspaceDisplay,
  required AppDisplayParams appDisplay,
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
    contentGuardDisplay: contentGuardDisplay,
    heartbeatDisplay: heartbeatDisplay,
    schedulingDisplay: schedulingDisplay,
    workspaceDisplay: workspaceDisplay,
    auditReader: appDisplay.dataDir != null ? AuditLogReader(dataDir: appDisplay.dataDir!) : null,
    pubsubHealthGetter: healthService != null
        ? () => healthService.pubsubHealth ?? const {'status': 'disabled', 'enabled': false}
        : null,
    showHealth: visibility.showHealth,
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
