import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/mcp/delegate_to_agent_tool.dart';
import 'package:test/test.dart';

import 'delegate_to_agent_test_support.dart';

void main() {
  group('DelegateToAgentTool result contract', () {
    test('emits required completed fields', () async {
      final tool = DelegateToAgentTool(
        config: delegationConfig(),
        pool: FakeDelegationPool({'goose': FakeDelegationRunner(providerId: 'goose')}),
        workspaceDir: '/tmp/ws',
      );

      final result = await callDelegate(tool, {'agent_id': 'goose', 'task': 'x'});

      expect(
        result.keys,
        containsAll(['status', 'agent_id', 'security_mode', 'usage', 'budget_status', 'budget_enforcement']),
      );
      expect(result['status'], 'completed');
    });

    test('emits required codes for handled terminal results', () async {
      Future<void> expectCode(DelegateToAgentTool tool, String code, {Map<String, dynamic>? args}) async {
        final result = await callDelegate(tool, args ?? {'agent_id': 'goose', 'task': 'x'});
        expect(result['code'], code);
      }

      await expectCode(
        DelegateToAgentTool(
          config: delegationConfig(enabled: false),
          pool: FakeDelegationPool({'goose': FakeDelegationRunner(providerId: 'goose')}),
          workspaceDir: '/tmp/ws',
        ),
        'DELEGATION_DISABLED',
      );
      await expectCode(
        DelegateToAgentTool(
          config: delegationConfig(),
          pool: FakeDelegationPool({'goose': FakeDelegationRunner(providerId: 'goose')}),
          workspaceDir: '/tmp/ws',
        ),
        'AGENT_NOT_ALLOWLISTED',
        args: {'agent_id': 'codex', 'task': 'x'},
      );
      await expectCode(
        DelegateToAgentTool(
          config: delegationConfig(agents: const [DelegationAgentConfig(id: 'missing_acp_agent')]),
          pool: FakeDelegationPool({'goose': FakeDelegationRunner(providerId: 'goose')}),
          workspaceDir: '/tmp/ws',
        ),
        'UNKNOWN_AGENT',
        args: {'agent_id': 'missing_acp_agent', 'task': 'x'},
      );
      await expectCode(
        DelegateToAgentTool(
          config: delegationConfig(
            acp: const AcpConfig(
              agents: {'goose': AcpAgentConfig(binary: 'goose', topology: AcpAgentTopology.relay)},
            ),
          ),
          pool: FakeDelegationPool({'goose': FakeDelegationRunner(providerId: 'goose')}),
          workspaceDir: '/tmp/ws',
        ),
        'AGENT_SECURITY_MODE_UNAVAILABLE',
      );
      final validTool = DelegateToAgentTool(
        config: delegationConfig(),
        pool: FakeDelegationPool({'goose': FakeDelegationRunner(providerId: 'goose')}),
        workspaceDir: '/tmp/ws',
      );
      await expectCode(validTool, 'INVALID_WORK_DIR', args: {'agent_id': 'goose', 'task': 'x', 'work_dir': '/etc'});
      await expectCode(validTool, 'EMPTY_TASK', args: {'agent_id': 'goose', 'task': ' '});
      await expectCode(
        DelegateToAgentTool(
          config: delegationConfig(),
          pool: FakeDelegationPool({'goose': FakeDelegationRunner(providerId: 'goose')}),
          workspaceDir: '/tmp/ws',
          estimateTaskTokens: (_) => 50231,
        ),
        'BUDGET_EXCEEDED',
      );
      await expectCode(
        DelegateToAgentTool(
          config: delegationConfig(),
          pool: FakeDelegationPool({'goose': FakeDelegationRunner(providerId: 'goose')..outcomeFactory = _zeroUsage}),
          workspaceDir: '/tmp/ws',
        ),
        'BUDGET_USAGE_UNAVAILABLE',
      );
      await expectCode(
        DelegateToAgentTool(
          config: delegationConfig(),
          pool: FakeDelegationPool({
            'goose': FakeDelegationRunner(
              providerId: 'goose',
              outcomeFactory: (sessionId, turnId) => TurnOutcome(
                sessionId: sessionId,
                turnId: turnId,
                status: TurnStatus.failed,
                errorMessage: 'process crashed',
                completedAt: DateTime.utc(2026),
              ),
            ),
          }),
          workspaceDir: '/tmp/ws',
        ),
        'AGENT_CRASHED',
      );
      await expectCode(
        DelegateToAgentTool(
          config: delegationConfig(),
          pool: FakeDelegationPool({
            'goose': FakeDelegationRunner(
              providerId: 'goose',
              outcomeFactory: (sessionId, turnId) => TurnOutcome(
                sessionId: sessionId,
                turnId: turnId,
                status: TurnStatus.cancelled,
                completedAt: DateTime.utc(2026),
              ),
            ),
          }),
          workspaceDir: '/tmp/ws',
        ),
        'CANCELLED',
      );
      await expectCode(
        DelegateToAgentTool(
          config: delegationConfig(),
          pool: FakeDelegationPool({
            'goose': FakeDelegationRunner(providerId: 'goose')
              ..waitError = const AcpHarnessException(AcpHarnessErrorCode.spawnFailed, 'spawn failed'),
          }),
          workspaceDir: '/tmp/ws',
        ),
        'SPAWN_FAILED',
      );
      await expectCode(
        DelegateToAgentTool(
          config: delegationConfig(),
          pool: FakeDelegationPool({
            'goose': FakeDelegationRunner(providerId: 'goose')
              ..waitError = const AcpHarnessException(AcpHarnessErrorCode.authRequired, 'auth required'),
          }),
          workspaceDir: '/tmp/ws',
        ),
        'ACP_AUTH_REQUIRED',
      );
      await expectCode(
        DelegateToAgentTool(
          config: delegationConfig(),
          pool: FakeDelegationPool({
            'goose': FakeDelegationRunner(
              providerId: 'goose',
              outcomeFactory: (sessionId, turnId) => TurnOutcome(
                sessionId: sessionId,
                turnId: turnId,
                status: TurnStatus.failed,
                errorMessage: 'GUARD denied command',
                completedAt: DateTime.utc(2026),
              ),
            ),
          }),
          workspaceDir: '/tmp/ws',
        ),
        'GUARD_DENIED',
      );
    });

    test('failed and cancelled outcomes are not protocol errors', () async {
      final tool = DelegateToAgentTool(
        config: delegationConfig(),
        pool: FakeDelegationPool({
          'goose': FakeDelegationRunner(
            providerId: 'goose',
            outcomeFactory: (sessionId, turnId) => TurnOutcome(
              sessionId: sessionId,
              turnId: turnId,
              status: TurnStatus.cancelled,
              completedAt: DateTime.utc(2026),
            ),
          ),
        }),
        workspaceDir: '/tmp/ws',
      );

      final result = await tool.call({'agent_id': 'goose', 'task': 'x'});
      expect(result, isA<ToolResultText>());
      expect((await callDelegate(tool, {'agent_id': 'goose', 'task': 'x'}))['status'], 'cancelled');
    });
  });
}

TurnOutcome _zeroUsage(String sessionId, String turnId) => TurnOutcome(
  sessionId: sessionId,
  turnId: turnId,
  status: TurnStatus.completed,
  responseText: 'done',
  completedAt: DateTime.utc(2026),
);
