import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

/// Every combination in the release matrix, with the boundary each one is
/// advertised to enforce. Cases are enumerated rather than derived so a
/// silently dropped combination fails the coverage assertion below.
const _matrix = <({String provider, ProviderLaunchSurface surface, ExecutionPolicy policy, bool supported})>[
  (provider: 'claude', surface: ProviderLaunchSurface.longLived, policy: ExecutionPolicy.host(), supported: true),
  (
    provider: 'claude',
    surface: ProviderLaunchSurface.longLived,
    policy: ExecutionPolicy.container('workspace'),
    supported: true,
  ),
  (provider: 'claude', surface: ProviderLaunchSurface.workflowOneShot, policy: ExecutionPolicy.host(), supported: true),
  (
    provider: 'claude',
    surface: ProviderLaunchSurface.workflowOneShot,
    policy: ExecutionPolicy.container('restricted'),
    supported: true,
  ),
  (provider: 'codex', surface: ProviderLaunchSurface.longLived, policy: ExecutionPolicy.host(), supported: true),
  (
    provider: 'codex',
    surface: ProviderLaunchSurface.longLived,
    policy: ExecutionPolicy.container('restricted'),
    supported: true,
  ),
  (provider: 'codex', surface: ProviderLaunchSurface.workflowOneShot, policy: ExecutionPolicy.host(), supported: true),
  (
    provider: 'codex',
    surface: ProviderLaunchSurface.workflowOneShot,
    policy: ExecutionPolicy.container('workspace'),
    supported: true,
  ),
  (provider: 'goose', surface: ProviderLaunchSurface.longLived, policy: ExecutionPolicy.host(), supported: true),
  (
    provider: 'goose',
    surface: ProviderLaunchSurface.longLived,
    policy: ExecutionPolicy.container('workspace'),
    supported: false,
  ),
  (
    provider: 'goose',
    surface: ProviderLaunchSurface.longLived,
    policy: ExecutionPolicy.container('restricted'),
    supported: false,
  ),
  (provider: 'goose', surface: ProviderLaunchSurface.workflowOneShot, policy: ExecutionPolicy.host(), supported: false),
  (
    provider: 'goose',
    surface: ProviderLaunchSurface.workflowOneShot,
    policy: ExecutionPolicy.container('workspace'),
    supported: false,
  ),
];

void main() {
  final inventory = ProviderExecutionInventory.of(
    providerIds: const ['claude', 'codex', 'goose'],
    acpProviderIds: const {'goose'},
  );

  group('computed provider execution compatibility', () {
    for (final entry in _matrix) {
      test('${entry.provider} on the ${entry.surface.label} surface as ${entry.policy.describe()}', () {
        final verdict = inventory.verdictFor(providerId: entry.provider, surface: entry.surface, policy: entry.policy);

        expect(verdict.isSupported, entry.supported, reason: verdict.message);
        if (entry.supported) {
          expect(verdict.reason, isNull);
          return;
        }
        expect(verdict.message, contains('"${entry.provider}"'));
        expect(
          verdict.reason,
          entry.surface == ProviderLaunchSurface.workflowOneShot
              ? ProviderUnavailability.surface
              : ProviderUnavailability.containerMediation,
        );
      });
    }

    test('every provider and surface in the release matrix is covered', () {
      final covered = {for (final entry in _matrix) '${entry.provider}/${entry.surface.name}'};

      expect(covered, {
        for (final provider in ['claude', 'codex', 'goose'])
          for (final surface in ProviderLaunchSurface.values) '$provider/${surface.name}',
      });
    });

    test('an ACP container rejection names the registration path, the missing mechanism, and the remediation', () {
      final verdict = inventory.verdictFor(
        providerId: 'goose',
        surface: ProviderLaunchSurface.longLived,
        policy: const ExecutionPolicy.container('restricted'),
      );

      expect(verdict.message, contains('container/restricted'));
      expect(verdict.message, contains('harness.acp.agents.goose'));
      expect(verdict.message, contains('provider-credential or host-capability mediation for an ACP client'));
      expect(verdict.message, contains('agent.execution'));
      expect(verdict.message, contains('tasks.execution.<task-type>'));
    });

    test('an unsupported surface reports the same verdict wherever it is computed', () {
      final fromInventory = inventory.verdictFor(
        providerId: 'goose',
        surface: ProviderLaunchSurface.workflowOneShot,
        policy: const ExecutionPolicy.host(),
      );
      final fromSurface = ProviderExecutionVerdict.unsupportedSurface(
        providerId: 'goose',
        surface: ProviderLaunchSurface.workflowOneShot,
      );

      expect(fromInventory.message, fromSurface.message);
      expect(fromInventory.reason, fromSurface.reason);
    });

    test('an unregistered provider identity is left to harness construction', () {
      final verdict = inventory.verdictFor(
        providerId: 'not-configured',
        surface: ProviderLaunchSurface.longLived,
        policy: const ExecutionPolicy.container('workspace'),
      );

      expect(verdict.isSupported, isTrue);
    });

    test('an alias resolving to no built-in family earns no mediation claim', () {
      // Recording it as built-in would assert container mediation for an
      // adapter the inventory cannot name; harness construction rejects the
      // identity instead.
      final withAlias = ProviderExecutionInventory.of(
        providerIds: const ['claude', 'mytool'],
        acpProviderIds: const {},
      );

      expect(withAlias.supports.keys, ['claude']);
    });
  });

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
          support
              .verdictFor(
                surface: ProviderLaunchSurface.longLived,
                policy: const ExecutionPolicy.container('workspace'),
              )
              .reason,
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
