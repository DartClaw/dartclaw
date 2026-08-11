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
  late ExecutionPolicyResolver _policyResolver;
  late ExecutionPolicy _primaryPolicy;
  final Map<TurnRunner, ContainerAuthorityLease> _workerContainers =
      Map<TurnRunner, ContainerAuthorityLease>.identity();
  ContainerAuthorityLease? _primaryContainer;
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
  ExecutionPolicyResolver get policyResolver => _policyResolver;
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

    if (config.agent.provider.trim().isEmpty) {
      throw StateError('agent.provider must not be blank');
    }
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
      if (isLoopbackHost(host)) {
        _log.warning('Auth disabled on loopback — acceptable for local dev only');
      } else {
        _log.severe('CRITICAL: Auth disabled on network-accessible host $host');
      }
    }

    final mcpEnabled = _resolvedGatewayToken != null || (!_authEnabled && isLoopbackHost(config.server.host));
    _agentDefs = config.agent.definitions.isNotEmpty ? config.agent.definitions : [AgentDefinition.searchAgent()];
    for (final definition in _agentDefs) {
      if (definition.provider != null && definition.provider!.trim().isEmpty) {
        throw StateError('agents.${definition.id}.provider must not be blank');
      }
    }
    _agentMap = {for (final a in _agentDefs) a.id: a};
    // Bridged MCP authorization resolves registered tool names through the
    // same canonical taxonomy the guard cascade uses.
    _security.mcpToolCanonicals = _ownMcpToolCanonicals;
    _policyResolver = ExecutionPolicyResolver(
      config: config,
      availableContainerProfiles: _security.availableContainerProfiles,
    );
    for (final warning in _policyResolver.hostOverrideWarnings()) {
      _log.warning(warning);
    }
    for (final warning in _policyResolver.failClosedWarnings(agents: _agentDefs)) {
      _log.warning(warning);
    }
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
    final acpAgents = ProviderIdentity.normalizeKeys(config.harness.acp.agents, subject: 'Configured ACP provider IDs');
    final acpValidationResults = await _validateConfiguredAcpTargets(config, acpAgents);
    for (final entry in acpAgents.entries) {
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
      final available = _security.availableContainerProfiles;
      final profileIds = available.isEmpty ? ['workspace'] : available.toList(growable: false);
      providerEntries = _effectiveWorkerProviderEntries(config, acpAgents, acpValidationResults);
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
        entries: _effectiveValidationProviderEntries(config, providerEntries),
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

      _primaryPolicy = _policyResolver.resolveForPrimary(providerId: defaultProviderId);
      _harness = _harnessFactory.create(
        defaultProviderId,
        _buildFactoryConfig(
          executable: _resolveProviderExecutable(config, defaultProviderId),
          harnessConfig: _harnessConfig,
          providerOptions: _providerOptions(config, defaultProviderId),
          containerManager: await _primaryContainerManager(defaultProviderId),
          guardChain: _primaryGuardChain,
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
      await _releaseContainerQuietly(_primaryContainer);
      _primaryContainer = null;
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
          final policy = _policyResolver.resolveForAgent(definition, providerId: agentProviderId);
          session = await _storage.sessions.getOrCreateByKey(
            sessionId,
            type: SessionType.logicalAgent,
            provider: agentProviderId,
            securityProfile: policy.containerProfile,
            executionMode: policy.mode,
          );
        } else {
          session = await _storage.sessions.getByKey(sessionId);
          if (session == null || session.type != SessionType.logicalAgent) {
            throw StateError('Unknown logical-agent session: $sessionId');
          }
        }
        if (session.provider == null) {
          throw StateError('Logical-agent session is missing its pinned provider: $sessionId');
        }
        // A session pinned before execution mode existed carries only a
        // profile; the resolver derives its mode and TurnManager persists the
        // derived value forward. A missing mode is never itself a rejection.
        final sessionPolicy = _policyResolver.resolveForPinnedSession(
          sessionId: session.id,
          executionMode: session.executionMode,
          securityProfile: session.securityProfile,
        );

        final srv = serverRefGetter();
        final turnId = await srv.turns.reserveTurn(
          session.id,
          agentName: agentId,
          model: trimmedModel == null || trimmedModel.isEmpty ? null : trimmedModel,
          effort: trimmedEffort == null || trimmedEffort.isEmpty ? null : trimmedEffort,
          systemPromptOverride: persona,
          workerPolicy: sessionPolicy,
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
      required ExecutionPolicy executionPolicy,
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
      executionPolicy: executionPolicy,
      providerId: providerId,
    );

    // Append-mode providers receive behavior content when their process starts.
    // Snapshot the task prompt once so all workers in this coordinator share the
    // same construction inputs and are safe to reuse.
    final workerPrompt = await _behavior.composeStaticPrompt(scope: PromptScope.task);

    // Build the primary lane and on-demand worker authority.
    final primaryRunner = buildRunner(
      harness: _harness,
      guardChain: _primaryGuardChain,
      toolFilter: primaryFilter,
      providerId: defaultProviderId,
      executionPolicy: _primaryPolicy,
    );
    _executions = ExecutionCoordinator(
      primary: primaryRunner,
      providerCapacities: providerCapacities,
      admitExecution: (request) => primaryRunner.admitTurn(request.sessionId, isHumanInput: request.isHumanInput),
      releaseAdmission: primaryRunner.releaseAdmission,
      createWorker: (request) async {
        final entry = providerEntries[request.providerId];
        final allowedProfiles = providerProfiles[request.providerId];
        final containerProfile = request.policy.containerProfile;
        if (entry == null ||
            allowedProfiles == null ||
            (containerProfile != null && !allowedProfiles.contains(containerProfile))) {
          throw WorkerCreationException(
            'Provider "${request.providerId}" cannot execute as ${request.policy.describe()}',
          );
        }
        final requiresContainer = config.harness.acp[request.providerId]?.containerIsolationRequired ?? false;
        if (requiresContainer && !request.policy.isContainer) {
          throw WorkerCreationException(
            'ACP provider "${request.providerId}" requires container isolation, but its resolved policy is host '
            'execution. Select execution: container for it, or remove its container_isolation requirement.',
          );
        }
        ContainerAuthorityLease? lease;
        if (containerProfile != null) {
          try {
            lease = await _security.acquireContainerAuthority(
              GatewayPrincipal(
                sessionId: request.sessionId,
                providerId: request.providerId,
                policy: request.policy,
                logicalAgentId: request.logicalAgentId,
                taskId: request.taskId,
              ),
              allowedMcpTools: _bridgedMcpToolsFor(request.logicalAgentId),
            );
          } catch (error) {
            throw WorkerCreationException(
              'Provider "${request.providerId}" requires unavailable container profile "$containerProfile": $error',
            );
          }
        }
        final containerManager = lease?.container;
        final workerFilter = TaskToolFilterGuard();
        final workerGuardChain = _buildRunnerGuardChain(
          _security.guardChain,
          workerFilter,
          _security.toolPolicyCascade,
        );
        final workerHarnessConfig = _harnessConfig.copyWith(appendSystemPrompt: workerPrompt);
        try {
          final workerHarness = _harnessFactory.create(
            request.providerId,
            _buildFactoryConfig(
              executable: entry.executable,
              harnessConfig: workerHarnessConfig,
              providerOptions: entry.options,
              containerManager: containerManager,
              guardChain: workerGuardChain,
              environment: _providerEnvironment(
                config,
                request.providerId,
                _credentialProviderIdForProvider(config, request.providerId),
                credentialRegistry,
              ),
            ),
          );
          _wireCompactionCallbacks(workerHarness);
          final runner = buildRunner(
            harness: workerHarness,
            guardChain: workerGuardChain,
            toolFilter: workerFilter,
            executionPolicy: request.policy,
            providerId: request.providerId,
          );
          if (lease != null) _workerContainers[runner] = lease;
          return runner;
        } catch (_) {
          await _releaseContainerQuietly(lease);
          rethrow;
        }
      },
      destroyContainerAuthority: (context) async {
        await _workerContainers.remove(context.runner)?.release();
      },
    );
  }

  /// Creates the container backing the primary harness, or returns `null` when
  /// the primary agent's resolved policy places it on the host.
  ///
  /// The primary harness is a live container authority like any other, so it
  /// owns a dedicated container rather than sharing a per-profile one. A
  /// provider that declares a stronger minimum boundary rejects a host policy
  /// rather than silently upgrading it.
  Future<ContainerExecutor?> _primaryContainerManager(String providerId) async {
    final requiresContainer = config.harness.acp[providerId]?.containerIsolationRequired ?? false;
    if (requiresContainer && !_primaryPolicy.isContainer) {
      throw StateError(
        'ACP provider "$providerId" requires container isolation, but agent.execution resolves to host execution',
      );
    }
    if (!_primaryPolicy.isContainer) return null;
    _primaryContainer = await _security.acquireContainerAuthority(
      GatewayPrincipal(sessionId: _primaryAuthoritySessionId, providerId: providerId, policy: _primaryPolicy),
    );
    return _primaryContainer!.container;
  }

  /// The primary lane has no session of its own; its authority is still one
  /// principal, named so audit entries can be told apart from worker turns.
  static const _primaryAuthoritySessionId = 'primary';

  /// Canonical MCP tool names an agent's containerized execution may reach.
  ///
  /// Deny-by-default: only an explicit agent allowlist exposes anything, and
  /// only entries that name a canonical tool participate — a provider-native
  /// tool name in `allowed_tools` says nothing about host MCP.
  Set<String> _bridgedMcpToolsFor(String? agentId) {
    final definition = agentId == null ? null : _agentMap[agentId];
    if (definition == null || definition.allowedTools.isEmpty) return const {};
    // `mcp_call` names every tool without a semantic canonical, so it can
    // never act as a bridged grant.
    final canonicalNames = {
      for (final tool in CanonicalTool.values)
        if (tool != CanonicalTool.mcpCall) tool.stableName,
    };
    final denied = {...definition.deniedTools, ...config.agent.disallowedTools};
    return definition.allowedTools.where(canonicalNames.contains).toSet().difference(denied);
  }

  /// Destroys the primary harness's dedicated container, if it has one.
  ///
  /// The primary authority lives for the process, so its container is released
  /// at shutdown rather than per lease.
  Future<void> disposePrimaryContainer() async {
    final lease = _primaryContainer;
    if (lease == null) return;
    _primaryContainer = null;
    await _releaseContainerQuietly(lease);
  }

  Future<void> _releaseContainerQuietly(ContainerAuthorityLease? lease) async {
    if (lease == null) return;
    try {
      await lease.release();
    } catch (error, stackTrace) {
      _log.warning('Failed to release container authority', error, stackTrace);
    }
  }

  HarnessFactoryConfig _buildFactoryConfig({
    required String executable,
    required HarnessConfig harnessConfig,
    required Map<String, dynamic> providerOptions,
    required ContainerExecutor? containerManager,
    required GuardChain guardChain,
    required Map<String, String> environment,
  }) => HarnessFactoryConfig(
    cwd: Directory.current.path,
    executable: executable,
    turnTimeout: Duration(seconds: config.server.workerTimeout),
    onMemorySave: _memoryHandlers.onSave,
    onMemorySearch: _memoryHandlers.onSearch,
    onMemoryRead: _memoryHandlers.onRead,
    onPermissionDenied: (toolName, reason) {
      _eventBus.fire(ToolPermissionDeniedEvent(toolName: toolName, reason: reason, timestamp: DateTime.now()));
    },
    harnessConfig: harnessConfig,
    historyConfig: config.agent.history,
    providerOptions: providerOptions,
    containerManager: containerManager,
    guardChain: guardChain,
    ownMcpToolCanonicals: _ownMcpToolCanonicals,
    acpPermissionDecision: (request) => _acpPermissionDecision(guardChain, request),
    acpReverseCallAudit: _auditAcpReverseCall,
    environment: environment,
  );

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
  Map<String, AcpAgentConfig> acpAgents,
  Map<String, AcpTargetValidationResult> acpValidationResults,
) {
  final entries = <String, ProviderEntry>{
    for (final entry in ProviderIdentity.normalizeKeys(config.providers.entries).entries)
      entry.key: ProviderEntry(
        executable: entry.value.executable,
        poolSize: entry.value.poolSize,
        options: _withoutAcpValidationOptions(entry.value.options),
      ),
  };
  for (final acpEntry in acpAgents.entries) {
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

Future<Map<String, AcpTargetValidationResult>> _validateConfiguredAcpTargets(
  DartclawConfig config,
  Map<String, AcpAgentConfig> agents,
) async {
  if (agents.isEmpty) {
    return const {};
  }
  const validator = AcpTargetValidator();
  final defaultProviderId = ProviderIdentity.normalize(config.agent.provider);
  final results = await validator.validateConfiguredTargets(
    agents: agents,
    commandProbe: Process.run,
    advertisedCapabilities: {
      for (final providerId in agents.keys) providerId: const {'fs', 'terminal'},
    },
    requiredTargets: agents.entries
        .where((entry) => entry.key == defaultProviderId || entry.value.requiresGuardMediation)
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

Map<String, ProviderEntry> _effectiveValidationProviderEntries(
  DartclawConfig config,
  Map<String, ProviderEntry> workerEntries,
) {
  if (config.providers.isEmpty && config.harness.acp.isEmpty) {
    final defaultProviderId = ProviderIdentity.normalize(config.agent.provider);
    return {defaultProviderId: ProviderEntry(executable: _resolveProviderExecutable(config, defaultProviderId))};
  }
  return workerEntries;
}

List<String> _profilesForProvider(DartclawConfig config, String providerId, List<String> fallbackProfiles) {
  final acpEntry = config.harness.acp[providerId];
  final profile = acpEntry?.containerProfile;
  if (acpEntry != null && acpEntry.containerIsolationRequired && profile != null) {
    return [_containerProfileId(profile)];
  }
  return fallbackProfiles;
}

String _containerProfileId(AcpContainerProfile profile) {
  return switch (profile) {
    AcpContainerProfile.restricted => 'restricted',
    AcpContainerProfile.workspace => 'workspace',
  };
}
