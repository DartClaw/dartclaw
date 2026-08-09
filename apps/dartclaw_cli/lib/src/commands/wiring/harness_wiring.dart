import 'dart:io';
import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart' hide HarnessConfig;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../serve_command.dart' show ExitFn, mcpDisallowedTools;
import 'storage_wiring.dart';
import 'security_wiring.dart';

/// Constructs and exposes harness-layer services.
///
/// Owns agent definitions, primary + worker harnesses, execution capacity, token service,
/// usage tracker, health service, context management, logical-agent sessions, behavior
/// service, self-improvement, SSE broadcast, and auth state.
class HarnessWiring {
  HarnessWiring({
    required this.config,
    required String dataDir,
    required int port,
    required HarnessFactory harnessFactory,
    required ExitFn exitFn,
    required StorageWiring storage,
    required SecurityWiring security,
    required MessageRedactor messageRedactor,
    required EventBus eventBus,
    ConfigNotifier? configNotifier,
  }) : _dataDir = dataDir,
       _port = port,
       _harnessFactory = harnessFactory,
       _exitFn = exitFn,
       _storage = storage,
       _security = security,
       _messageRedactor = messageRedactor,
       _eventBus = eventBus,
       _configNotifier = configNotifier;

  final DartclawConfig config;
  final String _dataDir;
  final int _port;
  final HarnessFactory _harnessFactory;
  final ExitFn _exitFn;
  final StorageWiring _storage;
  final SecurityWiring _security;
  final MessageRedactor _messageRedactor;
  final EventBus _eventBus;
  final ConfigNotifier? _configNotifier;

  static final _log = Logger('HarnessWiring');

  late AgentHarness _harness;
  late GuardChain _primaryGuardChain;
  late ExecutionCoordinator _executions;
  late HarnessConfig _harnessConfig;
  late List<AgentDefinition> _agentDefs;
  late Map<String, AgentDefinition> _agentMap;
  late List<McpTool> _semanticMcpTools;
  late Map<String, CanonicalTool> _ownMcpToolCanonicals;
  late BehaviorFileService _behavior;
  late SelfImprovementService _selfImprovement;
  late LogicalAgentSessionService _logicalAgentSessions;
  late UsageTracker _usageTracker;
  late HealthService _healthService;
  late SseBroadcast _sseBroadcast;
  late ContextMonitor _contextMonitor;
  late ExplorationSummarizer _explorationSummarizer;
  late ResultTrimmer _resultTrimmer;
  late SessionLockManager _lockManager;
  late SessionResetService _resetService;
  late ({
    Future<Map<String, dynamic>> Function(Map<String, dynamic>) onSave,
    Future<Map<String, dynamic>> Function(Map<String, dynamic>) onSearch,
    Future<Map<String, dynamic>> Function(Map<String, dynamic>) onRead,
  })
  _memoryHandlers;
  BudgetEnforcer? _budgetEnforcer;
  Map<String, ProviderEntry> _providerStatusEntries = const {};
  bool _authEnabled = false;
  TokenService? _tokenService;
  String? _resolvedGatewayToken;

  AgentHarness get harness => _harness;
  ExecutionCoordinator get executions => _executions;
  HarnessConfig get harnessConfig => _harnessConfig;
  List<AgentDefinition> get agentDefs => _agentDefs;
  Map<String, AgentDefinition> get agentMap => _agentMap;
  List<McpTool> get semanticMcpTools => _semanticMcpTools;
  Map<String, CanonicalTool> get ownMcpToolCanonicals => _ownMcpToolCanonicals;
  BehaviorFileService get behavior => _behavior;
  SelfImprovementService get selfImprovement => _selfImprovement;
  LogicalAgentSessionService get logicalAgentSessions => _logicalAgentSessions;
  UsageTracker get usageTracker => _usageTracker;
  HealthService get healthService => _healthService;
  SseBroadcast get sseBroadcast => _sseBroadcast;
  ContextMonitor get contextMonitor => _contextMonitor;
  ExplorationSummarizer get explorationSummarizer => _explorationSummarizer;
  SessionLockManager get lockManager => _lockManager;
  SessionResetService get resetService => _resetService;
  ({
    Future<Map<String, dynamic>> Function(Map<String, dynamic>) onSave,
    Future<Map<String, dynamic>> Function(Map<String, dynamic>) onSearch,
    Future<Map<String, dynamic>> Function(Map<String, dynamic>) onRead,
  })
  get memoryHandlers => _memoryHandlers;
  BudgetEnforcer? get budgetEnforcer => _budgetEnforcer;
  Map<String, ProviderEntry> get providerStatusEntries => _providerStatusEntries;
  Set<String> get continuityProviders => _harnessFactory.probeContinuityProviders();
  bool get authEnabled => _authEnabled;
  TokenService? get tokenService => _tokenService;
  String? get resolvedGatewayToken => _resolvedGatewayToken;

  /// Wires harness services. [serverRefGetter] is resolved lazily for
  /// the logical-agent session dispatch closure.
  Future<void> wire({required DartclawServer Function() serverRefGetter}) async {
    _behavior = BehaviorFileService(
      workspaceDir: config.workspaceDir,
      projectDir: p.join(Directory.current.path, '.dartclaw'),
      maxMemoryBytes: config.memory.maxBytes,
      onboardingExpiryDays: config.onboarding.expiryDays,
      compactInstructions: config.context.compactInstructions,
      identifierPreservation: config.context.identifierPreservation,
      identifierInstructions: config.context.identifierInstructions,
    );
    final staticPrompt = await _behavior.composeStaticPrompt();

    _selfImprovement = SelfImprovementService(workspaceDir: config.workspaceDir);

    _memoryHandlers = createMemoryHandlers(
      memory: _storage.memory,
      memoryFile: _storage.memoryFile,
      searchBackend: _storage.searchBackend,
      selfImprovement: _selfImprovement,
    );

    final semanticMcpTools = <McpTool>[
      WebFetchTool(classifier: _security.contentClassifier, failOpenOnClassification: _security.contentGuardFailOpen),
      MemorySaveTool(handler: _memoryHandlers.onSave),
    ];
    for (final entry in config.search.providers.entries) {
      if (!entry.value.enabled || entry.value.apiKey.isEmpty) continue;
      switch (entry.key) {
        case 'brave':
          semanticMcpTools.add(
            BraveSearchTool(
              provider: BraveSearchProvider(apiKey: entry.value.apiKey),
              contentGuard: _security.contentGuard,
            ),
          );
        case 'tavily':
          semanticMcpTools.add(
            TavilySearchTool(
              provider: TavilySearchProvider(apiKey: entry.value.apiKey),
              contentGuard: _security.contentGuard,
            ),
          );
        default:
          _log.warning('Unknown search provider: ${entry.key} — skipping');
      }
    }
    _semanticMcpTools = List.unmodifiable(semanticMcpTools);
    _ownMcpToolCanonicals = Map.unmodifiable({
      'sessions_spawn': CanonicalTool.sessionsSpawn,
      'sessions_send': CanonicalTool.sessionsSend,
      for (final tool in _semanticMcpTools)
        tool.name: switch (tool.name) {
          'web_fetch' => CanonicalTool.webFetch,
          'brave_search' || 'tavily_search' => CanonicalTool.webSearch,
          'memory_save' => CanonicalTool.memorySave,
          _ => throw StateError('Missing canonical mapping for own MCP tool: ${tool.name}'),
        },
    });

    final defaultProviderId = ProviderIdentity.normalize(config.agent.provider);
    _authEnabled = config.gateway.authMode != 'none';
    if (_authEnabled) {
      _resolvedGatewayToken = config.gateway.token ?? TokenService.loadFromFile(_dataDir);
      if (_resolvedGatewayToken == null) {
        final ts = TokenService();
        _resolvedGatewayToken = ts.token;
        TokenService.persistToFile(_dataDir, _resolvedGatewayToken!);
      }
      _tokenService = TokenService(token: _resolvedGatewayToken!);
    } else {
      final host = config.server.host;
      if (_isLoopbackHost(host)) {
        _log.warning('Auth disabled on loopback — acceptable for local dev only');
      } else {
        _log.severe('CRITICAL: Auth disabled on network-accessible host $host');
      }
    }

    final mcpEnabled = _resolvedGatewayToken != null || (!_authEnabled && _isLoopbackHost(config.server.host));
    _agentDefs = config.agent.definitions.isNotEmpty ? config.agent.definitions : [AgentDefinition.searchAgent()];
    _agentMap = {for (final a in _agentDefs) a.id: a};
    _harnessConfig = HarnessConfig(
      disallowedTools: mcpDisallowedTools(
        mcpEnabled: mcpEnabled,
        searchEnabled: _ownMcpToolCanonicals.containsValue(CanonicalTool.webSearch),
        userDisallowed: config.agent.disallowedTools,
      ),
      maxTurns: config.agent.maxTurns,
      model: config.agent.model,
      effort: config.agent.effort,
      appendSystemPrompt: staticPrompt,
      mcpServerUrl: mcpEnabled ? 'http://localhost:$_port/mcp' : null,
      mcpGatewayToken: _resolvedGatewayToken,
    );

    final credentialRegistry = CredentialRegistry(credentials: config.credentials, env: Platform.environment);
    _warnToolPolicyEnforcementBoundaries(defaultProviderId);
    final acpValidationResults = await _validateConfiguredAcpTargets(config);
    for (final entry in _canonicalAcpAgentEntries(config.harness.acp).entries) {
      if (acpValidationResults[entry.key]?.status != AcpTargetValidationStatus.passed) {
        continue;
      }
      _harnessFactory.registerAcpAgent(entry.key, entry.value);
    }
    // Each runner gets its own TaskToolFilterGuard so per-task/per-turn
    // allowedTools enforcement is isolated across concurrent runners.
    final primaryFilter = TaskToolFilterGuard();
    _primaryGuardChain = _buildRunnerGuardChain(_security.guardChain, primaryFilter, _security.toolPolicyCascade);
    late final Map<String, ProviderEntry> providerEntries;
    late final Map<String, List<String>> providerProfiles;
    late final Map<String, int> providerCapacities;
    try {
      final profileIds = _security.containerManagers.isEmpty ? ['workspace'] : ['workspace', 'restricted'];
      providerEntries = _effectiveWorkerProviderEntries(config, acpValidationResults);
      _providerStatusEntries = providerEntries;
      providerProfiles = {
        for (final providerId in providerEntries.keys) providerId: _profilesForProvider(config, providerId, profileIds),
      };
      providerCapacities = {
        for (final providerEntry in providerEntries.entries) providerEntry.key: providerEntry.value.effectivePoolSize,
      };
      final totalCapacity = providerCapacities.values.fold(0, (sum, capacity) => sum + capacity);
      if (totalCapacity > 0) {
        _log.info('Worker capacity: up to $totalCapacity execution(s) + 1 primary-interactive lane');
      }

      final validationProviders = ProvidersConfig(
        entries: _effectiveValidationProviderEntries(config, acpValidationResults),
      );
      final validation = await ProviderValidator.validate(
        providers: validationProviders,
        registry: credentialRegistry,
        defaultProvider: defaultProviderId,
      );
      for (final warning in validation.warnings) {
        _log.warning(warning);
      }
      if (validation.errors.isNotEmpty) {
        throw StateError(validation.errors.join('\n'));
      }

      _harness = _harnessFactory.create(
        defaultProviderId,
        HarnessFactoryConfig(
          cwd: Directory.current.path,
          executable: _resolveProviderExecutable(config, defaultProviderId),
          turnTimeout: Duration(seconds: config.server.workerTimeout),
          onMemorySave: _memoryHandlers.onSave,
          onMemorySearch: _memoryHandlers.onSearch,
          onMemoryRead: _memoryHandlers.onRead,
          onPermissionDenied: (toolName, reason) {
            _eventBus.fire(ToolPermissionDeniedEvent(toolName: toolName, reason: reason, timestamp: DateTime.now()));
          },
          harnessConfig: _harnessConfig,
          historyConfig: config.agent.history,
          providerOptions: _providerOptions(config, defaultProviderId),
          containerManager: _containerManagerForProvider(config, _security, defaultProviderId),
          guardChain: _primaryGuardChain,
          ownMcpToolCanonicals: _ownMcpToolCanonicals,
          acpPermissionDecision: (request) => _acpPermissionDecision(_primaryGuardChain, request),
          acpReverseCallAudit: _auditAcpReverseCall,
          environment: _providerEnvironment(
            config,
            defaultProviderId,
            _credentialProviderIdForProvider(config, defaultProviderId),
            credentialRegistry,
          ),
        ),
      );
      _wireCompactionCallbacks(_harness);
      await _harness.start();
    } catch (e, st) {
      _log.severe('Failed to start harness', e, st);
      await _storage.memoryFile.dispose();
      await _storage.turnStateStore.dispose();
      for (final manager in _security.containerManagers.values) {
        try {
          await manager.stop();
        } catch (stopErr) {
          _log.fine('Error stopping container during harness startup failure cleanup', stopErr);
        }
      }
      await _security.credentialProxy?.stop();
      await _storage.dispose();
      _exitFn(1);
    }

    _sseBroadcast = SseBroadcast();
    _contextMonitor = ContextMonitor(
      reserveTokens: config.context.reserveTokens,
      warningThreshold: config.context.warningThreshold,
    );
    // Compaction cycle state is shared across runners, but flush suppression is
    // resolved per runner inside TurnRunner from that harness's capability.
    // CompactionCompletedEvent advances the shared cycle counter for dedup.
    _eventBus.on<CompactionCompletedEvent>().listen((_) => _contextMonitor.onCompactionCompleted());
    _resultTrimmer = ResultTrimmer(maxBytes: config.context.maxResultBytes);
    _explorationSummarizer = ExplorationSummarizer(
      trimmer: _resultTrimmer,
      thresholdTokens: config.context.explorationSummaryThreshold,
    );
    _lockManager = SessionLockManager(maxParallel: config.server.maxParallelTurns);
    _resetService = SessionResetService(
      sessions: _storage.sessions,
      messages: _storage.messages,
      resetHour: config.sessions.resetHour,
      idleTimeoutMinutes: config.sessions.idleTimeoutMinutes,
    );

    // Register harness-layer services with ConfigNotifier for hot-reload.
    if (_configNotifier != null) {
      _configNotifier.register(_contextMonitor);
      _configNotifier.register(_resultTrimmer);
      _configNotifier.register(_lockManager);
      _configNotifier.register(_resetService);
    }

    _usageTracker = UsageTracker(
      dataDir: _dataDir,
      kv: _storage.kvService,
      budgetWarningTokens: config.usage.budgetWarningTokens,
      maxFileSizeBytes: config.usage.maxFileSizeBytes,
    );

    _healthService = HealthService(
      worker: _harness,
      searchDbPath: config.searchDbPath,
      sessionsDir: config.sessionsDir,
      tasksDir: p.join(config.server.dataDir, 'tasks'),
      usageTracker: _usageTracker,
    );

    _logicalAgentSessions = LogicalAgentSessionService(
      dispatch: ({required sessionId, required message, required agentId, required createSession}) async {
        final definition = _agentMap[agentId] ?? (throw StateError('Unknown agent: $agentId'));
        final persona = definition.prompt.trim().isEmpty ? null : definition.prompt;
        final trimmedModel = definition.model?.trim();
        final trimmedEffort = definition.effort?.trim();
        final configuredProvider = definition.provider?.trim();
        final agentProviderId = configuredProvider == null || configuredProvider.isEmpty
            ? defaultProviderId
            : ProviderIdentity.normalize(configuredProvider);
        Session? session;
        if (createSession) {
          final workerProfile = _logicalAgentWorkerProfile(config, _security, definition, agentProviderId);
          session = await _storage.sessions.getOrCreateByKey(
            sessionId,
            type: SessionType.logicalAgent,
            provider: agentProviderId,
            securityProfile: workerProfile,
          );
        } else {
          session = await _storage.sessions.getByKey(sessionId);
          if (session == null || session.type != SessionType.logicalAgent) {
            throw StateError('Unknown logical-agent session: $sessionId');
          }
        }
        if (session.provider == null || session.securityProfile == null) {
          throw StateError('Logical-agent session is missing pinned execution routing: $sessionId');
        }

        final srv = serverRefGetter();
        final turnId = await srv.turns.reserveTurn(
          session.id,
          agentName: agentId,
          model: trimmedModel == null || trimmedModel.isEmpty ? null : trimmedModel,
          effort: trimmedEffort == null || trimmedEffort.isEmpty ? null : trimmedEffort,
          systemPromptOverride: persona,
          workerProfile: session.securityProfile,
        );
        try {
          await _storage.messages.insertMessage(sessionId: session.id, role: 'user', content: message);
          final history = await _storage.messages.getMessages(session.id);
          srv.turns.executeTurn(
            session.id,
            turnId,
            [
              for (final entry in history) {'role': entry.role, 'content': entry.content},
            ],
            source: createSession ? 'sessions_spawn' : 'sessions_send',
            agentName: agentId,
          );
        } catch (_) {
          srv.turns.releaseTurn(session.id, turnId);
          rethrow;
        }
        final outcome = await srv.turns.waitForOutcome(session.id, turnId);
        if (outcome.status != TurnStatus.completed) {
          throw StateError('Agent turn failed: ${outcome.errorMessage}');
        }
        return outcome.responseText ?? (throw StateError('No assistant response in session'));
      },
      discardSession: (sessionId) async {
        final session = await _storage.sessions.getByKey(sessionId);
        if (session == null) {
          await _storage.sessions.removeKeyMapping(sessionId);
          return;
        }
        try {
          await serverRefGetter().turns.resetProviderSessionContinuity(session.id);
        } finally {
          try {
            if (session.type == SessionType.logicalAgent) {
              await _storage.sessions.updateSessionType(session.id, SessionType.archive);
            }
          } finally {
            await _storage.sessions.removeKeyMapping(sessionId);
          }
        }
      },
      agents: _agentMap,
      contentGuard: _security.contentGuard,
      auditLogger: _security.auditLogger,
    );

    // Build global turn rate limiter (shared across all runners).
    final globalRateLimiter = config.governance.rateLimits.global.enabled
        ? SlidingWindowRateLimiter(
            limit: config.governance.rateLimits.global.turns,
            window: Duration(minutes: config.governance.rateLimits.global.windowMinutes),
          )
        : null;

    // Build budget enforcer (shared across all runners — deployment-wide daily budget).
    _budgetEnforcer = config.governance.budget.enabled
        ? BudgetEnforcer(usageTracker: _usageTracker, config: config.governance.budget)
        : null;
    final budgetEnforcer = _budgetEnforcer;

    // Build loop detector (shared across all runners — same detection state).
    final loopDetector = config.governance.loopDetection.enabled
        ? LoopDetector(config: config.governance.loopDetection)
        : null;
    final loopAction = config.governance.loopDetection.enabled ? config.governance.loopDetection.action : null;
    final globalTimeout = Duration(seconds: config.server.workerTimeout);

    TurnRunner buildRunner({
      required AgentHarness harness,
      required GuardChain guardChain,
      required TaskToolFilterGuard toolFilter,
      required String providerId,
      String profileId = 'workspace',
    }) => TurnRunner(
      harness: harness,
      messages: _storage.messages,
      behavior: _behavior,
      memoryFile: _storage.memoryFile,
      sessions: _storage.sessions,
      turnState: _storage.turnStateStore,
      kv: _storage.kvService,
      guardChain: guardChain,
      taskToolFilterGuard: toolFilter,
      lockManager: _lockManager,
      resetService: _resetService,
      contextMonitor: _contextMonitor,
      explorationSummarizer: _explorationSummarizer,
      redactor: _messageRedactor,
      selfImprovement: _selfImprovement,
      usageTracker: _usageTracker,
      sseBroadcast: _sseBroadcast,
      globalRateLimiter: globalRateLimiter,
      budgetEnforcer: budgetEnforcer,
      loopDetector: loopDetector,
      loopAction: loopAction,
      eventBus: _eventBus,
      turnMonitor: config.harness.turnMonitor,
      globalTimeout: globalTimeout,
      profileId: profileId,
      providerId: providerId,
    );

    // Build the primary lane and on-demand worker authority.
    final primaryRunner = buildRunner(
      harness: _harness,
      guardChain: _primaryGuardChain,
      toolFilter: primaryFilter,
      providerId: defaultProviderId,
    );
    _executions = ExecutionCoordinator(
      primary: primaryRunner,
      providerCapacities: providerCapacities,
      admitExecution: (request) => primaryRunner.admitTurn(request.sessionId, isHumanInput: request.isHumanInput),
      releaseAdmission: primaryRunner.releaseAdmission,
      resolveFingerprint: (providerId, profileId) {
        final allowedProfiles = providerProfiles[providerId];
        if (allowedProfiles == null || !allowedProfiles.contains(profileId)) {
          throw StateError('Provider "$providerId" cannot execute in security profile "$profileId"');
        }
        return ExecutionFingerprint(providerId: providerId, profileId: profileId, configurationId: 'serve-composition');
      },
      createWorker: (request) async {
        final entry = providerEntries[request.providerId];
        final allowedProfiles = providerProfiles[request.providerId];
        if (entry == null || allowedProfiles == null || !allowedProfiles.contains(request.profileId)) {
          throw WorkerCreationException(
            'Provider "${request.providerId}" cannot execute in security profile "${request.profileId}"',
          );
        }
        final containerManager = _security.containerManagers[request.profileId];
        final requiresContainer = config.harness.acp[request.providerId]?.containerIsolationRequired ?? false;
        if (requiresContainer && containerManager == null) {
          throw WorkerCreationException(
            'ACP provider "${request.providerId}" requires unavailable container profile "${request.profileId}"',
          );
        }
        final workerFilter = TaskToolFilterGuard();
        final workerGuardChain = _buildRunnerGuardChain(
          _security.guardChain,
          workerFilter,
          _security.toolPolicyCascade,
        );
        final workerPrompt = await _behavior.composeStaticPrompt(scope: PromptScope.task);
        final workerHarnessConfig = _harnessConfig.copyWith(appendSystemPrompt: workerPrompt);
        final workerHarness = _harnessFactory.create(
          request.providerId,
          HarnessFactoryConfig(
            cwd: Directory.current.path,
            executable: entry.executable,
            turnTimeout: Duration(seconds: config.server.workerTimeout),
            onMemorySave: _memoryHandlers.onSave,
            onMemorySearch: _memoryHandlers.onSearch,
            onMemoryRead: _memoryHandlers.onRead,
            onPermissionDenied: (toolName, reason) {
              _eventBus.fire(ToolPermissionDeniedEvent(toolName: toolName, reason: reason, timestamp: DateTime.now()));
            },
            harnessConfig: workerHarnessConfig,
            historyConfig: config.agent.history,
            providerOptions: entry.options,
            containerManager: containerManager,
            guardChain: workerGuardChain,
            ownMcpToolCanonicals: _ownMcpToolCanonicals,
            acpPermissionDecision: (permissionRequest) => _acpPermissionDecision(workerGuardChain, permissionRequest),
            acpReverseCallAudit: _auditAcpReverseCall,
            environment: _providerEnvironment(
              config,
              request.providerId,
              _credentialProviderIdForProvider(config, request.providerId),
              credentialRegistry,
            ),
          ),
        );
        _wireCompactionCallbacks(workerHarness);
        try {
          await workerHarness.start();
          return buildRunner(
            harness: workerHarness,
            guardChain: workerGuardChain,
            toolFilter: workerFilter,
            profileId: request.profileId,
            providerId: request.providerId,
          );
        } catch (error) {
          try {
            await workerHarness.stop();
          } catch (cleanupError) {
            _log.warning('Failed to stop worker after startup failure: $cleanupError');
          }
          try {
            await workerHarness.dispose();
          } catch (cleanupError) {
            _log.warning('Failed to dispose worker after startup failure: $cleanupError');
          }
          throw WorkerCreationException(
            'Failed to start ${request.providerId} worker: $error',
            quarantineSlot: !workerHarness.isRootProcessTerminationConfirmed,
          );
        }
      },
    );
  }

  static bool _isLoopbackHost(String host) => host == 'localhost' || host == '127.0.0.1' || host == '::1';

  void _warnToolPolicyEnforcementBoundaries(String defaultProviderId) {
    final hasToolPolicy =
        config.agent.disallowedTools.isNotEmpty ||
        _agentDefs.any((agent) => agent.allowedTools.isNotEmpty || agent.deniedTools.isNotEmpty) ||
        config.memory.journalEnabled ||
        config.knowledge.inbox.enabled;
    if (!hasToolPolicy) return;

    if (_security.guardChain == null) {
      _log.warning('Security guards are disabled – only configured tool policy and per-turn filters remain');
    }

    final providers = {...config.providers.entries.keys, defaultProviderId};
    for (final providerId in providers.where(
      (id) =>
          ProviderIdentity.resolveFamily(
            id,
            executable: _resolveProviderExecutable(config, id),
            options: _providerOptions(config, id),
          ) ==
          ProviderIdentity.codex,
    )) {
      final approvalValue = _providerOptions(config, providerId)['approval'];
      final approval = approvalValue is String && approvalValue.trim().isNotEmpty ? approvalValue.trim() : null;
      if (approval != 'on-request') {
        _log.warning(
          'Tool-restricted agent or job turns are configured while a Codex harness uses approval: '
          '${approval ?? 'not explicitly set'} – '
          'host tool-policy enforcement is partial or inactive for that harness; use approval: on-request for the '
          'broadest available interception',
        );
      }
    }
    if (config.harness.acp.agents.isNotEmpty) {
      _log.warning(
        'Tool-restricted agent or job turns are configured for an ACP harness – host tool-policy enforcement covers only '
        'guard-evaluated reverse calls and permission requests',
      );
    }
  }

  Future<AcpPermissionResult> _acpPermissionDecision(GuardChain runnerGuardChain, AcpPermissionRequest request) async {
    try {
      final verdict = await runnerGuardChain.evaluateBeforeToolCall(
        request.operation,
        request.params,
        sessionId: request.sessionId,
        agentId: request.agentId,
        rawProviderToolName: 'session/request_permission',
      );
      return AcpPermissionResult(granted: !verdict.isBlock, reason: verdict.message);
    } catch (error) {
      return AcpPermissionResult(granted: false, reason: 'Permission evaluation failed: $error');
    }
  }

  void _auditAcpReverseCall(AcpReverseCallAuditEvent event) {
    _log.fine(
      'ACP reverse-call raw=${event.rawProviderToolName}'
      '${event.canonicalToolName == null ? '' : ' canonical=${event.canonicalToolName}'}',
    );
  }

  /// Wires compaction EventBus callbacks onto a [ClaudeCodeHarness] instance.
  ///
  /// No-op for other harness types — only [ClaudeCodeHarness] exposes the
  /// compaction callback fields.
  void _wireCompactionCallbacks(AgentHarness harness) {
    if (harness is! ClaudeCodeHarness) return;
    harness.onCompactionStarting = (sessionId, trigger) {
      _eventBus.fire(CompactionStartingEvent(sessionId: sessionId, trigger: trigger, timestamp: DateTime.now()));
    };
    harness.onCompactionCompleted = (trigger, preTokens) {
      final sessionId = harness.sessionId ?? '';
      _eventBus.fire(
        CompactionCompletedEvent(
          sessionId: sessionId,
          trigger: trigger,
          preTokens: preTokens,
          timestamp: DateTime.now(),
        ),
      );
    };
  }
}

/// Creates a per-runner [GuardChain] layering the runner's [filter] after all
/// guards of [base].
///
/// Each runner (primary and worker) requires its own chain so that mutating
/// [filter] policies for one runner does not affect others. The base guard
/// list is tracked live: a guards.* hot-reload ([GuardChain.replaceGuards] on
/// [base]) reaches every runner chain while the filter survives the rebuild.
/// When [base] is null, configured tool policy remains active independently of
/// the optional security-guard bundle.
GuardChain _buildRunnerGuardChain(GuardChain? base, TaskToolFilterGuard filter, ToolPolicyCascade cascade) =>
    GuardChain.layered(
      base: base,
      guards: [
        if (base == null) ToolPolicyGuard(cascade: cascade),
        filter,
      ],
    );

Map<String, String> _providerEnvironment(
  DartclawConfig config,
  String providerId,
  String credentialProviderId,
  CredentialRegistry registry,
) {
  final providerFamily = ProviderIdentity.resolveFamily(
    providerId,
    executable: _resolveProviderExecutable(config, providerId),
    options: _providerOptions(config, providerId),
  );
  final environment = SafeProcess.sanitize(
    baseEnvironment: Platform.environment,
    extraEnvironment: providerFamily == ProviderIdentity.claude ? claudeHardeningEnvVars : const {},
  );
  final apiKey = registry.getApiKey(credentialProviderId);
  if (apiKey != null) {
    for (final envVar in CredentialRegistry.envVarsFor(credentialProviderId)) {
      environment[envVar] = apiKey;
    }
  }
  return environment;
}

String _credentialProviderIdForProvider(DartclawConfig config, String providerId) {
  final acpEntry = config.harness.acp[providerId];
  final modelProvider = acpEntry?.modelProvider?.trim().toLowerCase();
  return switch (modelProvider) {
    'anthropic' => 'claude',
    'openai' => 'codex',
    String value when value.isNotEmpty => value,
    _ => providerId,
  };
}

String _resolveProviderExecutable(DartclawConfig config, String providerId) {
  final entry = config.providers[providerId];
  if (entry != null) {
    return entry.executable;
  }
  final acpEntry = config.harness.acp[providerId];
  if (acpEntry != null) {
    return acpEntry.binary;
  }
  return switch (ProviderIdentity.family(providerId)) {
    'claude' => config.server.claudeExecutable,
    'codex' => 'codex',
    _ => providerId,
  };
}

Map<String, dynamic> _providerOptions(DartclawConfig config, String providerId) =>
    config.providers[providerId]?.options ?? const <String, dynamic>{};

Map<String, ProviderEntry> _effectiveWorkerProviderEntries(
  DartclawConfig config,
  Map<String, AcpTargetValidationResult> acpValidationResults,
) {
  final entries = <String, ProviderEntry>{};
  for (final entry in config.providers.entries.entries) {
    final providerId = ProviderIdentity.normalize(entry.key);
    if (entries.containsKey(providerId)) {
      throw StateError('Configured provider IDs collide after normalization to "$providerId"');
    }
    entries[providerId] = ProviderEntry(
      executable: entry.value.executable,
      poolSize: entry.value.poolSize,
      options: _withoutAcpValidationOptions(entry.value.options),
    );
  }
  for (final acpEntry in _canonicalAcpAgentEntries(config.harness.acp).entries) {
    final providerId = acpEntry.key;
    final providerOverride = entries[providerId];
    final validation = acpValidationResults[providerId];
    final validationJson = validation?.toJson();
    entries[providerId] = ProviderEntry(
      executable: acpEntry.value.binary,
      poolSize: validation?.status == AcpTargetValidationStatus.passed ? providerOverride?.poolSize ?? 0 : 0,
      options: {
        ...?providerOverride?.options,
        'credentials_required': false,
        ...validationJson == null ? const <String, dynamic>{} : {'acp_validation_result': validationJson},
        if (validationJson != null) 'acp_validation_owned': true,
      },
    );
  }
  entries.putIfAbsent(
    ProviderIdentity.normalize(config.agent.provider),
    () => ProviderEntry(
      executable: _resolveProviderExecutable(config, ProviderIdentity.normalize(config.agent.provider)),
    ),
  );
  return entries;
}

Map<String, dynamic> _withoutAcpValidationOptions(Map<String, dynamic> options) {
  final sanitized = Map<String, dynamic>.from(options);
  sanitized.remove('acp_validation_result');
  sanitized.remove('security_classification');
  sanitized.remove('validation_evidence');
  return sanitized;
}

Future<Map<String, AcpTargetValidationResult>> _validateConfiguredAcpTargets(DartclawConfig config) async {
  final agents = _canonicalAcpAgentEntries(config.harness.acp);
  if (agents.isEmpty) {
    return const {};
  }
  const validator = AcpTargetValidator();
  final results = await validator.validateConfiguredTargets(
    agents: agents,
    commandProbe: Process.run,
    advertisedCapabilities: {
      for (final providerId in agents.keys) providerId: const {'fs', 'terminal'},
    },
    requiredTargets: agents.entries
        .where((entry) => entry.key == config.agent.provider || entry.value.requiresGuardMediation)
        .map((entry) => entry.key)
        .toSet(),
  );
  final failures = results.entries.where(
    (entry) =>
        entry.value.status == AcpTargetValidationStatus.failed && agents[entry.key]?.requiresGuardMediation == true,
  );
  if (failures.isNotEmpty) {
    throw StateError(
      failures
          .map((entry) => 'Invalid harness.acp.agents.${entry.key}: ${entry.value.message ?? entry.value.errorCode}')
          .join('\n'),
    );
  }
  return results;
}

Map<String, AcpAgentConfig> _canonicalAcpAgentEntries(AcpConfig config) {
  final agents = <String, AcpAgentConfig>{};
  for (final entry in config.agents.entries) {
    final providerId = ProviderIdentity.normalize(entry.key);
    if (agents.containsKey(providerId)) {
      throw StateError('Configured ACP provider IDs collide after normalization to "$providerId"');
    }
    agents[providerId] = entry.value;
  }
  return agents;
}

Map<String, ProviderEntry> _effectiveValidationProviderEntries(
  DartclawConfig config,
  Map<String, AcpTargetValidationResult> acpValidationResults,
) {
  if (config.providers.isEmpty && config.harness.acp.isEmpty) {
    return {
      config.agent.provider: ProviderEntry(executable: _resolveProviderExecutable(config, config.agent.provider)),
    };
  }
  return _effectiveWorkerProviderEntries(config, acpValidationResults);
}

List<String> _profilesForProvider(DartclawConfig config, String providerId, List<String> fallbackProfiles) {
  final acpEntry = config.harness.acp[providerId];
  final profile = acpEntry?.containerProfile;
  if (acpEntry != null && acpEntry.containerIsolationRequired && profile != null) {
    return [_containerProfileId(profile)];
  }
  return fallbackProfiles;
}

ContainerExecutor? _containerManagerForProvider(DartclawConfig config, SecurityWiring security, String providerId) {
  final acpEntry = config.harness.acp[providerId];
  if (acpEntry == null) {
    return security.containerManagers['workspace'];
  }
  if (!acpEntry.containerIsolationRequired) {
    return null;
  }
  final profile = acpEntry.containerProfile;
  if (profile == null) {
    throw StateError('ACP provider "$providerId" requires container isolation without a container_profile');
  }
  final profileId = _containerProfileId(profile);
  final manager = security.containerManagers[profileId];
  if (manager == null) {
    throw StateError('ACP provider "$providerId" requires unavailable container profile "$profileId"');
  }
  return manager;
}

String _containerProfileId(AcpContainerProfile profile) {
  return switch (profile) {
    AcpContainerProfile.restricted => 'restricted',
    AcpContainerProfile.workspace => 'workspace',
  };
}

String _logicalAgentWorkerProfile(
  DartclawConfig config,
  SecurityWiring security,
  AgentDefinition definition,
  String providerId,
) {
  final configured = definition.securityProfile;
  if (configured != null) {
    if (configured != 'workspace' && !security.containerManagers.containsKey(configured)) {
      throw StateError('Logical agent "${definition.id}" requires unavailable security profile "$configured"');
    }
    return configured;
  }

  if (security.containerManagers.isEmpty) return 'workspace';

  final providerProfile = config.harness.acp[providerId]?.containerProfile;
  return providerProfile == null ? 'workspace' : _containerProfileId(providerProfile);
}
