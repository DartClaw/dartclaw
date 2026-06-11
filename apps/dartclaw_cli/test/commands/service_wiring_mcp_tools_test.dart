import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show HarnessPool, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart' show DelegateToAgentTool;
import 'package:test/test.dart';

void main() {
  test('delegate_to_agent tool is available from the server MCP surface used by service wiring', () {
    final tool = DelegateToAgentTool(
      config: const DartclawConfig(
        delegation: DelegationConfig(enabled: true, agents: [DelegationAgentConfig(id: 'goose')]),
      ),
      pool: _NoopPool(),
      workspaceDir: '/tmp/ws',
    );

    expect(tool.name, 'delegate_to_agent');
    expect(tool.inputSchema['required'], containsAll(['agent_id', 'task']));
    expect(tool.inputSchema['additionalProperties'], isFalse);
    expect(tool, isA<DelegateToAgentTool>());
    expect(const DelegationConfig.defaults().enabled, isFalse);
  });
}

class _NoopPool implements HarnessPool {
  @override
  TurnRunner get primary => throw StateError('No primary runner in _NoopPool');

  @override
  List<TurnRunner> get runners => const [];

  @override
  void addRunner(TurnRunner runner) {}

  @override
  int get spawnableCount => 0;

  @override
  TurnRunner? tryAcquire() => null;

  @override
  TurnRunner? tryAcquireForProfile(String profileId) => null;

  @override
  TurnRunner? tryAcquireForProvider(String providerId) => null;

  @override
  TurnRunner? tryAcquireForProviderAndProfile(String providerId, String profileId) => null;

  @override
  void release(TurnRunner runner) {}

  @override
  int get activeCount => 0;

  @override
  int get availableCount => 0;

  @override
  int get size => 0;

  @override
  int get maxConcurrentTasks => 0;

  @override
  int indexOf(TurnRunner runner) => -1;

  @override
  bool hasTaskRunnerForProfile(String profileId) => false;

  @override
  bool hasTaskRunnerForProvider(String providerId) => false;

  @override
  int taskRunnerCountForProvider(String providerId) => 0;

  @override
  Set<String> get taskProfiles => const {};

  @override
  Set<String> get taskProviders => const {};

  @override
  Future<void> dispose() async {}
}
