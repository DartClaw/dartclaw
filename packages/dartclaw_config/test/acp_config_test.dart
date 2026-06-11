import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

import 'support/load_config.dart';

void main() {
  group('ACP harness config', () {
    test('parses a guarded direct ACP agent without provider capacity coupling', () {
      final config = loadYaml('''
harness:
  acp:
    agents:
      goose:
        binary: goose
        args: ["acp", "--with-builtin", "developer"]
        topology: direct
        model_provider: anthropic
        verification: a0_1_goose_direct
        requires_guard_mediation: true
        required_builtins: ["developer"]
        container_isolation_required: false
providers:
  goose:
    executable: goose
    pool_size: 2
''');

      final goose = config.harness.acp['goose'];

      expect(goose, isNotNull);
      expect(goose!.binary, 'goose');
      expect(goose.args, ['acp', '--with-builtin', 'developer']);
      expect(goose.topology, AcpAgentTopology.direct);
      expect(goose.modelProvider, 'anthropic');
      expect(goose.verification, 'a0_1_goose_direct');
      expect(goose.requiresGuardMediation, isTrue);
      expect(goose.requiredBuiltins, ['developer']);
      expect(goose.containerIsolationRequired, isFalse);
      expect(goose.securityClassification, AcpSecurityClassification.guardMediated);
      expect(config.providers['goose']!.poolSize, 2);
      expect(config.warnings, isEmpty);
    });

    test('skips missing binary without creating an agent', () {
      final config = loadYaml('''
harness:
  acp:
    agents:
      goose:
        args: ["acp"]
''');

      expect(config.harness.acp.isEmpty, isTrue);
      expect(config.warnings, anyElement(contains('harness.acp.agents.goose missing "binary"')));
    });

    test('rejects guarded relay and unverified configs before spawn', () {
      for (final topology in ['relay', 'unverified']) {
        final config = loadYaml('''
harness:
  acp:
    agents:
      goose:
        binary: goose
        args: ["acp", "--with-builtin", "developer"]
        topology: $topology
        model_provider: anthropic
        verification: evidence
        requires_guard_mediation: true
        required_builtins: ["developer"]
''');

        expect(config.harness.acp.isEmpty, isTrue);
        expect(config.warnings, anyElement(contains('requires_guard_mediation requires topology "direct"')));
      }
    });

    test('rejects guarded configs missing verification developer builtin or using relay selectors', () {
      final cases = {
        'missing verification': '''
harness:
  acp:
    agents:
      goose:
        binary: goose
        args: ["acp", "--with-builtin", "developer"]
        topology: direct
        model_provider: anthropic
        requires_guard_mediation: true
''',
        'missing developer': '''
harness:
  acp:
    agents:
      goose:
        binary: goose
        args: ["acp"]
        topology: direct
        model_provider: anthropic
        verification: evidence
        requires_guard_mediation: true
''',
        'claude-acp relay': '''
harness:
  acp:
    agents:
      goose:
        binary: goose
        args: ["acp", "--with-builtin", "developer"]
        topology: direct
        model_provider: claude-acp
        verification: evidence
        requires_guard_mediation: true
        required_builtins: ["developer"]
''',
        'codex-acp relay': '''
harness:
  acp:
    agents:
      goose:
        binary: goose
        args: ["acp", "--with-builtin", "developer"]
        topology: direct
        model_provider: codex-acp
        verification: evidence
        requires_guard_mediation: true
        required_builtins: ["developer"]
''',
      };

      for (final yaml in cases.values) {
        final config = loadYaml(yaml);
        expect(config.harness.acp.isEmpty, isTrue);
      }
    });

    test('requires container isolation metadata for unguarded relay and unverified configs', () {
      final rejected = loadYaml('''
harness:
  acp:
    agents:
      goose:
        binary: goose
        topology: relay
''');
      final accepted = loadYaml('''
harness:
  acp:
    agents:
      goose:
        binary: goose
        topology: unverified
        container_isolation_required: true
        container_profile: restricted
      vibe:
        binary: vibe-acp
        topology: relay
        container_isolation_required: true
        container_profile: workspace
''');

      expect(rejected.harness.acp.isEmpty, isTrue);
      expect(rejected.warnings, anyElement(contains('container_isolation_required: true')));
      expect(accepted.harness.acp['goose']!.containerProfile, AcpContainerProfile.restricted);
      expect(accepted.harness.acp['vibe']!.containerProfile, AcpContainerProfile.workspace);
      expect(accepted.harness.acp['goose']!.securityClassification, AcpSecurityClassification.containerIsolationOnly);
      expect(accepted.warnings, isEmpty);
    });
  });
}
