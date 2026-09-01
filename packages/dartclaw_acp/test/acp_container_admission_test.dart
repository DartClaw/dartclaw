import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_acp/dartclaw_acp.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('no ACP registration field grants container support', () {
    const registrations = <String, AcpAgentConfig>{
      'declared direct and guard-mediated': AcpAgentConfig(
        binary: 'goose',
        topology: AcpAgentTopology.direct,
        modelProvider: 'anthropic',
        verification: 'a0_1_goose_direct',
        requiresGuardMediation: true,
      ),
      'declaring the workspace profile': AcpAgentConfig(
        binary: 'goose',
        topology: AcpAgentTopology.direct,
        containerProfile: AcpContainerProfile.workspace,
      ),
      'declaring the restricted profile': AcpAgentConfig(
        binary: 'goose',
        topology: AcpAgentTopology.direct,
        containerProfile: AcpContainerProfile.restricted,
      ),
      'unverified': AcpAgentConfig(binary: 'goose'),
    };

    for (final entry in registrations.entries) {
      test('a registration ${entry.key} still cannot run in a container', () {
        final support = ProviderExecutionSupport.acp('goose');

        expect(
          support.verdictFor(policy: const ExecutionPolicy.container('workspace')).reason,
          ProviderUnavailability.containerMediation,
        );
        // The registration itself is only ever a startup-fatal input; it never
        // widens the computed compatibility above.
        final runnable = entry.value.topology == AcpAgentTopology.direct && !entry.value.containerIsolationRequired;
        expect(acpContainerRequirementError('goose', entry.value), runnable ? isNull : isNotNull);
      });
    }
  });

  group('container-required ACP registrations have no runnable execution', () {
    test('a relay registration is rejected with its exact configuration path', () {
      final error = acpContainerRequirementError(
        'relay-agent',
        const AcpAgentConfig(
          binary: 'goose',
          topology: AcpAgentTopology.relay,
          containerIsolationRequired: true,
          containerProfile: AcpContainerProfile.restricted,
        ),
      );

      expect(error, isNotNull);
      expect(error, contains('harness.acp.agents.relay-agent.topology'));
      expect(error, contains('provider-credential or host-capability mediation for an ACP client'));
      expect(error, contains('topology: direct'));
    });

    test('a direct registration that opts into a container is rejected the same way', () {
      final error = acpContainerRequirementError(
        'goose',
        const AcpAgentConfig(
          binary: 'goose',
          topology: AcpAgentTopology.direct,
          modelProvider: 'anthropic',
          verification: 'a0_1_goose_direct',
          containerIsolationRequired: true,
        ),
      );

      expect(error, contains('harness.acp.agents.goose.container_isolation_required'));
    });

    test('a host-only direct registration is accepted', () {
      expect(
        acpContainerRequirementError('goose', const AcpAgentConfig(binary: 'goose', topology: AcpAgentTopology.direct)),
        isNull,
      );
    });

    test('a relay topology is rejected even without the container flag', () {
      // YAML validation couples relay/unverified to container_isolation_required,
      // but a programmatically built registration must not bypass the rule.
      expect(
        acpContainerRequirementError('goose', const AcpAgentConfig(binary: 'goose', topology: AcpAgentTopology.relay)),
        contains('harness.acp.agents.goose.topology'),
      );
      expect(
        acpContainerRequirementError('goose', const AcpAgentConfig(binary: 'goose')),
        isNotNull,
        reason: 'an omitted topology defaults to unverified',
      );
    });
  });
}
