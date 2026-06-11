import 'dart:io';
import 'dart:math';
import 'package:dartclaw_core/dartclaw_core.dart' hide HarnessPool, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart' hide HarnessConfig;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../serve_command.dart' show ExitFn, mcpDisallowedTools;
import 'storage_wiring.dart';
import 'security_wiring.dart';

typedef _SpawnPlanEntry = ({
  String providerId,
  String profileId,
  String executable,
  String credentialProviderId,
  Map<String, dynamic> options,
  bool requiresContainer,
});

/// Constructs and exposes harness-layer services.
///
/// Owns agent definitions, primary + task harnesses, harness pool, token service,
/// usage tracker, health service, context management, session delegate, behavior
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
  late HarnessPool _pool;
  late HarnessConfig _harnessConfig;
  late List<AgentDefinition> _agentDefs;
  late Map<String, AgentDefinition> _agentMap;
  late BehaviorFileService _behavior;
  late SelfImprovementService _selfImprovement;
  late SessionDelegate _sessionDelegate;
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
  SpawnTaskRunner? _onSpawnNeeded;
  Map<String, ProviderEntry> _providerStatusEntries = const {};
  bool _authEnabled = false;
  TokenService? _tokenService;
  String? _resolvedGatewayToken;

  AgentHarness get harness => _harness;
  HarnessPool get pool => _pool;
  HarnessConfig get harnessConfig => _harnessConfig;
  List<AgentDefinition> get agentDefs => _agentDefs;
  Map<String, AgentDefinition> get agentMap => _agentMap;
  BehaviorFileService get behavior => _behavior;
  SelfImprovementService get selfImprovement => _selfImprovement;
  SessionDelegate get sessionDelegate => _sessionDelegate;
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
  SpawnTaskRunner? get onSpawnNeeded => _onSpawnNeeded;
  Map<String, ProviderEntry> get providerStatusEntries => _providerStatusEntries;
  bool get authEnabled => _authEnabled;
  TokenService? get tokenService => _tokenService;
  String? get resolvedGatewayToken => _resolvedGatewayToken;

  /// Wires harness services. [serverRefGetter] is resolved lazily for
  /// the session delegate dispatch closure.
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

    _agentDefs = config.agent.definitions.isNotEmpty ? config.agent.definitions : [AgentDefinition.searchAgent()];
    _agentMap = {for (final a in _agentDefs) a.id: a};
    final agentsPayload = {for (final a in _agentDefs) a.id: a.toInitializePayload()};

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
      final isLoopback = host == 'localhost' || host == '127.0.0.1';
      if (isLoopback) {
        _log.warning('Auth disabled on loopback — acceptable for local dev only');
      } else {
        _log.severe('CRITICAL: Auth disabled on network-accessible host $host');
      }
    }

    final mcpEnabled = _resolvedGatewayToken != null;
    _harnessConfig = HarnessConfig(
      disallowedTools: mcpDisallowedTools(
        mcpEnabled: mcpEnabled,
        searchEnabled: _hasSearchProvider(config),
        userDisallowed: config.agent.disallowedTools,
      ),
      maxTurns: config.agent.maxTurns,
      model: config.agent.model,
      effort: config.agent.effort,
      agents: agentsPayload,
      appendSystemPrompt: staticPrompt,
      mcpServerUrl: _resolvedGatewayToken != null ? 'http://127.0.0.1:$_port/mcp' : null,
      mcpGatewayToken: _resolvedGatewayToken,
    );

    final credentialRegistry = CredentialRegistry(credentials: config.credentials, env: Platform.environment);
    final defaultProviderId = config.agent.provider;
    final acpValidationResults = await _validateConfiguredAcpTargets(config);
    for (final entry in config.harness.acp.agents.entries) {
      if (acpValidationResults[entry.key]?.status != AcpTargetValidationStatus.passed) {
        continue;
      }
      _harnessFactory.registerAcpAgent(entry.key, entry.value);
    }
    try {
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
          guardChain: _security.guardChain,
          acpPermissionDecision: _acpPermissionDecision,
          acpReverseCallAudit: _auditAcpReverseCall,
          environment: _providerEnvironment(
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

    // Task pool capacity — runners are spawned lazily on first task creation.
    final profileIds = _security.containerManagers.isEmpty ? ['workspace'] : ['workspace', 'restricted'];
    final providerEntries = _effectiveTaskProviderEntries(config, acpValidationResults);
    _providerStatusEntries = providerEntries;
    final useLegacyTaskPool = config.providers.isEmpty && config.harness.acp.isEmpty;
    final maxConcurrent = useLegacyTaskPool
        ? config.tasks.maxConcurrent
        : providerEntries.values.fold<int>(0, (sum, entry) => sum + entry.effectivePoolSize);

    // Build a spawn plan: one entry per future task runner, consumed in order.
    final spawnPlan = <_SpawnPlanEntry>[];
    if (useLegacyTaskPool) {
      final taskRunnerCount = config.tasks.maxConcurrent == 0
          ? 0
          : (_security.containerManagers.isEmpty
                ? config.tasks.maxConcurrent
                : max(config.tasks.maxConcurrent, profileIds.length));
      final legacyProviderId = defaultProviderId;
      final legacyExecutable = _resolveProviderExecutable(config, legacyProviderId);
      final legacyProviderOptions = _providerOptions(config, legacyProviderId);
      for (var i = 0; i < taskRunnerCount; i++) {
        spawnPlan.add((
          providerId: legacyProviderId,
          profileId: profileIds[i % profileIds.length],
          executable: legacyExecutable,
          credentialProviderId: _credentialProviderIdForProvider(config, legacyProviderId),
          options: legacyProviderOptions,
          requiresContainer: false,
        ));
      }
    } else {
      for (final providerEntry in providerEntries.entries) {
        final providerId = providerEntry.key;
        final entry = providerEntry.value;
        final acpEntry = config.harness.acp[providerId];
        final planProfiles = _profilesForProvider(config, providerId, profileIds);
        for (var i = 0; i < entry.effectivePoolSize; i++) {
          spawnPlan.add((
            providerId: providerId,
            profileId: planProfiles[i % planProfiles.length],
            executable: entry.executable,
            credentialProviderId: _credentialProviderIdForProvider(config, providerId),
            options: entry.options,
            requiresContainer: acpEntry?.containerIsolationRequired ?? false,
          ));
        }
      }
    }
    if (maxConcurrent > 0) {
      _log.info('Task pool: lazy, up to $maxConcurrent task runner(s) + 1 primary');
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

    final totalConcurrent = _agentDefs.fold(0, (sum, a) => sum + a.maxConcurrent);
    final subagentLimits = SubagentLimits(
      maxConcurrent: totalConcurrent,
      maxSpawnDepth: 1,
      maxChildrenPerAgent: totalConcurrent,
    );

    _sessionDelegate = SessionDelegate(
      dispatch: ({required sessionId, required message, required agentId}) async {
        final session = await _storage.sessions.getOrCreateByKey(sessionId);
        final userMsg = <String, dynamic>{'role': 'user', 'content': message};
        final srv = serverRefGetter();
        final turnId = await srv.turns.startTurn(session.id, [userMsg], agentName: agentId);
        final outcome = await srv.turns.waitForOutcome(session.id, turnId);
        if (outcome.status != TurnStatus.completed) {
          throw StateError('Agent turn failed: ${outcome.errorMessage}');
        }
        final msgs = await _storage.messages.getMessages(session.id);
        final lastAssistant = msgs.lastWhere(
          (m) => m.role == 'assistant',
          orElse: () => throw StateError('No assistant response in session'),
        );
        return lastAssistant.content;
      },
      limits: subagentLimits,
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

    // Build primary TurnRunner and pool (task runners spawned lazily).
    // Each runner gets its own TaskToolFilterGuard so per-task allowedTools
    // enforcement is isolated across concurrent runners.
    final primaryFilter = TaskToolFilterGuard();
    final primaryRunner = TurnRunner(
      harness: _harness,
      messages: _storage.messages,
      behavior: _behavior,
      memoryFile: _storage.memoryFile,
      sessions: _storage.sessions,
      turnState: _storage.turnStateStore,
      kv: _storage.kvService,
      guardChain: _security.guardChain,
      taskToolFilterGuard: primaryFilter,
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
      providerId: defaultProviderId,
    );
    _pool = HarnessPool(runners: [primaryRunner], maxConcurrentTasks: maxConcurrent);

    // Lazy spawn callback — consumed by TaskExecutor when tasks arrive.
    final consumedSpawnPlanIndexes = <int>{};
    _onSpawnNeeded = spawnPlan.isEmpty
        ? null
        : (requestedProviderId) async {
            if (_pool.spawnableCount <= 0) return false;
            final planIndex = _nextSpawnPlanIndex(
              spawnPlan,
              consumedSpawnPlanIndexes,
              requestedProviderId: requestedProviderId,
            );
            if (planIndex == null) {
              _log.warning(
                requestedProviderId == null
                    ? 'No task runner spawn-plan entry remains'
                    : 'No task runner spawn-plan entry remains for provider "$requestedProviderId"',
              );
              return false;
            }
            final plan = spawnPlan[planIndex];
            final containerManager = _security.containerManagers[plan.profileId];
            if (plan.requiresContainer && containerManager == null) {
              _log.warning(
                'ACP provider "${plan.providerId}" requires unavailable container profile "${plan.profileId}"',
              );
              return false;
            }
            try {
              // Each task runner gets its own TaskToolFilterGuard so per-task
              // allowedTools enforcement is isolated across concurrent runners.
              final taskFilter = TaskToolFilterGuard();
              final taskGuardChain = _buildTaskGuardChain(_security.guardChain, taskFilter);
              final taskPrompt = await _behavior.composeStaticPrompt(scope: PromptScope.task);
              final taskHarnessConfig = _harnessConfig.copyWith(appendSystemPrompt: taskPrompt);
              final taskHarness = _harnessFactory.create(
                plan.providerId,
                HarnessFactoryConfig(
                  cwd: Directory.current.path,
                  executable: plan.executable,
                  turnTimeout: Duration(seconds: config.server.workerTimeout),
                  onMemorySave: _memoryHandlers.onSave,
                  onMemorySearch: _memoryHandlers.onSearch,
                  onMemoryRead: _memoryHandlers.onRead,
                  onPermissionDenied: (toolName, reason) {
                    _eventBus.fire(
                      ToolPermissionDeniedEvent(toolName: toolName, reason: reason, timestamp: DateTime.now()),
                    );
                  },
                  harnessConfig: taskHarnessConfig,
                  historyConfig: config.agent.history,
                  providerOptions: plan.options,
                  containerManager: containerManager,
                  guardChain: taskGuardChain,
                  environment: {
                    ..._providerEnvironment(plan.credentialProviderId, credentialRegistry),
                    ..._taskRunnerSubagentEnvironment,
                  },
                ),
              );
              _wireCompactionCallbacks(taskHarness);
              await taskHarness.start();
              final runner = TurnRunner(
                harness: taskHarness,
                messages: _storage.messages,
                behavior: _behavior,
                memoryFile: _storage.memoryFile,
                sessions: _storage.sessions,
                turnState: _storage.turnStateStore,
                kv: _storage.kvService,
                guardChain: taskGuardChain,
                taskToolFilterGuard: taskFilter,
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
                profileId: plan.profileId,
                providerId: plan.providerId,
              );
              _pool.addRunner(runner);
              consumedSpawnPlanIndexes.add(planIndex);
              return true;
            } catch (e) {
              _log.warning('Failed to spawn task runner: $e');
              return false;
            }
          };
  }

  Future<AcpPermissionResult> _acpPermissionDecision(AcpPermissionRequest request) async {
    final guardChain = _security.guardChain;
    if (guardChain == null) {
      return const AcpPermissionResult(granted: false, reason: 'Guard chain unavailable');
    }
    try {
      final verdict = await guardChain.evaluateBeforeToolCall(
        request.operation,
        request.params,
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

const _taskRunnerSubagentEnvironment = <String, String>{'CLAUDE_CODE_SUBAGENT_MODEL': 'sonnet'};

/// Creates a per-harness [GuardChain] that includes all guards from [base]
/// plus the per-runner [filter].
///
/// Each task runner requires its own guard chain instance so that mutating
/// [filter.allowedTools] for one runner does not affect others.
/// When [base] is null, returns a chain with only the filter guard.
GuardChain _buildTaskGuardChain(GuardChain? base, TaskToolFilterGuard filter) {
  final guards = <Guard>[...?base?.guards, filter];
  return GuardChain(guards: guards, onVerdict: base?.onVerdict, failOpen: base?.failOpen ?? false);
}

Map<String, String> _providerEnvironment(String providerId, CredentialRegistry registry) {
  final environment = SafeProcess.sanitize(
    baseEnvironment: Platform.environment,
    sensitivePatterns: [...defaultSensitivePatterns, 'CLAUDE_CODE_SUBAGENT_MODEL'],
    extraEnvironment: claudeHardeningEnvVars,
  );
  final apiKey = registry.getApiKey(providerId);
  if (apiKey != null) {
    for (final envVar in CredentialRegistry.envVarsFor(providerId)) {
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

bool _hasSearchProvider(DartclawConfig config) =>
    config.search.providers.values.any((p) => p.enabled && p.apiKey.isNotEmpty);

Map<String, ProviderEntry> _effectiveTaskProviderEntries(
  DartclawConfig config,
  Map<String, AcpTargetValidationResult> acpValidationResults,
) {
  final entries = {
    for (final entry in config.providers.entries.entries)
      entry.key: ProviderEntry(
        executable: entry.value.executable,
        poolSize: entry.value.poolSize,
        options: _withoutAcpValidationOptions(entry.value.options),
      ),
  };
  for (final acpEntry in config.harness.acp.agents.entries) {
    final providerOverride = entries[acpEntry.key];
    final validation = acpValidationResults[acpEntry.key];
    final validationJson = validation?.toJson();
    entries[acpEntry.key] = ProviderEntry(
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
    config.agent.provider,
    () => ProviderEntry(executable: _resolveProviderExecutable(config, config.agent.provider)),
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
  if (config.harness.acp.isEmpty) {
    return const {};
  }
  const validator = AcpTargetValidator();
  final results = await validator.validateConfiguredTargets(
    agents: config.harness.acp.agents,
    commandProbe: Process.run,
    advertisedCapabilities: {
      for (final providerId in config.harness.acp.agents.keys) providerId: const {'fs', 'terminal'},
    },
    requiredTargets: config.harness.acp.agents.entries
        .where((entry) => entry.key == config.agent.provider || entry.value.requiresGuardMediation)
        .map((entry) => entry.key)
        .toSet(),
  );
  final failures = results.entries.where(
    (entry) =>
        entry.value.status == AcpTargetValidationStatus.failed &&
        config.harness.acp[entry.key]?.requiresGuardMediation == true,
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
  Map<String, AcpTargetValidationResult> acpValidationResults,
) {
  if (config.providers.isEmpty && config.harness.acp.isEmpty) {
    return {
      config.agent.provider: ProviderEntry(executable: _resolveProviderExecutable(config, config.agent.provider)),
    };
  }
  return _effectiveTaskProviderEntries(config, acpValidationResults);
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

int? _nextSpawnPlanIndex(
  List<_SpawnPlanEntry> spawnPlan,
  Set<int> consumedIndexes, {
  required String? requestedProviderId,
}) {
  for (var i = 0; i < spawnPlan.length; i++) {
    if (consumedIndexes.contains(i)) continue;
    if (requestedProviderId != null && spawnPlan[i].providerId != requestedProviderId) continue;
    return i;
  }
  return null;
}
