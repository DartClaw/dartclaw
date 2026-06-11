import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

import 'support/load_config.dart';

void main() {
  group('ACP target validation', () {
    test('verified target profiles', () {
      const goose = AcpVerifiedTargetProfile.goose;
      const vibe = AcpVerifiedTargetProfile.vibe;

      expect(goose.providerId, 'goose');
      expect(goose.binary, 'goose');
      expect(goose.args, ['acp', '--with-builtin', 'developer']);
      expect(goose.requiredBuiltins, ['developer']);
      expect(goose.knownRelaySelectors, containsAll(<String>['claude-acp', 'codex-acp']));

      expect(vibe.providerId, 'vibe');
      expect(vibe.binary, 'vibe-acp');
      expect(vibe.modelProvider, 'mistral');
      expect(vibe.verification, 'vibe_acp_direct_probe');
    });

    test('classification failures', () {
      final cases = [
        '''
harness:
  acp:
    agents:
      goose:
        binary: goose
        topology: direct
        model_provider: anthropic
        requires_guard_mediation: true
        required_builtins: ["developer"]
''',
        '''
harness:
  acp:
    agents:
      goose:
        binary: goose
        topology: direct
        model_provider: anthropic
        verification: a0_1_goose_direct
        requires_guard_mediation: true
''',
        '''
harness:
  acp:
    agents:
      goose:
        binary: goose
        args: ["acp", "--with-builtin", "developer"]
        topology: direct
        model_provider: claude-acp
        verification: a0_1_goose_direct
        requires_guard_mediation: true
        required_builtins: ["developer"]
''',
        '''
harness:
  acp:
    agents:
      goose:
        binary: goose
        args: ["acp", "--with-builtin", "developer"]
        topology: direct
        model_provider: codex-acp
        verification: a0_1_goose_direct
        requires_guard_mediation: true
        required_builtins: ["developer"]
''',
        '''
harness:
  acp:
    agents:
      vibe:
        binary: vibe-acp
        topology: direct
        model_provider: mistral
        requires_guard_mediation: true
''',
      ];

      for (final yaml in cases) {
        final config = loadYaml(yaml);
        expect(config.harness.acp.isEmpty, isTrue);
      }

      final relay = loadYaml('''
harness:
  acp:
    agents:
      goose:
        binary: goose
        topology: relay
        container_isolation_required: true
        container_profile: restricted
      vibe:
        binary: vibe-acp
        topology: unverified
        container_isolation_required: true
        container_profile: workspace
''');

      expect(relay.harness.acp['goose']!.securityClassification, AcpSecurityClassification.containerIsolationOnly);
      expect(relay.harness.acp['vibe']!.securityClassification, AcpSecurityClassification.containerIsolationOnly);
      expect(relay.harness.acp['goose']!.containerProfile, AcpContainerProfile.restricted);
      expect(relay.harness.acp['vibe']!.containerProfile, AcpContainerProfile.workspace);
    });
  });
}
