import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

import 'acp_test_support.dart';

void main() {
  group('live ACP target validation', () {
    test(
      'goose and vibe prerequisites skip cleanly when absent',
      () async {
        const validator = AcpTargetValidator();
        const agents = {
          'goose': AcpAgentConfig(
            binary: 'goose',
            args: ['acp', '--with-builtin', 'developer'],
            topology: AcpAgentTopology.direct,
            modelProvider: 'anthropic',
            verification: 'a0_1_goose_direct',
            requiresGuardMediation: true,
            requiredBuiltins: ['developer'],
          ),
          'vibe': AcpAgentConfig(
            binary: 'vibe-acp',
            topology: AcpAgentTopology.direct,
            modelProvider: 'mistral',
            verification: 'vibe_acp_direct_probe',
            requiresGuardMediation: true,
          ),
        };

        final result = await validator.validateConfiguredTargets(
          agents: agents,
          targetProbe: _guardMediatedProbe,
          advertisedCapabilities: const {
            'vibe': {'fs', 'terminal'},
          },
          commandProbe: (executable, arguments) => Process.run(executable, arguments),
        );

        expect(result.keys, containsAll(<String>['goose', 'vibe']));
        expect(result.values.map((target) => target.status.id), everyElement(anyOf('passed', 'skipped')));
      },
      tags: 'integration',
      skip: Platform.environment['DARTCLAW_LIVE_ACP_PROBES'] != '1' ? 'set DARTCLAW_LIVE_ACP_PROBES=1' : false,
    );
  });
}

Future<Iterable<AcpTargetOperationEvidence>> _guardMediatedProbe(String providerId, AcpAgentConfig config) async {
  return guardMediatedTargetEvidence();
}
