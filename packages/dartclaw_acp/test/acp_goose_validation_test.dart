import 'package:dartclaw_acp/dartclaw_acp.dart';
import 'package:test/test.dart';

import 'acp_test_support.dart';

void main() {
  group('Goose ACP target validation', () {
    const validator = AcpTargetValidator();

    test('records guard-mediated evidence for direct-provider Goose', () async {
      const config = AcpAgentConfig(
        binary: 'goose',
        args: ['acp', '--with-builtin', 'developer'],
        topology: AcpAgentTopology.direct,
        modelProvider: 'anthropic',
        verification: 'a0_1_goose_direct',
        requiresGuardMediation: true,
        requiredBuiltins: ['developer'],
      );

      expect(
        validator.validateConfig('goose', config, advertisedCapabilities: {'fs'}),
        contains('guarded goose requires advertised terminal capability'),
      );
      expect(validator.validateConfig('goose', config, advertisedCapabilities: {'fs', 'terminal'}), isEmpty);

      final result = (await validator.validateConfiguredTargets(
        agents: {'goose': config},
        commandProbe: presentAcpBinary,
        targetProbe: _guardMediatedProbe,
        advertisedCapabilities: const {
          'goose': {'fs', 'terminal'},
        },
      ))['goose']!;
      expect(result.isGuardMediated, isTrue);
      expect(result.evidence.values.map((evidence) => evidence.status.id), everyElement('guard_mediated'));
    });

    test('rejects missing developer and relay selectors before spawn', () {
      const base = AcpAgentConfig(
        binary: 'goose',
        args: ['acp', '--with-builtin', 'developer'],
        topology: AcpAgentTopology.direct,
        modelProvider: 'anthropic',
        verification: 'a0_1_goose_direct',
        requiresGuardMediation: true,
        requiredBuiltins: ['developer'],
      );

      expect(
        validator.validateConfig(
          'goose',
          const AcpAgentConfig(
            binary: 'goose',
            args: ['acp'],
            topology: AcpAgentTopology.direct,
            modelProvider: 'anthropic',
            verification: 'a0_1_goose_direct',
            requiresGuardMediation: true,
          ),
        ),
        contains('guarded goose requires developer builtin'),
      );
      expect(validator.validateConfig('goose', _withModelProvider(base, 'claude-acp')).join('\n'), contains('relay'));
      expect(validator.validateConfig('goose', _withModelProvider(base, 'codex-acp')).join('\n'), contains('relay'));
    });
  });
}

Future<Iterable<AcpTargetOperationEvidence>> _guardMediatedProbe(String providerId, AcpAgentConfig config) async {
  expect(providerId, 'goose');
  expect(config.args, contains('--with-builtin'));
  return guardMediatedTargetEvidence();
}

AcpAgentConfig _withModelProvider(AcpAgentConfig config, String modelProvider) {
  return AcpAgentConfig(
    binary: config.binary,
    args: config.args,
    topology: config.topology,
    modelProvider: modelProvider,
    verification: config.verification,
    requiresGuardMediation: config.requiresGuardMediation,
    requiredBuiltins: config.requiredBuiltins,
  );
}
