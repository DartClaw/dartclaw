part of 'service_wiring.dart';

final _mcpToolsLog = Logger('ServiceWiring');

(WorkshopCanvasSubscriber?, AdvisorSubscriber?) _registerMcpTools(
  DartclawConfig config,
  _WiringContext ctx,
  DartclawServer server,
  HarnessWiring harness,
  StorageWiring storage,
  SecurityWiring security,
  ChannelWiring channel,
  CanvasService? canvasService,
) {
  final handlers = harness.memoryHandlers;
  server.registerTool(SessionsSendTool(delegate: harness.sessionDelegate));
  server.registerTool(SessionsSpawnTool(delegate: harness.sessionDelegate));
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

  WorkshopCanvasSubscriber? workshopCanvasSubscriber;
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
    workshopCanvasSubscriber.subscribe(ctx.eventBus);
  }

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

  return (workshopCanvasSubscriber, advisorSubscriber);
}
