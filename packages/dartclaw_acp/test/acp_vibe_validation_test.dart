import 'package:dartclaw_acp/dartclaw_acp.dart';
import 'package:test/test.dart';

import 'acp_test_support.dart';

void main() {
  group('Vibe ACP target validation', () {
    const validator = AcpTargetValidator();

    test('records guard-mediated evidence for direct-provider Vibe with advertised capabilities', () async {
      const config = AcpAgentConfig(
        binary: 'vibe-acp',
        topology: AcpAgentTopology.direct,
        modelProvider: 'mistral',
        verification: 'vibe_acp_direct_probe',
        requiresGuardMediation: true,
      );

      expect(validator.validateConfig('vibe', config, advertisedCapabilities: {'fs'}), isEmpty);
      final result = (await validator.validateConfiguredTargets(
        agents: {'vibe': config},
        commandProbe: presentAcpBinary,
        targetProbe: _guardMediatedProbe,
        advertisedCapabilities: const {
          'vibe': {'fs', 'terminal'},
        },
      ))['vibe']!;
      expect(result.isGuardMediated, isTrue);
    });

    test('requires capability advertisement and proof before guarded Vibe can pass', () {
      const config = AcpAgentConfig(
        binary: 'vibe-acp',
        topology: AcpAgentTopology.direct,
        modelProvider: 'mistral',
        verification: 'vibe_acp_direct_probe',
        requiresGuardMediation: true,
      );
      const noProof = AcpAgentConfig(
        binary: 'vibe-acp',
        topology: AcpAgentTopology.direct,
        modelProvider: 'mistral',
        requiresGuardMediation: true,
      );

      expect(validator.validateConfig('vibe', config), contains('guarded vibe requires advertised fs capability'));
      expect(
        validator.validateConfig('vibe', noProof, advertisedCapabilities: {'fs', 'terminal'}),
        contains('requires_guard_mediation requires verification'),
      );
      expect(AcpTargetValidationResult.hostOnly('vibe').isGuardMediated, isFalse);
    });
  });
}

Future<Iterable<AcpTargetOperationEvidence>> _guardMediatedProbe(String providerId, AcpAgentConfig config) async {
  expect(providerId, 'vibe');
  expect(config.verification, 'vibe_acp_direct_probe');
  return guardMediatedTargetEvidence();
}
