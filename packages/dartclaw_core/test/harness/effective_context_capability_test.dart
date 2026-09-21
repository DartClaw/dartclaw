import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

import 'harness_test_support.dart';

void main() {
  test('capabilities come from adapters that serialize model and effort', () {
    final factory = HarnessFactory();
    final capabilities = factory.probeEffectiveContextCapabilities();

    expect(capabilities['claude']?.toJson(), {
      'model': true,
      'effort': true,
      'models': ['sonnet', 'opus', 'haiku'],
      'efforts': ['low', 'medium', 'high', 'max'],
    });
    // Codex transports a model but documents no catalogue of its own, so the
    // picker offers the provider default and whatever value is already staged.
    expect(capabilities['codex']?.toJson(), {
      'model': true,
      'effort': true,
      'models': <String>[],
      'efforts': ['low', 'medium', 'high', 'xhigh'],
    });

    final request = CodexProtocolAdapter().buildTurnRequest(
      message: 'hello',
      settings: const {'model': 'gpt-test', 'effort': 'high'},
    );
    expect(request, {
      'method': 'turn/start',
      'params': {
        'input': [
          {'type': 'text', 'text': 'hello'},
        ],
        'model': 'gpt-test',
        'effort': 'high',
      },
    });
  });

  test('Claude transports model and effort as exact CLI arguments', () async {
    final spawns = <List<String>>[];
    final harness = buildClaudeHarness(
      processFactory: resultEmittingFactory(onSpawn: (spawn) => spawns.add(spawn.args)),
    );
    addTearDown(harness.dispose);

    await harness.start();
    await harness.turn(
      sessionId: 'effective-context',
      messages: const [
        {'role': 'user', 'content': 'hello'},
      ],
      systemPrompt: '',
      model: 'claude-test',
      effort: 'high',
    );

    expect(spawns, hasLength(2));
    expect(spawns.last, containsAllInOrder(['--model', 'claude-test']));
    expect(spawns.last, containsAllInOrder(['--effort', 'high']));
  });

  test('unknown harnesses fail closed', () {
    expect(EffectiveContextCapabilities.of(_UnprovenHarness()).toJson(), {
      'model': false,
      'effort': false,
      'models': <String>[],
      'efforts': <String>[],
    });
  });
}

final class _UnprovenHarness extends AgentHarness {
  @override
  WorkerState get state => WorkerState.idle;

  @override
  bool get isRootProcessTerminationConfirmed => true;

  @override
  Stream<BridgeEvent> get events => const Stream.empty();

  @override
  Future<void> start() async {}

  @override
  Future<TurnResult> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    String? agentId,
    Map<String, dynamic>? mcpServers,
    String? providerSessionId,
    bool requestProviderSessionResume = false,
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
    Map<String, dynamic>? outputSchema,
  }) async => const TurnResult();

  @override
  Future<void> cancel() async {}

  @override
  Future<void> resetSessionContinuity(String sessionId) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}
