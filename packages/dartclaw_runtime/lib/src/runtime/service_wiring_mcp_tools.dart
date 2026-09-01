part of 'service_wiring.dart';

final _mcpToolsLog = Logger('DartclawRuntime');

Future<OutboundMcpPool?> _registerMcpTools(
  DartclawConfig config,
  _WiringContext ctx,
  DartclawServer server,
  HarnessWiring harness,
  StorageWiring storage,
  SecurityWiring security,
  TaskWiring task,
  ThreadBindingStore? threadBindingStore,
  SchedulingWiring scheduling,
  WorkflowDefinitionSource workflowDefinitions,
  WorkflowService workflowService,
  config_tools.ConfigWriter configWriter, {
  OutboundMcpTransportFactory? outboundMcpTransportFactory,
}) async {
  server.registerTool(SessionsSpawnTool(sessions: harness.logicalAgentSessions));
  server.registerTool(SessionsSendTool(sessions: harness.logicalAgentSessions));
  server.registerTool(TaskCreateTool(tasks: storage.taskService));
  server.registerTool(TaskReviewTool(reviews: task.taskReviewService));
  server.registerTool(TaskListTool(tasks: storage.taskService));
  server.registerTool(ReviewListTool(tasks: storage.taskService));
  // The binding tools register unconditionally: an absent store is reported at
  // call time, so their availability does not change with an operator toggle.
  server.registerTool(TaskBindTool(tasks: storage.taskService, bindings: threadBindingStore));
  server.registerTool(TaskUnbindTool(bindings: threadBindingStore));
  // Orchestration and content tools. They take no session, channel or caller
  // argument, which is what makes them answer the same way to a chat turn and a
  // cron turn — and is why a containerized lane reaches exactly what the host
  // lane of the same kind reaches, through the shared canonical mapping.
  final scheduleMutations = ScheduleMutationService(writer: configWriter, dataDir: ctx.dataDir);
  server.registerTool(WorkflowRunTool(definitions: workflowDefinitions, workflows: workflowService));
  server.registerTool(WorkflowListTool(definitions: workflowDefinitions));
  server.registerTool(ScheduleUpsertTool(mutations: scheduleMutations));
  server.registerTool(ScheduleListTool(mutations: scheduleMutations, schedules: scheduling.scheduleService));
  server.registerTool(
    AttachMediaTool(workspace: WorkspacePathGuard(config.workspaceDir), delivery: scheduling.deliveryService),
  );
  server.registerTool(WikiWriteTool(wiki: WikiPageStore(workspaceDir: config.workspaceDir)));
  for (final tool in harness.semanticMcpTools) {
    server.registerTool(tool);
  }
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
  // KG write tools are registered without a principalProvider, so writes run as
  // the steward principal (`system`). The gateway token authenticates the
  // deployment rather than a person, so an owner write has no narrower principal
  // to carry. A named MCP client does carry one, but no write tool is in its
  // profile, so it can never reach these.
  server.registerTool(KgAddTool(kg: storage.kg, auditLogger: auditLogger));
  server.registerTool(KgQueryTool(kg: storage.kg));
  server.registerTool(KgTimelineTool(kg: storage.kg));
  server.registerTool(KgInvalidateTool(kg: storage.kg, auditLogger: auditLogger));
  server.registerTool(KgContradictionsTool(kg: storage.kg));
  server.registerTool(
    ContextResearchTool(
      memorySearch: storage.searchBackend,
      kg: storage.kg,
      sourceResolver: LiveCitationSourceResolver(
        corpus: storage.memoryCorpus,
        wiki: WikiSearchSource(workspaceDir: config.workspaceDir),
        kg: storage.kg,
        inbox: KnowledgeInboxReadService(workspaceDir: config.workspaceDir),
      ),
      synthesizer: ContextResearchTool.logicalAgentSynthesizer(harness.logicalAgentSessions),
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
  return _registerOutboundMcpTools(config, ctx, server, security, transportFactory: outboundMcpTransportFactory);
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
    contentScan: security.contentScan,
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
