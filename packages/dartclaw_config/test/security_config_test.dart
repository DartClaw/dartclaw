import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:test/test.dart';

import 'support/load_config.dart';

void main() {
  group('guard_audit config', () {
    test('guard_audit.max_retention_days defaults to 30 when unset', () {
      final config = loadNoFile();
      expect(config.security.guardAuditMaxRetentionDays, 30);
    });

    test('guard_audit.max_entries is ignored with deprecation warning when configured', () {
      final config = loadYaml('guard_audit:\n  max_entries: 25000\n');
      expect(config.warnings, anyElement(contains('guard_audit.max_entries is deprecated and ignored')));
    });

    test('guard_audit.max_retention_days parses when configured', () {
      final config = loadYaml('guard_audit:\n  max_retention_days: 7\n');
      expect(config.security.guardAuditMaxRetentionDays, 7);
    });

    test('guard_audit.max_retention_days is clamped to 0..365', () {
      final low = loadYaml('guard_audit:\n  max_retention_days: -5\n');
      final high = loadYaml('guard_audit:\n  max_retention_days: 999\n');
      expect(low.security.guardAuditMaxRetentionDays, 0);
      expect(high.security.guardAuditMaxRetentionDays, 365);
    });

    test('guard_audit.max_entries invalid type is ignored with deprecation warning', () {
      final config = loadYaml('guard_audit:\n  max_entries: nope\n');
      expect(config.warnings, anyElement(contains('guard_audit.max_entries is deprecated and ignored')));
    });
  });

  group('guards config', () {
    test('missing guards section uses GuardConfig.defaults()', () {
      final config = loadNoFile();
      expect(config.security.guards.failOpen, isFalse);
      expect(config.security.guards.enabled, isTrue);
    });

    test('guards: {fail_open: true} parsed correctly', () {
      final config = loadYaml('guards:\n  fail_open: true\n');
      expect(config.security.guards.failOpen, isTrue);
      expect(config.security.guards.enabled, isTrue);
      expect(config.warnings, isEmpty);
    });

    test('guards: {enabled: false} parsed correctly', () {
      final config = loadYaml('guards:\n  enabled: false\n');
      expect(config.security.guards.enabled, isFalse);
    });

    test('guards: {unknown_key: x} produces warning, defaults used', () {
      final config = loadYaml('guards:\n  unknown_key: x\n');
      expect(config.security.guards.failOpen, isFalse);
      expect(config.warnings, anyElement(contains('Unknown guards config key')));
    });

    test('guards: non-map type produces warning, defaults used', () {
      final config = loadYaml('guards: true\n');
      expect(config.security.guards.failOpen, isFalse);
      expect(config.warnings, anyElement(contains('Invalid type for guards')));
    });
  });

  group('security.bash_step config', () {
    test('security.bash_step.env_allowlist extends defaults', () {
      final config = loadYaml('security:\n  bash_step:\n    env_allowlist:\n      - CUSTOM_ALLOWED\n');
      expect(config.security.bashStep.envAllowlist, containsAll(['PATH', 'HOME', 'CUSTOM_ALLOWED']));
    });

    test('invalid security.bash_step.env_allowlist type warns and uses defaults', () {
      final config = loadYaml('security:\n  bash_step:\n    env_allowlist: true\n');
      expect(config.security.bashStep.envAllowlist, defaultBashStepEnvAllowlist);
      expect(config.warnings, anyElement(contains('Invalid type for env_allowlist')));
    });

    test('security.bash_step.extra_strip_patterns parses as additive list', () {
      final config = loadYaml('security:\n  bash_step:\n    extra_strip_patterns:\n      - CUSTOM_FLAG\n');
      expect(config.security.bashStep.extraStripPatterns, ['CUSTOM_FLAG']);
    });
  });
}
