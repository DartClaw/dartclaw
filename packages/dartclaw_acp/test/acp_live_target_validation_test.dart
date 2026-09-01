import 'dart:io';

import 'package:dartclaw_acp/dartclaw_acp.dart';
import 'package:test/test.dart';

import 'acp_test_support.dart';

void main() {
  group('live ACP target validation', () {
    test(
      'a guarded Goose is refused for the withdrawn terminal capability, and Vibe passes or skips',
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

        // The contract this probe exists to hold, against the real binaries:
        // Goose's verified profile requires the `terminal` reverse-call
        // capability, DartClaw advertises none (`AcpReverseCallHandlers`
        // reports `terminal: false`, owning no terminals), so a guarded Goose
        // fails validation and is refused at registration. Until S66 the check
        // read a hardcoded capability set and passed on a claim the host could
        // not honour — this asserted `passed or skipped` for both targets and
        // kept doing so afterwards, because the probe is env-gated and never
        // runs in CI.
        expect(result['goose']!.status.id, 'failed');
        expect(result['goose']!.message, contains('terminal'));
        // Vibe requires `fs`, which DartClaw does advertise, so it passes when
        // present and skips when its binary is absent.
        expect(result['vibe']!.status.id, anyOf('passed', 'skipped'));
      },
      tags: 'integration',
      skip: Platform.environment['DARTCLAW_LIVE_ACP_PROBES'] != '1' ? 'set DARTCLAW_LIVE_ACP_PROBES=1' : false,
    );
  });
}

Future<Iterable<AcpTargetOperationEvidence>> _guardMediatedProbe(String providerId, AcpAgentConfig config) async {
  return guardMediatedTargetEvidence();
}
