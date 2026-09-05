import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

import 'support/load_config.dart';

void main() {
  group('guard_audit config', () {
    test('guard_audit.max_retention_days defaults to 30 when unset', () {
      final config = loadNoFile();
      expect(config.security.guardAuditMaxRetentionDays, 30);
    });

    test('guard_audit.max_entries no longer reaches the parser, and the accept-set names its replacement', () {
      final config = loadYaml('guard_audit:\n  max_entries: 25000\n');
      expect(config.security.guardAuditMaxRetentionDays, 30);
      expect(config.warnings, [ConfigMeta.toleratedLegacyKeys['guard_audit.max_entries']!.replacement]);
      expect(config.warnings.single, contains('guard_audit.max_retention_days'));
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

    test('an excessive max_retention_days saturates without an advisory', () {
      final config = loadYaml('guard_audit:\n  max_retention_days: 999\n');

      expect(config.security.guardAuditMaxRetentionDays, 365);
      expect(config.warnings.where((warning) => warning.contains('guard_audit.max_retention_days')), isEmpty);
    });

    test('guard_audit.max_entries of any type leaves max_retention_days alone', () {
      final config = loadYaml('guard_audit:\n  max_entries: nope\n  max_retention_days: 7\n');
      expect(config.security.guardAuditMaxRetentionDays, 7);
      expect(config.warnings, [ConfigMeta.toleratedLegacyKeys['guard_audit.max_entries']!.replacement]);
    });
  });

  group('guards config', () {
    test('guards.content.fail_open defaults to false', () {
      // The default classifier used to force fail-open with no key and no log,
      // so an unscorable payload reached the agent on a stock install.
      final config = loadNoFile();
      expect(config.security.contentGuardFailOpen, isFalse);
    });

    test('guards.content.fail_open parses when configured', () {
      final config = loadYaml('guards:\n  content:\n    fail_open: true\n');
      expect(config.security.contentGuardFailOpen, isTrue);
      expect(config.warnings, isEmpty);
    });

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

    test('guards: {unknown_key: x} refuses the load', () {
      // The guards vocabulary is closed, so an undescribed guards key is a typo
      // on a security surface rather than a deployer extension point.
      expect(
        () => loadYaml('guards:\n  unknown_key: x\n'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains("'guards.unknown_key'"))),
      );
    });

    test('guards.input_sanitizer is tolerated with its replacement named and parses to no field', () {
      final config = loadYaml('guards:\n  input_sanitizer:\n    enabled: false\n');
      expect(config.warnings, anyElement(contains('Ignoring guards.input_sanitizer: Removed regex injection guard')));
      expect(config.reloadBlockingWarnings, isEmpty, reason: 'a tolerated key is an advisory, not a blocker');
      expect(config.security.guardsYaml.containsKey('input_sanitizer'), isTrue, reason: 'raw YAML is preserved');
      expect(SecurityConfig.defaults(), config.security.copyWith(guardsYaml: const {}));
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
