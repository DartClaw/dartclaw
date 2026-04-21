import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

TurnRunner _makeRunner({String profileId = 'workspace', String providerId = 'claude'}) {
  final dir = Directory.systemTemp.createTempSync('pool-provider-test-');
  addTearDown(() => dir.deleteSync(recursive: true));

  return TurnRunner(
    harness: _StubHarness(),
    messages: MessageService(baseDir: dir.path),
    behavior: BehaviorFileService(workspaceDir: dir.path),
    profileId: profileId,
    providerId: providerId,
  );
}

void main() {
  group('HarnessPool provider-aware acquisition', () {
    test('primary runner provider defaults to claude', () {
      final primary = _makeRunner();
      final taskClaude = _makeRunner(providerId: 'claude');
      final taskCodex = _makeRunner(providerId: 'codex');
      final pool = HarnessPool(runners: [primary, taskClaude, taskCodex]);

      expect(pool.primary.providerId, 'claude');
      expect(pool.taskProviders, {'claude', 'codex'});
      expect(pool.hasTaskRunnerForProvider('claude'), isTrue);
      expect(pool.hasTaskRunnerForProvider('codex'), isTrue);
      expect(pool.hasTaskRunnerForProvider('unknown'), isFalse);
    });

    test('tryAcquireForProvider returns the requested provider and never falls back', () {
      final primary = _makeRunner();
      final taskClaude = _makeRunner(providerId: 'claude');
      final taskCodex = _makeRunner(providerId: 'codex');
      final pool = HarnessPool(runners: [primary, taskClaude, taskCodex]);

      final acquiredCodex = pool.tryAcquireForProvider('codex');
      expect(acquiredCodex, isNotNull);
      expect(acquiredCodex!.providerId, 'codex');

      final secondCodex = pool.tryAcquireForProvider('codex');
      expect(secondCodex, isNull);

      final acquiredClaude = pool.tryAcquireForProvider('claude');
      expect(acquiredClaude, isNotNull);
      expect(acquiredClaude!.providerId, 'claude');
    });

    test('tryAcquireForProvider returns null when a matching provider is busy even if another provider is idle', () {
      final primary = _makeRunner();
      final taskClaude = _makeRunner(providerId: 'claude');
      final taskCodex = _makeRunner(providerId: 'codex');
      final pool = HarnessPool(runners: [primary, taskClaude, taskCodex]);

      final acquiredCodex = pool.tryAcquireForProvider('codex');
      expect(acquiredCodex, isNotNull);

      final fallbackAttempt = pool.tryAcquireForProvider('codex');
      expect(fallbackAttempt, isNull);
      expect(pool.availableCount, 1);
      expect(pool.activeCount, 1);
      expect(pool.tryAcquire(), isNotNull);
    });

    test('release returns a provider-specific runner to the available pool', () {
      final primary = _makeRunner();
      final taskClaude = _makeRunner(providerId: 'claude');
      final taskCodex = _makeRunner(providerId: 'codex');
      final pool = HarnessPool(runners: [primary, taskClaude, taskCodex]);

      final acquired = pool.tryAcquireForProvider('codex');
      expect(acquired, isNotNull);

      pool.release(acquired!);

      final reacquired = pool.tryAcquireForProvider('codex');
      expect(reacquired, isNotNull);
      expect(reacquired!.providerId, 'codex');
    });

    test('tryAcquire still works with mixed-provider pools', () {
      final primary = _makeRunner();
      final taskClaude = _makeRunner(providerId: 'claude');
      final taskCodex = _makeRunner(providerId: 'codex');
      final pool = HarnessPool(runners: [primary, taskClaude, taskCodex]);

      final acquired = pool.tryAcquire();
      expect(acquired, isNotNull);
      expect(acquired, isNot(same(pool.primary)));
      expect(acquired!.providerId, anyOf('claude', 'codex'));
    });
  });
}

class _StubHarness implements AgentHarness {
  @override
  String skillActivationLine(String skill) => "Use the '$skill' skill.";

  @override
  bool get supportsCostReporting => true;

  @override
  bool get supportsToolApproval => true;

  @override
  bool get supportsStreaming => true;

  @override
  bool get supportsCachedTokens => false;

  @override
  bool get supportsSessionContinuity => false;

  @override
  bool get supportsPreCompactHook => false;

  @override
  WorkerState get state => WorkerState.idle;

  @override
  Stream<BridgeEvent> get events => const Stream.empty();

  @override
  PromptStrategy get promptStrategy => PromptStrategy.replace;

  @override
  Future<void> start() async {}

  @override
  Future<Map<String, dynamic>> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    Map<String, dynamic>? mcpServers,
    bool resume = false,
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
  }) async {
    return const {'input_tokens': 0, 'output_tokens': 0};
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}
