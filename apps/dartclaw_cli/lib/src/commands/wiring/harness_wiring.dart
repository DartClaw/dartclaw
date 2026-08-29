import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart' hide HarnessConfig;
import 'package:dartclaw_storage/dartclaw_storage.dart' show WikiSearchSource;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../codex_subscription_home.dart';
import '../provider_credential_environment.dart';
import '../serve_command.dart' show ExitFn, mcpDisallowedTools;
import 'storage_wiring.dart';
import 'security_wiring.dart';

/// Constructs and exposes harness-layer services.
///
/// Owns agent definitions, primary + worker harnesses, execution capacity, token service,
/// usage tracker, health service, context management, logical-agent sessions, behavior
/// service, self-improvement, SSE broadcast, and auth state.
class HarnessWiring {
  static const _preCompactObservationMaxBytes = 32 * 1024;
  static const _preCompactMessageCount = 12;

  new({
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
    Map<String, CredentialEntry> Function()? subscriptionCredentials,
    CodexRefreshAuthority? codexRefresh,
    Map<String, String>? environment,
  }) : _codexRefresh = codexRefresh,
       _subscriptionCredentials = subscriptionCredentials ?? _noSubscriptionCredentials,
       _dataDir = dataDir,
       _port = port,
       _harnessFactory = harnessFactory,
       _exitFn = exitFn,
       _storage = storage,
       _security = security,
       _messageRedactor = messageRedactor,
       _eventBus = eventBus,
       _configNotifier = configNotifier,
       _environment = environment ?? Platform.environment;

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

  /// Process environment credential resolution and provider spawns read.
  final Map<String, String> _environment;

  /// Snapshot of the dedicated subscription stores, read when a spawn
  /// environment is built rather than cached at wiring time.
  final Map<String, CredentialEntry> Function() _subscriptionCredentials;

  /// The only thing that rotates the dedicated Codex store, shared with the
  /// gateway so DartClaw's own refreshes stay single-flight across host spawns
  /// and mediated container requests alike.
  final CodexRefreshAuthority? _codexRefresh;

  static Map<String, CredentialEntry> _noSubscriptionCredentials() => const {};

  /// A registry over the current credential state, rebuilt per use because
  /// workers spawn long after wiring and the stored token can be re-issued.
  CredentialRegistry _credentialRegistry() => CredentialRegistry(
    credentials: config.credentials,
    env: _environment,
    providers: config.providers,
    subscriptions: _subscriptionCredentials(),
  );

  static final _log = Logger('HarnessWiring');

  late AgentHarness _harness;
  late GuardChain _primaryGuardChain;
  late ExecutionCoordinator _executions;
  late ExecutionPolicyResolver _policyResolver;
  late ProviderExecutionInventory _executionInventory;
  late ExecutionPolicy _primaryPolicy;
  final Map<TurnRunner, ContainerAuthorityLease> _workerContainers =
      Map<TurnRunner, ContainerAuthorityLease>.identity();
  ContainerAuthorityLease? _primaryContainer;
  CredentialHealthMonitor? _credentialHealth;

  /// Binds the single credential-health writer, built several wiring steps
  /// after this class and therefore not a constructor argument.
  set credentialHealth(CredentialHealthMonitor value) => _credentialHealth = value;

  /// Announces a host-boundary credential condition through that writer.
  ///
  /// The container boundary reports every refusal through the gateway's sink;
  /// this is the same announcement for the host boundary, which reaches no
  /// gateway at all. Until the monitor is bound — the primary lane's own spawn
  /// precedes it — the severe line is the degradation FR6 requires.
  void _reportHostCredentialHealth({
    required String providerId,
    required CredentialHealthState state,
    required String detail,
    String? remediation,
  }) {
    final monitor = _credentialHealth;
    if (monitor == null) {
      _log.severe('Provider "$providerId" credential unusable: $detail${remediation == null ? '' : ' $remediation'}');
      return;
    }
    monitor.report(providerId: providerId, state: state, detail: detail, remediation: remediation);
  }

  /// The primary authority's container name, captured on acquisition so a crash
  /// event can be attributed to the primary lane specifically.
  String? _primaryContainerName;
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
  late MemoryHandlers _memoryHandlers;
  BudgetEnforcer? _budgetEnforcer;
  Map<String, ProviderEntry> _providerStatusEntries = const {};
  bool _authEnabled = false;
  TokenService? _tokenService;
  String? _resolvedGatewayToken;

  AgentHarness get harness => _harness;
  ExecutionCoordinator get executions => _executions;
  ExecutionPolicyResolver get policyResolver => _policyResolver;
  ProviderExecutionInventory get executionInventory => _executionInventory;
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
  MemoryHandlers get memoryHandlers => _memoryHandlers;
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
      memoryCorpus: _storage.memoryCorpus,
      onboardingExpiryDays: config.onboarding.expiryDays,
      compactInstructions: config.context.compactInstructions,
      identifierPreservation: config.context.identifierPreservation,
      identifierInstructions: config.context.identifierInstructions,
    );
    final staticPrompt = await _behavior.composeStaticPrompt(scope: PromptScope.primary);

    _selfImprovement = SelfImprovementService(workspaceDir: config.workspaceDir, corpusService: _storage.memoryCorpus);

    _memoryHandlers = createMemoryHandlers(
      memory: _storage.memory,
      memoryFile: _storage.memoryFile,
      corpusService: _storage.memoryCorpus,
      searchBackend: _storage.searchBackend,
      nativeSourceResolver: LiveMemorySourceResolver(
        wiki: WikiSearchSource(workspaceDir: config.workspaceDir),
        kg: _storage.kg,
        inbox: KnowledgeInboxReadService(workspaceDir: config.workspaceDir),
      ),
      selfImprovement: _selfImprovement,
    );

    final semanticMcpTools = <McpTool>[
      WebFetchTool(scan: _security.contentScan),
      MemoryApplyTool(handler: _memoryHandlers.onApply, contextualHandler: _memoryHandlers.apply),
      MemoryObserveTool(handler: _memoryHandlers.onObserve, contextualHandler: _memoryHandlers.observe),
      MemorySearchTool(handler: _memoryHandlers.onSearch),
      MemoryReadTool(handler: _memoryHandlers.onRead),
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
          'memory_apply' => CanonicalTool.memoryApply,
          'memory_observe' => CanonicalTool.memoryObserve,
          'memory_search' => CanonicalTool.memorySearch,
          'memory_read' => CanonicalTool.memoryRead,
          _ => throw StateError('Missing canonical mapping for own MCP tool: ${tool.name}'),
        },
    });

    if (config.agent.provider.trim().isEmpty) {
      throw StateError('agent.provider must not be blank');
    }
    final defaultProviderId = ProviderIdentity.normalize(config.agent.provider);
    _authEnabled = config.gateway.authMode != 'none';
    if (_authEnabled) {
      // A blank configured token authenticates an empty bearer header and signs
      // session cookies with an empty HMAC key — take the generated token file.
      final configuredToken = config.gateway.token;
      _resolvedGatewayToken = configuredToken != null && configuredToken.trim().isNotEmpty
          ? configuredToken
          : TokenService.loadFromFile(_dataDir);
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

    _warnToolPolicyEnforcementBoundaries(defaultProviderId);
    final acpAgents = ProviderIdentity.normalizeKeys(config.harness.acp.agents, subject: 'Configured ACP provider IDs');
    final acpRequirementErrors = [
      for (final entry in acpAgents.entries) ?acpContainerRequirementError(entry.key, entry.value),
    ];
    if (acpRequirementErrors.isNotEmpty) {
      throw StateError(acpRequirementErrors.join('\n'));
    }
    _executionInventory = ProviderExecutionInventory.of(
      providerIds: {defaultProviderId, ...ProviderIdentity.normalizeKeys(config.providers.entries).keys},
      acpProviderIds: acpAgents.keys.toSet(),
      credentialGate: (providerId) => _credentialRefusalFor(config, _credentialRegistry(), providerId),
    );
    // One startup emission point for every execution-boundary diagnostic:
    // deliberate weakenings, contexts that fail closed at first dispatch, and
    // combinations this deployment resolves to but cannot run. The compatibility
    // pass and the provider gate below both surface an unpresentable credential
    // in the single author's words, so the same line is logged once.
    final emittedWarnings = <String>{};
    void warn(String warning) {
      if (emittedWarnings.add(warning)) _log.warning(warning);
    }

    _policyResolver.hostOverrideWarnings().forEach(warn);
    _policyResolver.failClosedWarnings(agents: _agentDefs).forEach(warn);
    _policyResolver
        .providerCompatibilityWarnings(
          inventory: _executionInventory,
          defaultProviderId: defaultProviderId,
          agents: _agentDefs,
        )
        .forEach(warn);
    // Reports an agent allowed a host tool this deployment cannot serve at
    // startup rather than at that agent's first container turn.
    for (final definition in _agentDefs) {
      _bridgedMcpToolsFor(agentId: definition.id);
    }
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
      providerProfiles = {for (final providerId in providerEntries.keys) providerId: profileIds};
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
        registry: _credentialRegistry(),
        defaultProvider: defaultProviderId,
        credentialsDir: config.credentialsDir,
        isHostExecution: (providerId) => !_policyResolver.resolveForPrimary(providerId: providerId).isContainer,
      );
      validation.warnings.forEach(warn);
      if (validation.errors.isNotEmpty) {
        throw StateError(validation.errors.join('\n'));
      }

      _primaryPolicy = _policyResolver.resolveForPrimary(providerId: defaultProviderId);
      // The primary lane's own grant, and the disallow list resolved against
      // the MCP surface it will really have — a containerized primary that is
      // granted no bridged search keeps its native one instead of losing both.
      final primaryBridgedMcpTools = _primaryPolicy.isContainer ? _primaryBridgedMcpTools() : const <String>{};
      final primaryHarnessConfig = _harnessConfig.copyWith(
        disallowedTools: workerDisallowedTools(
          containerProfile: _primaryPolicy.containerProfile,
          hostDisallowedTools: _harnessConfig.disallowedTools,
          userDisallowedTools: config.agent.disallowedTools,
        ),
      );
      _harness = _harnessFactory.create(
        defaultProviderId,
        _buildFactoryConfig(
          executable: _resolveProviderExecutable(config, defaultProviderId),
          harnessConfig: primaryHarnessConfig,
          providerOptions: _providerOptions(config, defaultProviderId),
          containerManager: await _primaryContainerManager(defaultProviderId, allowedMcpTools: primaryBridgedMcpTools),
          guardChain: _primaryGuardChain,
          environment: _providerEnvironment(config, defaultProviderId, _credentialRegistry(), _environment),
          prepareSubscriptionHome: _subscriptionHomeFor(defaultProviderId),
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
    // The primary agent's container is a single-use authority: once it dies its
    // bridges are gone and nothing re-acquires it (auto-recovery is deliberately
    // deferred). Emit a distinct, operator-actionable signal — separate from the
    // per-task crash handling — naming the primary lane and the only recovery.
    _eventBus.on<ContainerCrashedEvent>().listen((event) {
      if (_primaryContainerName != null && event.containerName == _primaryContainerName) {
        _log.severe(
          'The primary agent\'s container (${event.containerName}) was lost; the chat cannot recover on its own. '
          'Restart the service to recover.',
        );
      }
    });
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
        final personaPrompt = definition.personaPrompt;
        final persona = personaPrompt.trim().isEmpty ? null : personaPrompt;
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
          promptScope: PromptScope.task,
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
        final verdict = _executionInventory.verdictFor(
          providerId: request.providerId,
          surface: ProviderLaunchSurface.longLived,
          policy: request.policy,
        );
        if (!verdict.isSupported) {
          if (verdict.reason == ProviderUnavailability.credential) {
            _reportHostCredentialHealth(
              providerId: request.providerId,
              state: CredentialHealthState.reauthRequired,
              detail: 'Host execution was refused at admission because the selected credential cannot be presented.',
              remediation: verdict.message,
            );
          }
          throw WorkerCreationException(verdict.message);
        }
        final bridgedMcpTools = _bridgedMcpToolsFor(
          agentId: request.logicalAgentId,
          allowedTools: request.allowedTools,
        );
        ContainerAuthorityLease? lease;
        if (containerProfile != null) {
          _warnIfUngranted(bridgedMcpTools, request: request, containerProfile: containerProfile);
          try {
            lease = await _security.acquireContainerAuthority(
              GatewayPrincipal(
                sessionId: request.sessionId,
                providerId: request.providerId,
                policy: request.policy,
                sourceSessionId: request.sessionId,
                logicalAgentId: request.logicalAgentId,
                taskId: request.taskId,
              ),
              allowedMcpTools: bridgedMcpTools,
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
        final workerHarnessConfig = _harnessConfig.copyWith(
          appendSystemPrompt: workerPrompt,
          disallowedTools: workerDisallowedTools(
            containerProfile: containerProfile,
            hostDisallowedTools: _harnessConfig.disallowedTools,
            userDisallowedTools: config.agent.disallowedTools,
          ),
        );
        try {
          final workerHarness = _harnessFactory.create(
            request.providerId,
            _buildFactoryConfig(
              executable: entry.executable,
              harnessConfig: workerHarnessConfig,
              providerOptions: entry.options,
              containerManager: containerManager,
              guardChain: workerGuardChain,
              environment: _providerEnvironment(config, request.providerId, _credentialRegistry(), _environment),
              prepareSubscriptionHome: _subscriptionHomeFor(request.providerId),
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
  /// provider whose resolved boundary this deployment cannot enforce rejects
  /// before any container exists rather than running somewhere else.
  Future<ContainerExecutor?> _primaryContainerManager(String providerId, {required Set<String> allowedMcpTools}) async {
    final verdict = _executionInventory.verdictFor(
      providerId: providerId,
      surface: ProviderLaunchSurface.longLived,
      policy: _primaryPolicy,
    );
    if (!verdict.isSupported) {
      throw StateError(verdict.message);
    }
    if (!_primaryPolicy.isContainer) return null;
    _primaryContainer = await _security.acquireContainerAuthority(
      GatewayPrincipal(sessionId: _primaryAuthoritySessionId, providerId: providerId, policy: _primaryPolicy),
      allowedMcpTools: allowedMcpTools,
    );
    final container = _primaryContainer!.container;
    if (container is ContainerManager) _primaryContainerName = container.containerName;
    return container;
  }

  /// The primary lane has no session of its own; its authority is still one
  /// principal, named so audit entries can be told apart from worker turns.
  static const _primaryAuthoritySessionId = 'primary';

  /// Canonical MCP tool names one containerized execution may reach.
  ///
  /// Deny-by-default: only an explicit allowlist exposes anything — the logical
  /// agent's `allowed_tools`, or the tool policy already in force for the task
  /// — and only entries that name a canonical tool participate, since a
  /// provider-native tool name says nothing about host MCP.
  /// The tool policy authorizing an execution, before any canonical or
  /// servability filtering — `null` when the execution carries none at all.
  Set<String>? _requestedToolPolicy({String? agentId, List<String>? allowedTools}) =>
      (agentId == null ? null : _agentMap[agentId])?.allowedTools ?? allowedTools?.toSet();

  /// The bridged-MCP grant for a workflow one-shot step, derived by the one
  /// owner of the deny set and the servable set.
  ///
  /// A workflow step carries no agent definition, so its grant comes from the
  /// step's own tool policy — the same derivation background worker tasks use
  /// (deny subtraction + servable intersection). Injected into the workflow
  /// runner so the workflow lane never re-derives a divergent, unguarded grant.
  Set<String> workflowBridgedMcpTools(List<String>? allowedTools) => _bridgedMcpToolsFor(allowedTools: allowedTools);

  Set<String> _bridgedMcpToolsFor({String? agentId, List<String>? allowedTools}) {
    final definition = agentId == null ? null : _agentMap[agentId];
    final requested = _requestedToolPolicy(agentId: agentId, allowedTools: allowedTools);
    if (requested == null || requested.isEmpty) return const {};
    // `mcp_call` names every tool without a semantic canonical, so it can
    // never act as a bridged grant.
    final canonicalNames = {
      for (final tool in CanonicalTool.values)
        if (tool != CanonicalTool.mcpCall) tool.stableName,
    };
    // Both sides carry provider-native or canonical spellings; normalize to
    // canonical stable names first so a native-spelled allow entry is not
    // silently dropped and a native-spelled deny is not silently ignored.
    final denied = {
      ...?definition?.deniedTools,
      ...config.agent.disallowedTools,
    }.map(ToolPolicyCascade.normalizeEntry).toSet();
    final granted = requested
        .map(ToolPolicyCascade.normalizeEntry)
        .where(canonicalNames.contains)
        .toSet()
        .difference(denied);
    return _servableGrant(granted, subject: agentId == null ? 'This deployment' : 'Agent "$agentId"');
  }

  /// The primary lane's bridged grant.
  ///
  /// The primary agent is the deployment itself, not a scoped logical agent:
  /// on the host it reaches the whole registered MCP surface, so containerizing
  /// it must not silently drop web and memory capability. Session-spawning
  /// tools stay out — orchestrating other executions is not a capability a
  /// container needs to keep working.
  Set<String> _primaryBridgedMcpTools() {
    final semantic = {for (final tool in _semanticMcpTools) ?_ownMcpToolCanonicals[tool.name]?.stableName};
    // Normalize provider-native deny spellings (`WebSearch`) to canonical names
    // (`web_search`) so the operator's global deny actually subtracts.
    return semantic.difference(config.agent.disallowedTools.map(ToolPolicyCascade.normalizeEntry).toSet());
  }

  /// Drops grants no registered host tool can serve, naming each one once.
  ///
  /// A canonical the deployment does not implement — `web_search` with no
  /// configured `search.providers` — would otherwise be granted, suppress the
  /// provider-native tool that could have replaced it, and fail only when the
  /// agent first calls it.
  Set<String> _servableGrant(Set<String> granted, {required String subject}) {
    final servable = {for (final canonical in _ownMcpToolCanonicals.values) canonical.stableName};
    for (final tool in granted.difference(servable)) {
      if (!_warnedUnservableGrants.add('$subject/$tool')) continue;
      _log.warning(
        '$subject is allowed host MCP tool "$tool", but this deployment registers no such tool – '
        'containerized executions will run without it. '
        'Configure the provider that serves it (for example search.providers.* for web_search).',
      );
    }
    return granted.intersection(servable);
  }

  /// Reports a containerized execution that was meant to reach host tools but
  /// reaches none.
  ///
  /// Bridged MCP is deny-by-default, so an ordinary workspace coding task with
  /// no tool policy is capability-free *by design* — warning on it would fire
  /// on every default-config containerized turn. Two cases are real capability
  /// loss instead: the `restricted` profile, whose whole point is web-shaped
  /// work with no workspace to fall back on, and an execution whose configured
  /// policy asked for host tools that all turned out unservable.
  void _warnIfUngranted(
    Set<String> bridgedMcpTools, {
    required ExecutionRequest request,
    required String containerProfile,
  }) {
    if (bridgedMcpTools.isNotEmpty) return;
    final grantConfigured =
        _requestedToolPolicy(agentId: request.logicalAgentId, allowedTools: request.allowedTools)?.isNotEmpty ?? false;
    if (containerProfile != SecurityProfile.restricted.id && !grantConfigured) return;
    final subject = request.logicalAgentId == null
        ? '${request.surface.name} executions'
        : 'Logical agent "${request.logicalAgentId}"';
    if (!_warnedUnservableGrants.add('ungranted $subject $containerProfile')) return;
    _log.warning(
      '$subject run in container profile "$containerProfile" with no host MCP tools: '
      'nothing was allowed, so they reach no search, fetch, or memory capability. '
      'Allow the canonical tools they need (an agent\'s allowed_tools, or the task\'s tool policy), '
      'or select host execution for them.',
    );
  }

  final Set<String> _warnedUnservableGrants = {};

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

  /// The dedicated-home preparation for [providerId], or `null` for a provider
  /// family with no dedicated store lane, for an API-key deployment, and for an
  /// ACP registration — a dedicated `CODEX_HOME` is how a Codex subscription is
  /// presented, and no subscription credential reaches an ACP agent.
  Future<String?> Function()? _subscriptionHomeFor(String providerId) {
    final authority = _codexRefresh;
    if (authority == null || config.harness.acp[providerId] != null) return null;
    final family = ProviderIdentity.resolveFamily(
      providerId,
      executable: _resolveProviderExecutable(config, providerId),
      options: _providerOptions(config, providerId),
    );
    if (family != ProviderIdentity.codex) return null;
    return () => prepareCodexSubscriptionHome(
      registry: _credentialRegistry(),
      authority: authority,
      providerId: providerId,
      family: family,
      credentialsDir: config.credentialsDir,
      onCredentialHealth: _reportHostCredentialHealth,
    );
  }

  HarnessFactoryConfig _buildFactoryConfig({
    required String executable,
    required HarnessConfig harnessConfig,
    required Map<String, dynamic> providerOptions,
    required ContainerExecutor? containerManager,
    required GuardChain guardChain,
    required Map<String, String> environment,
    Future<String?> Function()? prepareSubscriptionHome,
  }) => HarnessFactoryConfig(
    cwd: Directory.current.path,
    executable: executable,
    turnTimeout: Duration(seconds: config.server.workerTimeout),
    onMemoryApply: _memoryHandlers.onApply,
    onMemoryObserve: _memoryHandlers.onObserve,
    onContextualMemoryApply: (arguments, context) =>
        _memoryHandlers.apply(arguments, _memoryCaptureContext('memory_apply', context)),
    onContextualMemoryObserve: (arguments, context) =>
        _memoryHandlers.observe(arguments, _memoryCaptureContext('memory_observe', context)),
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
    prepareSubscriptionHome: prepareSubscriptionHome,
  );

  MemoryCaptureContext _memoryCaptureContext(String toolName, HarnessTurnContext context) {
    final isJournal = context.source == 'cron' && context.agentName == 'cron:memory-journal';
    return MemoryCaptureContext(
      originKind: isJournal ? MemoryOriginKind.journal : MemoryOriginKind.turn,
      sourceLocator: isJournal ? 'memory-journal' : 'session:${context.sessionId}',
      sourceEvent: 'turn:${context.turnId}',
      caller: context.agentName == 'main' ? toolName : context.agentName,
      sessionRef: context.sessionId,
    );
  }

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
    harness.onCompactionStarting = (sessionId, trigger) async {
      try {
        await _capturePreCompactObservation(sessionId, trigger);
      } finally {
        _eventBus.fire(CompactionStartingEvent(sessionId: sessionId, trigger: trigger, timestamp: DateTime.now()));
      }
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

  Future<void> _capturePreCompactObservation(String sessionId, String trigger) async {
    final messages = await _storage.messages.getMessagesTail(sessionId, count: _preCompactMessageCount);
    if (messages.isEmpty) return;
    final triggerLabel = trigger == 'manual' ? 'manual' : 'auto';
    final tail = messages.map((message) => '[${message.role}] ${_messageRedactor.redact(message.content)}').join('\n');
    final text = truncateUtf8Bytes(
      'Pre-compaction conversation context ($triggerLabel):\n$tail',
      _preCompactObservationMaxBytes,
    );
    await _memoryHandlers.observe(
      {'text': text, 'role': 'observation'},
      MemoryCaptureContext(
        originKind: MemoryOriginKind.turn,
        sourceLocator: 'session:$sessionId',
        sourceEvent: 'pre-compact:${messages.last.id}',
        caller: 'claude:PreCompact',
        sessionRef: sessionId,
      ),
    );
  }
}

/// Tools a worker must refuse, resolved against the MCP surface it will really
/// have.
///
/// On the host a provider-native web tool is suppressed only where the
/// deployment MCP endpoint replaces it, already folded into
/// [hostDisallowedTools]. Every container loses both of them regardless of what
/// its bridge serves: they run at the provider rather than in the container, so
/// `network:none` cannot contain them and the host gateway refuses any request
/// declaring one. Keeping a native tool the gateway would 403 buys no
/// capability — it only moves the failure to the agent's first call.
List<String> workerDisallowedTools({
  required String? containerProfile,
  required List<String> hostDisallowedTools,
  required List<String> userDisallowedTools,
}) {
  if (containerProfile == null) return hostDisallowedTools;
  return [...userDisallowedTools, 'WebFetch', 'WebSearch'];
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
  CredentialRegistry registry,
  Map<String, String> baseEnvironment,
) {
  final providerFamily = ProviderIdentity.resolveFamily(
    providerId,
    executable: _resolveProviderExecutable(config, providerId),
    options: _providerOptions(config, providerId),
  );
  final environment = SafeProcess.sanitize(
    baseEnvironment: baseEnvironment,
    extraEnvironment: providerFamily == ProviderIdentity.claude ? claudeHardeningEnvVars : const {},
  );
  // An ACP agent owns its own authentication: nothing DartClaw resolves is
  // presented to it, only the API key its registration explicitly names.
  final acpAgent = config.harness.acp[providerId];
  if (acpAgent != null) {
    return overlayAcpCredential(environment: environment, credentials: config.credentials, agent: acpAgent);
  }
  return overlayProviderCredential(
    environment: environment,
    registry: registry,
    providerId: providerId,
    providerFamily: providerFamily,
  );
}

/// Why [providerId] cannot present the credential selected for it, or `null`
/// when it can — the credential half of every execution-admission verdict.
///
/// [CredentialUnavailableReason.noneConfigured] is not a refusal: nothing was
/// selected, DartClaw presents nothing, and the vendor CLI's own login stays
/// admissible. Every other reason means the operator forced a credential this
/// deployment cannot present, and spawning anyway would authenticate the turn on
/// the ambient login they ruled out — not injecting one is not the same as
/// refusing one. A provider that declares it supplies its own credentials is
/// left alone, matching the startup gate; so is an ACP registration, which is
/// credential-isolated and therefore has no first-party selection to fail.
String? _credentialRefusalFor(DartclawConfig config, CredentialRegistry registry, String providerId) {
  final options = _providerOptions(config, providerId);
  if (options['credentials_required'] == false || config.harness.acp[providerId] != null) return null;
  final family = ProviderIdentity.resolveFamily(
    providerId,
    executable: _resolveProviderExecutable(config, providerId),
    options: options,
  );
  final reason = registry.resolve(providerId, family: family).reason;
  if (reason == null || reason == CredentialUnavailableReason.noneConfigured) return null;
  return credentialRemediationFor(
    reason,
    providerId: providerId,
    family: family,
    credentialsDir: config.credentialsDir,
  );
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
      entry.key: entry.value.copyWith(options: _withoutAcpValidationOptions(entry.value.options)),
  };
  for (final acpEntry in acpAgents.entries) {
    final providerId = acpEntry.key;
    final providerOverride = entries[providerId];
    final validation = acpValidationResults[providerId];
    final validationJson = validation?.toJson();
    entries[providerId] = (providerOverride ?? ProviderEntry(executable: acpEntry.value.binary)).copyWith(
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
