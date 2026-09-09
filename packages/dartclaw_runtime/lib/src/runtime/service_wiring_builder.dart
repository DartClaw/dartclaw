part of 'service_wiring.dart';

/// Cross-cutting deps threaded through the assembly's `_wireXxx` methods.
///
/// Late slots (serverRef, serverTurns) are bound via setters as construction
/// proceeds; closures capture them via getters so late-binding order is
/// preserved across method boundaries.
final class _WiringContext {
  final EventBus eventBus;
  final ConfigNotifier configNotifier;
  final String dataDir;
  final int port;
  final ResolvedAssets resolvedAssets;
  final String? builtInSkillsSourceDir;
  final MessageRedactor messageRedactor;
  final GuardAuditLogger auditLogger;

  /// Dedicated subscription credential stores, read per use so a re-issued
  /// token reaches the next spawn or mediated request without a restart.
  final SubscriptionCredentialStore subscriptions;

  /// One refresh authority per dedicated Codex store for the whole process.
  ///
  /// Single-flight is a property of this instance, so a second one would be a
  /// second refresher — exactly what the design forbids. Every DartClaw lane
  /// that touches the store shares this one.
  final CodexRefreshAuthority codexRefresh;

  /// Bound when the server is composed. A headless build composes none, so the
  /// surfaces that need one resolve through [composedServerGetter], which
  /// refuses, while the ones that merely may have one read [serverRefGetter].
  DartclawServer? _serverRef;
  late TurnManager _serverTurns;

  /// The provider entries the composed harness registrars declared, bound once
  /// the harness is wired.
  ///
  /// The probe lane resolves through these so a registrar-owned provider is
  /// probed under its own credential isolation rather than DartClaw's
  /// first-party arm. A lane that has not wired a harness yet — the staged
  /// headless provider-auth preflight — composed no registrar either, so an
  /// empty map is the honest answer rather than a missing one.
  Map<String, ProviderEntry> registeredProviderEntries = const {};

  /// The credential overlay those registrations present, bound with them.
  Map<String, String>? Function(String, Map<String, String>)? registrarCredentialOverlay;
  new({
    required this.eventBus,
    required this.configNotifier,
    required this.dataDir,
    required this.port,
    required this.resolvedAssets,
    required this.builtInSkillsSourceDir,
    required this.messageRedactor,
    required this.subscriptions,
    required this.codexRefresh,
  }) : auditLogger = GuardAuditLogger(dataDir: dataDir);

  void bindServer(DartclawServer server) => _serverRef = server;
  void bindTurns(TurnManager turns) => _serverTurns = turns;

  DartclawServer? Function() get serverRefGetter =>
      () => _serverRef;
  DartclawServer Function() get composedServerGetter =>
      () => _serverRef ?? (throw StateError('This runtime composed no server'));
  TurnManager Function() get turnManagerGetter =>
      () => _serverTurns;
}

/// Composes the turn manager the rest of the assembly threads through.
///
/// Built before the server because scheduling, the task layer and the restart
/// service all take it, and the server itself is one more consumer.
TurnManager _composeTurns(
  DartclawConfig config,
  _WiringContext ctx,
  StorageWiring storage,
  HarnessWiring harness,
  SecurityWiring security,
) => composeServerTurns(
  sessions: storage.sessions,
  messages: storage.messages,
  worker: harness.harness,
  behavior: harness.behavior,
  executions: harness.executions,
  policyResolver: harness.policyResolver,
  memoryFile: storage.personalMemoryFile,
  kv: storage.kvService,
  guardChain: security.guardChain,
  lockManager: harness.lockManager,
  resetService: harness.resetService,
  contextMonitor: harness.contextMonitor,
  redactor: ctx.messageRedactor,
  selfImprovement: harness.selfImprovement,
  usageTracker: harness.usageTracker,
  eventBus: ctx.eventBus,
  config: config,
);

DartclawServer _composeRuntimeServer(
  DartclawConfig config,
  String resolvedConfigPath,
  _WiringContext ctx,
  StorageWiring storage,
  TaskWiring task,
  HarnessWiring harness,
  SchedulingWiring scheduling,
  ProjectWiring project,
  ProviderStatusService providerStatus,
  WorkflowService workflowService,
  WorkflowRegistry workflowRegistry,
  RestartService restartService,
  ChannelWiring channel,
  SecurityWiring security,
  config_tools.ConfigWriter configWriter,
) => composeServer(
  core: ServerCoreDeps(
    sessions: storage.sessions,
    messages: storage.messages,
    worker: harness.primaryHarness,
    dataDir: ctx.dataDir,
    staticDir: ctx.resolvedAssets.staticDir,
    assetSource: ctx.resolvedAssets.source,
    authEnabled: harness.authEnabled,
    gatewayToken: harness.resolvedGatewayToken,
    runtimeConfig: scheduling.runtimeConfig,
    kvService: storage.kvService,
    configWriter: configWriter,
    config: config,
    configNotifier: ctx.configNotifier,
    restartService: restartService,
    healthService: harness.healthService,
    tokenService: harness.tokenService,
    resetService: harness.resetService,
    redactor: ctx.messageRedactor,
    guardChain: security.guardChain,
    auditLogger: security.auditLogger,
    mcpToolCanonicals: harness.ownMcpToolCanonicals,
    webhookSecret: channel.webhookSecret,
    resultTrimmer: harness.resultTrimmer,
  ),
  turn: ServerTurnDeps(turns: ctx._serverTurns, executions: harness.executions),
  channels: ServerChannelDeps(
    channelManager: channel.channelManager,
    whatsAppChannel: channel.whatsAppChannel,
    signalChannel: channel.signalChannel,
    googleChatWebhookHandler: channel.googleChatWebhookHandler,
    spaceEventsWiring: channel.spaceEventsWiring,
    threadBindingStore: channel.threadBindingStore,
  ),
  tasks: ServerTaskDeps(
    projectService: project.projectService,
    goalService: storage.goalService,
    taskService: storage.taskService,
    taskReviewService: task.taskReviewService,
    worktreeManager: task.worktreeManager,
    taskFileGuard: task.taskFileGuard,
    runnerObserver: task.runnerObserver,
    mergeExecutor: task.mergeExecutor,
    mergeStrategy: config.tasks.worktreeMergeStrategy,
    baseRef: config.tasks.worktreeBaseRef,
    traceService: storage.traceService,
    taskEventService: storage.taskEventService,
    executionDrainer: task.drainExecutions,
    eventBus: ctx.eventBus,
  ),
  observability: ServerObservabilityDeps(
    eventBus: ctx.eventBus,
    sseBroadcast: harness.sseBroadcast!,
    providerStatus: providerStatus,
    memoryFile: storage.memoryFile,
    memoryStatusService: scheduling.memoryStatusService,
    inspectMemorySearch: storage.inspectMemorySearch,
    conversationSearch: storage.conversationSearch,
    memoryPruner: scheduling.memoryPruner,
    memoryIndex: storage.memoryIndex,
    searchBackend: storage.searchBackend,
    memoryCorpus: storage.memoryCorpus,
    scheduleService: scheduling.scheduleService,
    schedulingJobsApplier: scheduling.applyJobs,
    pendingScheduleChanges: scheduling.pendingScheduleChanges,
    gitSync: scheduling.gitSync,
  ),
  web: ServerWebDeps(
    workflowService: workflowService,
    workflowDefinitionSource: workflowRegistry,
    kgService: storage.kg,
    contentGuardApiKeyConfigured:
        config.security.contentGuardClassifier == 'claude_binary' ||
        (Platform.environment['ANTHROPIC_API_KEY']?.isNotEmpty ?? false),
    contentGuardFailOpen: security.contentGuardFailOpen,
    schedulingJobs: scheduling.displayJobs,
    systemJobNames: scheduling.systemJobNames,
  ),
);
