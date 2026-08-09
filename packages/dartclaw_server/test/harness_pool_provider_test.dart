import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide HarnessPool, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart' hide HarnessPool, TurnRunner;
import 'package:dartclaw_server/src/harness_pool.dart' show HarnessPool;
import 'package:dartclaw_server/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:test/test.dart';

TurnRunner _makeRunner({String profileId = 'workspace', String providerId = 'claude'}) {
  final dir = Directory.systemTemp.createTempSync('pool-provider-test-');
  addTearDown(() => dir.deleteSync(recursive: true));

  return TurnRunner(
    harness: FakeAgentHarness(autoTransitionState: false),
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
      expect(pool.workerProviders, {'claude', 'codex'});
      expect(pool.hasWorkerForProvider('claude'), isTrue);
      expect(pool.hasWorkerForProvider('codex'), isTrue);
      expect(pool.hasWorkerForProvider('unknown'), isFalse);
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

    test('busy provider does not block another provider with idle capacity', () {
      final primary = _makeRunner();
      final taskClaude = _makeRunner(providerId: 'claude');
      final taskCodex = _makeRunner(providerId: 'codex');
      final pool = HarnessPool(runners: [primary, taskClaude, taskCodex], maxConcurrentWorkers: 2);

      final acquiredClaude = pool.tryAcquireForProvider('claude');
      expect(acquiredClaude, isNotNull);

      final acquiredCodex = pool.tryAcquireForProvider('codex');
      expect(acquiredCodex, isNotNull);
      expect(acquiredCodex!.providerId, 'codex');
      expect(pool.activeCount, lessThanOrEqualTo(pool.maxConcurrentWorkers));
      expect(pool.tryAcquire(), isNull);
      expect(pool.primary, isNot(same(acquiredClaude)));
      expect(pool.primary, isNot(same(acquiredCodex)));
    });

    test('constructor rejects more initial workers than the hard cap', () {
      final primary = _makeRunner();
      final taskClaude = _makeRunner(providerId: 'claude');
      final taskCodex = _makeRunner(providerId: 'codex');

      expect(
        () => HarnessPool(runners: [primary, taskClaude, taskCodex], maxConcurrentWorkers: 1),
        throwsArgumentError,
      );
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
