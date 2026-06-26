part of 'service_wiring.dart';

final _mcpToolsLog = Logger('ServiceWiring');

Future<(AdvisorSubscriber?, OutboundMcpPool?)> _registerMcpTools(
  DartclawConfig config,
  _WiringContext ctx,
  DartclawServer server,
  HarnessWiring harness,
  StorageWiring storage,
  SecurityWiring security,
  ChannelWiring channel, {
  OutboundMcpTransportFactory? outboundMcpTransportFactory,
}) async {
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
  final kgGuardEvaluator = _kgGuardEvaluator(security.guardChain);
  // KG write tools are registered without a principalProvider, so writes run as
  // the steward principal (`system`). This is the deliberate S04 steward-only
  // fallback: the inbound `/mcp` gateway authenticates a single shared gateway
  // token with no per-caller identity, so every authenticated (operator-trusted)
  // caller is treated as steward. Per-caller KG ownership requires inbound MCP
  // caller-identity propagation, deferred to the FR9–FR11 / 0.19.x scope. Do not
  // remove this without wiring a real per-caller principal end to end.
  server.registerTool(KgAddTool(kg: storage.kg, auditLogger: auditLogger, guardEvaluator: kgGuardEvaluator));
  server.registerTool(KgQueryTool(kg: storage.kg));
  server.registerTool(KgTimelineTool(kg: storage.kg));
  server.registerTool(KgInvalidateTool(kg: storage.kg, auditLogger: auditLogger, guardEvaluator: kgGuardEvaluator));
  server.registerTool(KgContradictionsTool(kg: storage.kg));
  server.registerTool(
    ContextResearchTool(
      memorySearch: storage.searchBackend,
      kg: storage.kg,
      wikiSearch: WikiSearchSource(workspaceDir: config.workspaceDir),
      synthesizer: ContextResearchTool.delegateSynthesizer(harness.sessionDelegate),
      metricsSink: (metrics) async {
        ctx.eventBus.fire(
          ContextResearchMetricsEvent(
            inputTokens: metrics.inputTokens,
            outputTokens: metrics.outputTokens,
            sourcesCount: metrics.sourcesCount,
            truncated: metrics.truncated,
            cacheBypass: metrics.cacheBypass,
            timestamp: DateTime.now(),
          ),
        );
      },
    ),
  );
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

  final outboundMcpPool = await _registerOutboundMcpTools(
    config,
    ctx,
    server,
    security,
    transportFactory: outboundMcpTransportFactory,
  );

  return (advisorSubscriber, outboundMcpPool);
}

KgGuardEvaluator? _kgGuardEvaluator(GuardChain? guardChain) {
  if (guardChain == null) return null;
  return (tool, args, principal) {
    return guardChain.evaluateBeforeToolCall(tool, args, sessionId: principal, rawProviderToolName: tool);
  };
}

Future<OutboundMcpPool?> _registerOutboundMcpTools(
  DartclawConfig config,
  _WiringContext ctx,
  DartclawServer server,
  SecurityWiring security, {
  OutboundMcpTransportFactory? transportFactory,
}) async {
  final enabledRegistry = config.mcpServers.enabledRegistry;
  if (enabledRegistry.isEmpty) return null;

  final policy = _RuntimeOutboundMcpPolicy();
  for (final MapEntry(key: serverName, value: entry) in enabledRegistry.entries) {
    policy.allow(serverName, entry.allowTools);
  }
  final pool = OutboundMcpPool(
    mcpServers: config.mcpServers,
    credentials: config.credentials,
    transportFactory: transportFactory,
    guardDecisionHook: policy.decide,
    auditLogger: security.auditLogger,
    eventBus: ctx.eventBus,
  );
  try {
    var registered = 0;
    for (final MapEntry(key: serverName, value: entry) in enabledRegistry.entries) {
      final surfaceTools = entry.surfaceTools.toSet();
      if (surfaceTools.isEmpty) continue;
      final exposedTools = await _listedOutboundTools(pool, serverName);
      if (exposedTools == null) continue;
      for (final tool in exposedTools.where((tool) => surfaceTools.contains(tool.name))) {
        final adapter = OutboundMcpToolAdapter(
          serverName: serverName,
          tool: tool,
          pool: pool,
          callerProvider: _systemOutboundMcpCaller,
        );
        if (server.mcpHandler.toolNames.contains(adapter.name)) {
          throw StateError('Outbound MCP tool name collision: ${adapter.name}');
        }
        server.registerTool(adapter);
        registered++;
      }
    }
    _mcpToolsLog.info('Registered $registered outbound MCP tool(s)');
    return pool;
  } catch (error, stackTrace) {
    try {
      await pool.close();
    } catch (closeError, closeStackTrace) {
      _mcpToolsLog.warning(
        'Failed to close outbound MCP pool after startup error: $closeError',
        closeError,
        closeStackTrace,
      );
    }
    Error.throwWithStackTrace(error, stackTrace);
  }
}

Future<List<OutboundMcpTool>?> _listedOutboundTools(OutboundMcpPool pool, String serverName) async {
  try {
    return await pool.listTools(serverName, surfacedOnly: false);
  } on OutboundMcpException catch (error) {
    if (error.code == 'invalid_surface_tool') {
      throw StateError(error.message);
    }
    _mcpToolsLog.warning('Skipping outbound MCP server "$serverName": ${error.message}');
    return null;
  } catch (error) {
    _mcpToolsLog.warning('Skipping outbound MCP server "$serverName": $error');
    return null;
  }
}

final class _RuntimeOutboundMcpPolicy {
  Map<String, Set<String>> _allowlist = const {};

  void allow(String serverName, Iterable<String> toolNames) {
    _allowlist = {..._allowlist, serverName: Set.unmodifiable(toolNames)};
  }

  Future<OutboundMcpGuardDecision> decide(OutboundMcpGuardRequest request) async {
    final guard = EgressGuard(allowlist: _allowlist);
    final verdict = await guard.evaluate(
      GuardContext(
        hookPoint: 'outboundMcpToolsCall',
        toolName: 'tools/call',
        rawProviderToolName: request.toolName,
        toolInput: {'server': request.serverName, 'tool': request.toolName, 'arguments': request.arguments},
        sessionId: request.caller.sessionId,
        timestamp: DateTime.now(),
      ),
    );
    if (verdict.isBlock) return OutboundMcpGuardDecision.deny(verdict.message ?? 'Egress denied');
    return const OutboundMcpGuardDecision.allow();
  }
}

OutboundMcpCaller _systemOutboundMcpCaller() => const OutboundMcpCaller(sessionId: 'system', principal: 'system');
