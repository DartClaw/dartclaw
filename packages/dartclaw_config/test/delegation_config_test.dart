import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

import 'support/load_config.dart';

void main() {
  group('DelegationConfig', () {
    test('defaults disabled with empty allowlist', () {
      final config = loadNoFile();

      expect(config.delegation.enabled, isFalse);
      expect(config.delegation.agents, isEmpty);
      expect(config.delegation.maxBudgetTokens, 0);
      expect(config.delegation.budgetAccounting, DelegationBudgetAccounting.providerReported);
      expect(config.delegation.rateLimit.maxPerMinute, 0);
    });

    test('parses allowlist, budget accounting, and rate limit', () {
      final config = loadYaml('''
delegation:
  enabled: true
  agents:
    - id: goose
      require_guard_mediation: true
      post_run_accounting_only: false
    - id: codex
      require_guard_mediation: false
      post_run_accounting_only: true
  max_budget_tokens: 50000
  budget_accounting: estimate_if_unreported
  rate_limit:
    max_per_minute: 6
''');

      expect(config.delegation.enabled, isTrue);
      expect(config.delegation.agent('goose')?.requireGuardMediation, isTrue);
      expect(config.delegation.agent('codex')?.postRunAccountingOnly, isTrue);
      expect(config.delegation.maxBudgetTokens, 50000);
      expect(config.delegation.budgetAccounting, DelegationBudgetAccounting.estimateIfUnreported);
      expect(config.delegation.rateLimit.maxPerMinute, 6);
    });

    test('invalid enum and negative limits fall back safely', () {
      final config = loadYaml('''
delegation:
  max_budget_tokens: -1
  budget_accounting: nope
  rate_limit:
    max_per_minute: -6
''');

      expect(config.delegation.maxBudgetTokens, 0);
      expect(config.delegation.budgetAccounting, DelegationBudgetAccounting.providerReported);
      expect(config.delegation.rateLimit.maxPerMinute, 0);
      expect(config.warnings, contains(contains('Invalid delegation.budget_accounting')));
    });

    test('duplicate allowlist IDs fail closed for that ID', () {
      final config = loadYaml('''
delegation:
  enabled: true
  agents:
    - id: goose
      require_guard_mediation: false
    - id: goose
      require_guard_mediation: true
      post_run_accounting_only: true
''');

      expect(config.delegation.agent('goose'), isNull);
      expect(config.delegation.agents, isEmpty);
      expect(config.warnings, contains(contains('Duplicate delegation.agents id "goose"')));
    });

    test('equality includes delegation section values', () {
      const a = DelegationConfig(
        enabled: true,
        agents: [DelegationAgentConfig(id: 'goose', requireGuardMediation: true)],
        maxBudgetTokens: 50000,
        budgetAccounting: DelegationBudgetAccounting.estimateIfUnreported,
        rateLimit: DelegationRateLimitConfig(maxPerMinute: 6),
      );
      const b = DelegationConfig(
        enabled: true,
        agents: [DelegationAgentConfig(id: 'goose', requireGuardMediation: true)],
        maxBudgetTokens: 50000,
        budgetAccounting: DelegationBudgetAccounting.estimateIfUnreported,
        rateLimit: DelegationRateLimitConfig(maxPerMinute: 6),
      );
      const c = DelegationConfig(enabled: true, agents: [DelegationAgentConfig(id: 'codex')]);

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });
  });
}
