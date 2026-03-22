import 'dart:io';
import 'dart:math';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../serve_command.dart' show HarnessFactory, ExitFn, mcpDisallowedTools;
import 'storage_wiring.dart';
import 'security_wiring.dart';

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
  })  : _dataDir = dataDir,
        _port = port,
        _harnessFactory = harnessFactory,
        _exitFn = exitFn,
        _storage = storage,
        _security = security,
        _messageRedactor = messageRedactor,
        _eventBus = eventBus;

  final DartclawConfig config;
  final String _dataDir;
  final int _port;
  final HarnessFactory _harnessFactory;
  final ExitFn _exitFn;
  final StorageWiring _storage;
  final SecurityWiring _security;
  final MessageRedactor _messageRedactor;
  final EventBus _eventBus;

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
  late SessionLockManager _lockManager;
  late SessionResetService _resetService;
  late ({
    Future<Map<String, dynamic>> Function(Map<String, dynamic>) onSave,
    Future<Map<String, dynamic>> Function(Map<String, dynamic>) onSearch,
    Future<Map<String, dynamic>> Function(Map<String, dynamic>) onRead,
  }) _memoryHandlers;
  BudgetEnforcer? _budgetEnforcer;
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
  }) get memoryHandlers => _memoryHandlers;
  BudgetEnforcer? get budgetEnforcer => _budgetEnforcer;
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
      compactInstructions: config.context.compactInstructions,
    );
    final staticPrompt = await _behavior.composeStaticPrompt();

    _selfImprovement = SelfImprovementService(workspaceDir: config.workspaceDir);

    _memoryHandlers = createMemoryHandlers(
      memory: _storage.memory,
      memoryFile: _storage.memoryFile,
      searchBackend: _storage.searchBackend,
      selfImprovement: _selfImprovement,
    );

    _agentDefs = config.agent.definitions.isNotEmpty
        ? config.agent.definitions
        : [AgentDefinition.searchAgent()];
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

    _harness = _harnessFactory(
      Directory.current.path,
      claudeExecutable: config.server.claudeExecutable,
      turnTimeout: Duration(seconds: config.server.workerTimeout),
      onMemorySave: _memoryHandlers.onSave,
      onMemorySearch: _memoryHandlers.onSearch,
      onMemoryRead: _memoryHandlers.onRead,
      harnessConfig: _harnessConfig,
      containerManager: _security.containerManagers['workspace'],
    );
    try {
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

    final taskHarnesses = <AgentHarness>[];
    final taskProfileIds = <String>[];
    final maxConcurrent = config.tasks.maxConcurrent;
    final profileIds = _security.containerManagers.isEmpty
        ? ['workspace']
        : ['workspace', 'restricted'];
    final taskRunnerCount = maxConcurrent == 0
        ? 0
        : (_security.containerManagers.isEmpty
            ? maxConcurrent
            : max(maxConcurrent, profileIds.length));

    for (var i = 0; i < taskRunnerCount; i++) {
      final profileId = profileIds[i % profileIds.length];
      final containerManager =
          _security.containerManagers[profileId] ?? _security.containerManagers['workspace'];
      final taskHarness = _harnessFactory(
        Directory.current.path,
        claudeExecutable: config.server.claudeExecutable,
        turnTimeout: Duration(seconds: config.server.workerTimeout),
        onMemorySave: _memoryHandlers.onSave,
        onMemorySearch: _memoryHandlers.onSearch,
        onMemoryRead: _memoryHandlers.onRead,
        harnessConfig: _harnessConfig,
        containerManager: containerManager,
      );
      try {
        await taskHarness.start();
        taskHarnesses.add(taskHarness);
        taskProfileIds.add(profileId);
      } catch (e) {
        _log.warning('Failed to start task harness ${i + 1} of $taskRunnerCount: $e');
        // Degraded mode: continue with fewer task runners.
      }
    }
    if (taskHarnesses.isNotEmpty) {
      _log.info('Task pool: ${taskHarnesses.length} task runner(s) + 1 primary');
    }

    _sseBroadcast = SseBroadcast();
    _contextMonitor = ContextMonitor(
      reserveTokens: config.context.reserveTokens,
      warningThreshold: config.context.warningThreshold,
    );
    _explorationSummarizer = ExplorationSummarizer(
      trimmer: ResultTrimmer(maxBytes: config.context.maxResultBytes),
      thresholdTokens: config.context.explorationSummaryThreshold,
    );
    _lockManager = SessionLockManager(maxParallel: config.server.maxParallelTurns);
    _resetService = SessionResetService(
      sessions: _storage.sessions,
      messages: _storage.messages,
      resetHour: config.sessions.resetHour,
      idleTimeoutMinutes: config.sessions.idleTimeoutMinutes,
    );

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
        ? BudgetEnforcer(
            usageTracker: _usageTracker,
            config: config.governance.budget,
          )
        : null;
    final budgetEnforcer = _budgetEnforcer;

    // Build loop detector (shared across all runners — same detection state).
    final loopDetector = config.governance.loopDetection.enabled
        ? LoopDetector(config: config.governance.loopDetection)
        : null;
    final loopAction = config.governance.loopDetection.enabled
        ? config.governance.loopDetection.action
        : null;

    // Build TurnRunners for the pool.
    final runners = <TurnRunner>[
      TurnRunner(
        harness: _harness,
        messages: _storage.messages,
        behavior: _behavior,
        memoryFile: _storage.memoryFile,
        sessions: _storage.sessions,
        turnState: _storage.turnStateStore,
        kv: _storage.kvService,
        guardChain: _security.guardChain,
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
      ),
      for (var i = 0; i < taskHarnesses.length; i++)
        TurnRunner(
          harness: taskHarnesses[i],
          messages: _storage.messages,
          behavior: _behavior,
          memoryFile: _storage.memoryFile,
          sessions: _storage.sessions,
          turnState: _storage.turnStateStore,
          kv: _storage.kvService,
          guardChain: _security.guardChain,
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
          profileId: taskProfileIds[i],
        ),
    ];
    _pool = HarnessPool(runners: runners, maxConcurrentTasks: maxConcurrent);
  }
}

bool _hasSearchProvider(DartclawConfig config) =>
    config.search.providers.values.any((p) => p.enabled && p.apiKey.isNotEmpty);
