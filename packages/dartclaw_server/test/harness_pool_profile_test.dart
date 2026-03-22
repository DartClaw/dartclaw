import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

/// Minimal AgentHarness stub for pool tests.
class _StubHarness implements AgentHarness {
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
  }) async => {};
  @override
  Future<void> cancel() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

TurnRunner _makeRunner({String profileId = 'workspace'}) {
  final dir = Directory.systemTemp.createTempSync('pool-test-');
  addTearDown(() => dir.deleteSync(recursive: true));
  return TurnRunner(
    harness: _StubHarness(),
    messages: MessageService(baseDir: dir.path),
    behavior: BehaviorFileService(workspaceDir: dir.path),
    profileId: profileId,
  );
}

void main() {
  group('HarnessPool profile-aware acquisition', () {
    test('tryAcquireForProfile returns matching runner', () {
      final primary = _makeRunner();
      final workspace = _makeRunner(profileId: 'workspace');
      final restricted = _makeRunner(profileId: 'restricted');
      final pool = HarnessPool(runners: [primary, workspace, restricted]);

      final acquired = pool.tryAcquireForProfile('restricted');
      expect(acquired, isNotNull);
      expect(acquired!.profileId, 'restricted');
    });

    test('tryAcquireForProfile returns null when no match', () {
      final primary = _makeRunner();
      final workspace = _makeRunner(profileId: 'workspace');
      final pool = HarnessPool(runners: [primary, workspace]);

      final acquired = pool.tryAcquireForProfile('restricted');
      expect(acquired, isNull);
    });

    test('tryAcquireForProfile does not return primary runner', () {
      final primary = _makeRunner(profileId: 'workspace');
      final pool = HarnessPool(runners: [primary]);

      final acquired = pool.tryAcquireForProfile('workspace');
      expect(acquired, isNull);
    });

    test('tryAcquireForProfile does not return busy runner', () {
      final primary = _makeRunner();
      final r1 = _makeRunner(profileId: 'restricted');
      final pool = HarnessPool(runners: [primary, r1]);

      final first = pool.tryAcquireForProfile('restricted');
      expect(first, isNotNull);

      final second = pool.tryAcquireForProfile('restricted');
      expect(second, isNull);
    });

    test('released runner can be re-acquired by profile', () {
      final primary = _makeRunner();
      final r1 = _makeRunner(profileId: 'restricted');
      final pool = HarnessPool(runners: [primary, r1]);

      final acquired = pool.tryAcquireForProfile('restricted')!;
      pool.release(acquired);

      final reacquired = pool.tryAcquireForProfile('restricted');
      expect(reacquired, isNotNull);
      expect(reacquired!.profileId, 'restricted');
    });

    test('tryAcquire returns any available runner regardless of profile', () {
      final primary = _makeRunner();
      final restricted = _makeRunner(profileId: 'restricted');
      final pool = HarnessPool(runners: [primary, restricted]);

      final acquired = pool.tryAcquire();
      expect(acquired, isNotNull);
      expect(acquired!.profileId, 'restricted');
    });

    test('pool with mixed profiles tracks counts correctly', () {
      final primary = _makeRunner();
      final ws = _makeRunner(profileId: 'workspace');
      final rs = _makeRunner(profileId: 'restricted');
      final pool = HarnessPool(runners: [primary, ws, rs]);

      expect(pool.availableCount, 2);
      expect(pool.activeCount, 0);

      final a1 = pool.tryAcquireForProfile('workspace')!;
      expect(pool.availableCount, 1);
      expect(pool.activeCount, 1);

      pool.tryAcquireForProfile('restricted');
      expect(pool.availableCount, 0);
      expect(pool.activeCount, 2);

      pool.release(a1);
      expect(pool.availableCount, 1);
      expect(pool.activeCount, 1);
    });
  });
}
