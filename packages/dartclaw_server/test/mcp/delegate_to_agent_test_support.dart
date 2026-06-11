import 'dart:convert';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart'
    show AgentHarness, HarnessPool, ToolResultText, TurnOutcome, TurnRunner, TurnStatus;
import 'package:dartclaw_server/src/mcp/delegate_to_agent_tool.dart';
import 'package:test/test.dart';

class FakeDelegationPool implements HarnessPool {
  final Map<String, FakeDelegationRunner> runnersByProvider;
  final List<String> acquisitions = [];
  int releases = 0;

  FakeDelegationPool(this.runnersByProvider);

  @override
  TurnRunner get primary => runnersByProvider.values.first;

  @override
  List<TurnRunner> get runners => runnersByProvider.values.toList();

  @override
  void addRunner(TurnRunner runner) {}

  @override
  int get spawnableCount => 0;

  @override
  TurnRunner? tryAcquire() => null;

  @override
  TurnRunner? tryAcquireForProfile(String profileId) => null;

  @override
  TurnRunner? tryAcquireForProvider(String providerId) {
    acquisitions.add(providerId);
    return runnersByProvider[providerId];
  }

  @override
  TurnRunner? tryAcquireForProviderAndProfile(String providerId, String profileId) => tryAcquireForProvider(providerId);

  @override
  void release(TurnRunner runner) {
    releases += 1;
  }

  @override
  int get activeCount => 0;

  @override
  int get availableCount => runnersByProvider.length;

  @override
  int get size => runnersByProvider.length + 1;

  @override
  int get maxConcurrentTasks => runnersByProvider.length;

  @override
  int indexOf(TurnRunner runner) => runners.indexOf(runner);

  @override
  bool hasTaskRunnerForProfile(String profileId) => true;

  @override
  bool hasTaskRunnerForProvider(String providerId) => runnersByProvider.containsKey(providerId);

  @override
  int taskRunnerCountForProvider(String providerId) => hasTaskRunnerForProvider(providerId) ? 1 : 0;

  @override
  Set<String> get taskProfiles => {'workspace'};

  @override
  Set<String> get taskProviders => runnersByProvider.keys.toSet();

  @override
  Future<void> dispose() async {}
}

class FakeDelegationRunner implements TurnRunner {
  @override
  final String providerId;

  @override
  final String profileId;

  TurnOutcome Function(String sessionId, String turnId) outcomeFactory;
  Object? reserveError;
  Object? executeError;
  Object? waitError;
  Duration waitDelay;
  int reserveCount = 0;
  int executeCount = 0;
  int releaseTurnCount = 0;
  int cancelCount = 0;
  String? directory;
  String? lastTask;

  FakeDelegationRunner({
    required this.providerId,
    this.profileId = 'workspace',
    TurnOutcome Function(String sessionId, String turnId)? outcomeFactory,
    this.waitDelay = Duration.zero,
  }) : outcomeFactory =
           outcomeFactory ??
           ((sessionId, turnId) => TurnOutcome(
             sessionId: sessionId,
             turnId: turnId,
             status: TurnStatus.completed,
             responseText: 'delegated output',
             inputTokens: 10,
             outputTokens: 20,
             completedAt: DateTime.utc(2026),
           ));

  @override
  AgentHarness get harness => throw StateError('FakeDelegationRunner does not expose a harness');

  @override
  Iterable<String> get activeSessionIds => const [];

  @override
  bool isActive(String sessionId) => false;

  @override
  String? activeTurnId(String sessionId) => null;

  @override
  bool isActiveTurn(String sessionId, String turnId) => false;

  @override
  TurnOutcome? recentOutcome(String sessionId, String turnId) => null;

  @override
  Future<String> reserveTurn(
    String sessionId, {
    String agentName = 'main',
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
    String? taskId,
    bool isHumanInput = false,
  }) async {
    reserveCount += 1;
    final error = reserveError;
    if (error != null) throw error;
    this.directory = directory;
    return 'turn-$reserveCount';
  }

  @override
  void executeTurn(
    String sessionId,
    String turnId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
    bool resume = false,
  }) {
    executeCount += 1;
    final error = executeError;
    if (error != null) throw error;
    lastTask = messages.single['content'] as String;
  }

  @override
  void releaseTurn(String sessionId, String turnId) {
    releaseTurnCount += 1;
  }

  @override
  Future<void> resetSessionContinuity(String sessionId) async {}

  @override
  Future<void> cancelTurn(String sessionId) async {
    cancelCount += 1;
  }

  @override
  Future<void> waitForCompletion(String sessionId, {Duration timeout = const Duration(seconds: 10)}) async {}

  @override
  Future<TurnOutcome> waitForOutcome(String sessionId, String turnId) async {
    if (waitDelay > Duration.zero) {
      await Future<void>.delayed(waitDelay);
    }
    final error = waitError;
    if (error != null) throw error;
    return outcomeFactory(sessionId, turnId);
  }

  @override
  void setTaskToolFilter(List<String>? allowedTools) {}

  @override
  void setTaskReadOnly(bool readOnly) {}
}

DartclawConfig delegationConfig({
  bool enabled = true,
  List<DelegationAgentConfig> agents = const [DelegationAgentConfig(id: 'goose', requireGuardMediation: true)],
  int maxBudgetTokens = 50000,
  DelegationBudgetAccounting budgetAccounting = DelegationBudgetAccounting.providerReported,
  int rateLimit = 0,
  Map<String, ProviderEntry> providers = const {},
  AcpConfig acp = const AcpConfig(
    agents: {'goose': AcpAgentConfig(binary: 'goose', topology: AcpAgentTopology.direct, requiresGuardMediation: true)},
  ),
}) {
  return DartclawConfig(
    server: const ServerConfig(dataDir: '/tmp/dartclaw-test'),
    delegation: DelegationConfig(
      enabled: enabled,
      agents: agents,
      maxBudgetTokens: maxBudgetTokens,
      budgetAccounting: budgetAccounting,
      rateLimit: DelegationRateLimitConfig(maxPerMinute: rateLimit),
    ),
    providers: ProvidersConfig(entries: providers),
    harness: HarnessConfig(acp: acp),
  );
}

Future<Map<String, dynamic>> callDelegate(DelegateToAgentTool tool, Map<String, dynamic> args) async {
  final result = await tool.call(args);
  expect(result, isA<ToolResultText>());
  return jsonDecode((result as ToolResultText).content) as Map<String, dynamic>;
}
