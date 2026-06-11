import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/mcp/delegate_to_agent_tool.dart';
import 'package:test/test.dart';

import 'delegate_to_agent_test_support.dart';

void main() {
  group('DelegateToAgentTool provider routing and turn outcomes', () {
    test('provider routing acquires only requested provider and releases once', () async {
      final goose = FakeDelegationRunner(providerId: 'goose');
      final codex = FakeDelegationRunner(providerId: 'codex');
      final pool = FakeDelegationPool({'goose': goose, 'codex': codex});
      final tool = DelegateToAgentTool(config: delegationConfig(), pool: pool, workspaceDir: '/tmp/ws');

      final result = await callDelegate(tool, {'agent_id': 'goose', 'task': 'research X'});

      expect(result['status'], 'completed');
      expect(pool.acquisitions, ['goose']);
      expect(pool.releases, 1);
      expect(goose.lastTask, 'research X');
      expect(codex.reserveCount, 0);
    });

    test('turn outcomes map cancellation and crash to terminal JSON', () async {
      final cancelled = FakeDelegationRunner(
        providerId: 'goose',
        outcomeFactory: (sessionId, turnId) => TurnOutcome(
          sessionId: sessionId,
          turnId: turnId,
          status: TurnStatus.cancelled,
          completedAt: DateTime.utc(2026),
        ),
      );
      final cancelledTool = DelegateToAgentTool(
        config: delegationConfig(),
        pool: FakeDelegationPool({'goose': cancelled}),
        workspaceDir: '/tmp/ws',
      );
      expect((await callDelegate(cancelledTool, {'agent_id': 'goose', 'task': 'x'}))['code'], 'CANCELLED');

      final crashed = FakeDelegationRunner(
        providerId: 'goose',
        outcomeFactory: (sessionId, turnId) => TurnOutcome(
          sessionId: sessionId,
          turnId: turnId,
          status: TurnStatus.failed,
          errorMessage: 'process crashed',
          completedAt: DateTime.utc(2026),
        ),
      );
      final crashTool = DelegateToAgentTool(
        config: delegationConfig(),
        pool: FakeDelegationPool({'goose': crashed}),
        workspaceDir: '/tmp/ws',
      );
      final crash = await callDelegate(crashTool, {'agent_id': 'goose', 'task': 'x'});
      expect(crash['status'], 'error');
      expect(crash['code'], 'AGENT_CRASHED');
    });

    test('turn outcomes map auth, spawn, and guard failures to required codes', () async {
      Future<Map<String, dynamic>> runWith(FakeDelegationRunner runner) {
        final tool = DelegateToAgentTool(
          config: delegationConfig(),
          pool: FakeDelegationPool({'goose': runner}),
          workspaceDir: '/tmp/ws',
        );
        return callDelegate(tool, {'agent_id': 'goose', 'task': 'x'});
      }

      final authRequired = FakeDelegationRunner(providerId: 'goose')
        ..waitError = const AcpHarnessException(AcpHarnessErrorCode.authRequired, 'auth required');
      expect((await runWith(authRequired))['code'], 'ACP_AUTH_REQUIRED');

      final spawnFailed = FakeDelegationRunner(providerId: 'goose')
        ..waitError = const AcpHarnessException(AcpHarnessErrorCode.spawnFailed, 'spawn failed');
      expect((await runWith(spawnFailed))['code'], 'SPAWN_FAILED');

      final guardDenied = FakeDelegationRunner(
        providerId: 'goose',
        outcomeFactory: (sessionId, turnId) => TurnOutcome(
          sessionId: sessionId,
          turnId: turnId,
          status: TurnStatus.failed,
          errorMessage: 'GUARD denied command',
          completedAt: DateTime.utc(2026),
        ),
      );
      expect((await runWith(guardDenied))['code'], 'GUARD_DENIED');
    });

    test('synchronous execute failures release the reserved turn once', () async {
      final runner = FakeDelegationRunner(providerId: 'goose')..executeError = StateError('spawn failed');
      final tool = DelegateToAgentTool(
        config: delegationConfig(),
        pool: FakeDelegationPool({'goose': runner}),
        workspaceDir: '/tmp/ws',
      );

      final result = await callDelegate(tool, {'agent_id': 'goose', 'task': 'x'});

      expect(result['code'], 'SPAWN_FAILED');
      expect(runner.releaseTurnCount, 1);
    });
  });
}
