import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/mcp/delegate_to_agent_tool.dart';
import 'package:test/test.dart';

import 'delegate_to_agent_test_support.dart';

void main() {
  group('DelegateToAgentTool budget accounting', () {
    test('preflight estimate breach avoids spawn', () async {
      final runner = FakeDelegationRunner(providerId: 'goose');
      final pool = FakeDelegationPool({'goose': runner});
      final tool = DelegateToAgentTool(
        config: delegationConfig(maxBudgetTokens: 50000),
        pool: pool,
        workspaceDir: '/tmp/ws',
        estimateTaskTokens: (_) => 50231,
      );

      final result = await callDelegate(tool, {'agent_id': 'goose', 'task': 'x'});

      expect(result['status'], 'budget_exceeded');
      expect(result['code'], 'BUDGET_EXCEEDED');
      expect(result['usage'], containsPair('budget_tokens', 50231));
      expect(result['usage'], containsPair('budget_limit', 50000));
      expect(pool.acquisitions, isEmpty);
    });

    test('provider-reported strict breach returns budget_exceeded', () async {
      final runner = FakeDelegationRunner(
        providerId: 'goose',
        outcomeFactory: (sessionId, turnId) => TurnOutcome(
          sessionId: sessionId,
          turnId: turnId,
          status: TurnStatus.completed,
          responseText: 'done',
          inputTokens: 50000,
          outputTokens: 231,
          completedAt: DateTime.utc(2026),
        ),
      );
      final tool = DelegateToAgentTool(
        config: delegationConfig(maxBudgetTokens: 50000),
        pool: FakeDelegationPool({'goose': runner}),
        workspaceDir: '/tmp/ws',
      );

      final result = await callDelegate(tool, {'agent_id': 'goose', 'task': 'x'});

      expect(result['status'], 'budget_exceeded');
      expect(result['usage'], containsPair('budget_tokens', 50231));
      expect(result['budget_status'], 'over_budget');
      expect(result['budget_enforcement'], 'strict');
    });

    test('streaming estimate breach cancels the delegated turn before completion result wins', () async {
      final runner = FakeDelegationRunner(providerId: 'goose', waitDelay: const Duration(milliseconds: 20));
      final tool = DelegateToAgentTool(
        config: delegationConfig(
          maxBudgetTokens: 50000,
          budgetAccounting: DelegationBudgetAccounting.estimateIfUnreported,
        ),
        pool: FakeDelegationPool({'goose': runner}),
        workspaceDir: '/tmp/ws',
        strictUsageStream: (_) => Stream<int>.value(50231),
      );

      final result = await callDelegate(tool, {'agent_id': 'goose', 'task': 'x'});

      expect(result['status'], 'budget_exceeded');
      expect(result['code'], 'BUDGET_EXCEEDED');
      expect(result['usage'], containsPair('budget_tokens', 50231));
      expect(result['usage'], containsPair('source', 'stream_estimated'));
      expect(runner.cancelCount, 1);
    });

    test('strict non-reporting agents fail closed unless post-run accounting is allowed', () async {
      final strictTool = DelegateToAgentTool(
        config: delegationConfig(maxBudgetTokens: 50000),
        pool: FakeDelegationPool({'goose': FakeDelegationRunner(providerId: 'goose')..outcomeFactory = _zeroUsage}),
        workspaceDir: '/tmp/ws',
      );
      expect((await callDelegate(strictTool, {'agent_id': 'goose', 'task': 'x'}))['code'], 'BUDGET_USAGE_UNAVAILABLE');

      final postRunTool = DelegateToAgentTool(
        config: delegationConfig(
          agents: const [DelegationAgentConfig(id: 'goose', requireGuardMediation: true, postRunAccountingOnly: true)],
          maxBudgetTokens: 50000,
        ),
        pool: FakeDelegationPool({
          'goose': FakeDelegationRunner(
            providerId: 'goose',
            outcomeFactory: (sessionId, turnId) => TurnOutcome(
              sessionId: sessionId,
              turnId: turnId,
              status: TurnStatus.completed,
              responseText: 'done',
              inputTokens: 50000,
              outputTokens: 231,
              completedAt: DateTime.utc(2026),
            ),
          ),
        }),
        workspaceDir: '/tmp/ws',
      );
      final postRun = await callDelegate(postRunTool, {'agent_id': 'goose', 'task': 'x'});
      expect(postRun['status'], 'completed');
      expect(postRun['usage'], containsPair('source', 'post_run_estimated'));
      expect(postRun['budget_status'], 'over_budget');
      expect(postRun['budget_enforcement'], 'post_run');
    });

    test('post-run accounting with unavailable usage reports unknown budget status', () async {
      final tool = DelegateToAgentTool(
        config: delegationConfig(
          agents: const [DelegationAgentConfig(id: 'goose', requireGuardMediation: true, postRunAccountingOnly: true)],
          maxBudgetTokens: 50000,
        ),
        pool: FakeDelegationPool({'goose': FakeDelegationRunner(providerId: 'goose')..outcomeFactory = _zeroUsage}),
        workspaceDir: '/tmp/ws',
      );

      final result = await callDelegate(tool, {'agent_id': 'goose', 'task': 'x'});

      expect(result['status'], 'completed');
      expect(result['usage'], containsPair('source', 'unknown'));
      expect(result['budget_status'], 'unknown');
      expect(result['budget_enforcement'], 'post_run');
    });

    test('estimate_if_unreported still fails closed without usage visibility', () async {
      final strictTool = DelegateToAgentTool(
        config: delegationConfig(
          maxBudgetTokens: 50000,
          budgetAccounting: DelegationBudgetAccounting.estimateIfUnreported,
        ),
        pool: FakeDelegationPool({'goose': FakeDelegationRunner(providerId: 'goose')..outcomeFactory = _zeroUsage}),
        workspaceDir: '/tmp/ws',
      );

      final result = await callDelegate(strictTool, {'agent_id': 'goose', 'task': 'x'});

      expect(result['status'], 'error');
      expect(result['code'], 'BUDGET_USAGE_UNAVAILABLE');
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
