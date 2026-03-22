import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

// Helpers for config-via-YAML tests
DartclawConfig _loadYaml(String yaml) {
  return DartclawConfig.load(
    fileReader: (path) => path == 'dartclaw.yaml' ? yaml : null,
    env: {'HOME': '/tmp'},
  );
}

void main() {
  group('GovernanceConfig', () {
    test('defaults — all features disabled', () {
      const config = GovernanceConfig.defaults();
      expect(config.adminSenders, isEmpty);
      expect(config.rateLimits.perSender.messages, 0);
      expect(config.rateLimits.perSender.enabled, isFalse);
      expect(config.rateLimits.global.turns, 0);
      expect(config.rateLimits.global.enabled, isFalse);
      expect(config.budget.dailyTokens, 0);
      expect(config.budget.enabled, isFalse);
      expect(config.loopDetection.enabled, isFalse);
    });

    group('isAdmin()', () {
      test('empty admin list — all senders are admins', () {
        const config = GovernanceConfig(adminSenders: []);
        expect(config.isAdmin('alice'), isTrue);
        expect(config.isAdmin('bob'), isTrue);
        expect(config.isAdmin(''), isTrue);
      });

      test('non-empty admin list — only listed senders are admins', () {
        const config = GovernanceConfig(adminSenders: ['alice', 'bob']);
        expect(config.isAdmin('alice'), isTrue);
        expect(config.isAdmin('bob'), isTrue);
        expect(config.isAdmin('charlie'), isFalse);
        expect(config.isAdmin(''), isFalse);
      });
    });

    group('BudgetConfig', () {
      test('enabled when dailyTokens > 0', () {
        const config = BudgetConfig(dailyTokens: 1000);
        expect(config.enabled, isTrue);
      });

      test('disabled when dailyTokens == 0', () {
        const config = BudgetConfig(dailyTokens: 0);
        expect(config.enabled, isFalse);
      });
    });

    group('LoopDetectionConfig', () {
      test('disabled by default', () {
        const config = LoopDetectionConfig.defaults();
        expect(config.enabled, isFalse);
      });

      test('enabled when flag set', () {
        const config = LoopDetectionConfig(enabled: true);
        expect(config.enabled, isTrue);
      });
    });

    group('BudgetAction', () {
      test('fromYaml — known values', () {
        expect(BudgetAction.fromYaml('warn'), BudgetAction.warn);
        expect(BudgetAction.fromYaml('block'), BudgetAction.block);
      });

      test('fromYaml — unknown returns null', () {
        expect(BudgetAction.fromYaml('unknown'), isNull);
        expect(BudgetAction.fromYaml(''), isNull);
      });
    });

    group('LoopAction', () {
      test('fromYaml — known values', () {
        expect(LoopAction.fromYaml('abort'), LoopAction.abort);
        expect(LoopAction.fromYaml('warn'), LoopAction.warn);
      });

      test('fromYaml — unknown returns null', () {
        expect(LoopAction.fromYaml('unknown'), isNull);
      });
    });

    group('YAML duration parsing (governance window fields)', () {
      test('integer minutes parsed directly', () {
        final config = _loadYaml('''
governance:
  rate_limits:
    per_sender:
      messages: 10
      window: 30
''');
        expect(config.governance.rateLimits.perSender.windowMinutes, 30);
      });

      test('minute shorthand — 5m → 5', () {
        final config = _loadYaml('''
governance:
  rate_limits:
    per_sender:
      messages: 5
      window: 5m
''');
        expect(config.governance.rateLimits.perSender.windowMinutes, 5);
      });

      test('hour shorthand — 1h → 60', () {
        final config = _loadYaml('''
governance:
  rate_limits:
    global:
      turns: 100
      window: 1h
''');
        expect(config.governance.rateLimits.global.windowMinutes, 60);
      });

      test('hour shorthand — 2h → 120', () {
        final config = _loadYaml('''
governance:
  rate_limits:
    global:
      turns: 100
      window: 2h
''');
        expect(config.governance.rateLimits.global.windowMinutes, 120);
      });

      test('seconds shorthand — 30s → 0 (rounds down)', () {
        final config = _loadYaml('''
governance:
  rate_limits:
    per_sender:
      messages: 5
      window: 30s
''');
        // 30s rounds down to 0 minutes — accepted for forward compat
        expect(config.governance.rateLimits.perSender.windowMinutes, 0);
      });

      test('missing governance section → all defaults', () {
        final config = _loadYaml('port: 3000\n');
        expect(config.governance.rateLimits.perSender.messages, 0);
        expect(config.governance.rateLimits.global.turns, 0);
        expect(config.governance.budget.dailyTokens, 0);
        expect(config.governance.loopDetection.enabled, isFalse);
      });
    });

    group('equality', () {
      test('two defaults are equal', () {
        expect(const GovernanceConfig.defaults(), equals(const GovernanceConfig.defaults()));
      });

      test('different adminSenders are not equal', () {
        const a = GovernanceConfig(adminSenders: ['alice']);
        const b = GovernanceConfig(adminSenders: ['bob']);
        expect(a, isNot(equals(b)));
      });
    });
  });
}
