part of 'service_wiring.dart';

DartclawServerBuilder _buildServerBuilderPreServer(
  DartclawConfig config,
  _WiringContext ctx,
  StorageWiring storage,
  HarnessWiring harness,
  TaskWiring task,
  ChannelWiring channel,
  SecurityWiring security,
  CanvasService? canvasService,
) {
  return DartclawServerBuilder()
    ..sessions = storage.sessions
    ..messages = storage.messages
    ..traceService = storage.traceService
    ..taskEventService = storage.taskEventService
    ..worker = harness.harness
    ..staticDir = ctx.resolvedAssets?.staticDir ?? config.server.staticDir
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
    ..redactor = ctx.messageRedactor
    ..gatewayToken = harness.resolvedGatewayToken
    ..selfImprovement = harness.selfImprovement
    ..usageTracker = harness.usageTracker
    ..eventBus = ctx.eventBus
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
    ..appDisplay = AppDisplayParams(name: config.server.name, dataDir: ctx.dataDir);
}

void _applyServerBuilderPostServer(
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
) {
  final configWriter = config_tools.ConfigWriter(configPath: resolvedConfigPath);
  ctx.builder
    ..heartbeat = scheduling.heartbeat
    ..scheduleService = scheduling.scheduleService
    ..gitSync = scheduling.gitSync
    ..runtimeConfig = scheduling.runtimeConfig
    ..memoryStatusService = scheduling.memoryStatusService
    ..memoryPruner = scheduling.memoryPruner
    ..configWriter = configWriter
    ..config = config
    ..configNotifier = ctx.configNotifier
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
    ..schedulingDisplay = SchedulingDisplayParams(
      jobs: scheduling.displayJobs,
      systemJobNames: scheduling.systemJobNames,
      scheduledTasks: config.scheduling.taskDefinitions,
    );
}
