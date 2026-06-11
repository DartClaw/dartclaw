part of 'service_wiring.dart';

final _mcpToolsLog = Logger('ServiceWiring');

AdvisorSubscriber? _registerMcpTools(
  DartclawConfig config,
  _WiringContext ctx,
  DartclawServer server,
  HarnessWiring harness,
  StorageWiring storage,
  SecurityWiring security,
  ChannelWiring channel,
) {
  final handlers = harness.memoryHandlers;
  server.registerTool(DelegateToAgentTool(config: config, pool: harness.pool));
  server.registerTool(SessionsSendTool(delegate: harness.sessionDelegate));
  server.registerTool(MemorySaveTool(handler: handlers.onSave));
  server.registerTool(MemorySearchTool(handler: handlers.onSearch));
  server.registerTool(MemoryReadTool(handler: handlers.onRead));
  final auditLogger = security.auditLogger;
  // Register onboarding_complete only when onboarding is active at startup.
  // The single global MCP surface is shared with task/cron/channel agents;
  // the tool's onboardingActive flag refuses calls from non-onboarding contexts
  // even if registration were to occur (belt-and-suspenders).
  final onboardingFile = File('${config.workspaceDir}/ONBOARDING.md');
  final onboardingActive = onboardingFile.existsSync();
  if (onboardingActive) {
    server.registerTool(OnboardingCompleteTool(workspaceDir: config.workspaceDir, onboardingActive: true));
  }
  server.registerTool(KgAddTool(kg: storage.kg, auditLogger: auditLogger));
  server.registerTool(KgQueryTool(kg: storage.kg));
  server.registerTool(KgTimelineTool(kg: storage.kg));
  server.registerTool(KgInvalidateTool(kg: storage.kg, auditLogger: auditLogger));
  server.registerTool(KgContradictionsTool(kg: storage.kg));
  server.registerTool(
    WebFetchTool(classifier: security.contentClassifier, failOpenOnClassification: security.contentGuardFailOpen),
  );

  AdvisorSubscriber? advisorSubscriber;
  if (config.advisor.enabled) {
    advisorSubscriber = AdvisorSubscriber(
      pool: harness.pool,
      sessions: storage.sessions,
      taskService: storage.taskService,
      channelManager: channel.channelManager,
      eventBus: ctx.eventBus,
      traceService: storage.traceService,
      threadBindings: channel.threadBindingStore,
      triggers: config.advisor.triggers,
      periodicIntervalMinutes: config.advisor.periodicIntervalMinutes,
      maxWindowTurns: config.advisor.maxWindowTurns,
      maxPriorReflections: config.advisor.maxPriorReflections,
      model: config.advisor.model,
      effort: config.advisor.effort,
    );
    advisorSubscriber.subscribe();
  }

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
        _mcpToolsLog.info('Registered brave_search MCP tool');
      case 'tavily':
        server.registerTool(
          TavilySearchTool(
            provider: TavilySearchProvider(apiKey: providerConfig.apiKey),
            contentGuard: security.contentGuard,
          ),
        );
        _mcpToolsLog.info('Registered tavily_search MCP tool');
      default:
        _mcpToolsLog.warning('Unknown search provider: $providerName — skipping');
    }
  }

  return advisorSubscriber;
}
