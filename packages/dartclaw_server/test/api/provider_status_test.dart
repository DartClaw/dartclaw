import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

import '../helpers/probe_helpers.dart';

void main() {
  group('ACP provider status', () {
    test('exposes guard-mediated and container-isolation-only validation classifications', () async {
      const validator = AcpTargetValidator();
      const gooseConfig = AcpAgentConfig(
        binary: 'goose',
        args: ['acp', '--with-builtin', 'developer'],
        topology: AcpAgentTopology.direct,
        modelProvider: 'anthropic',
        verification: 'a0_1_goose_direct',
        requiresGuardMediation: true,
        requiredBuiltins: ['developer'],
      );
      const vibeConfig = AcpAgentConfig(
        binary: 'vibe-acp',
        topology: AcpAgentTopology.relay,
        containerIsolationRequired: true,
        containerProfile: AcpContainerProfile.restricted,
      );
      final validation = await validator.validateConfiguredTargets(
        agents: const {'goose': gooseConfig, 'vibe': vibeConfig},
        commandProbe: (executable, arguments) async => ProcessResult(1, 0, '$executable 1.0.0', ''),
        targetProbe: _guardMediatedProbe,
      );
      final service = ProviderStatusService(
        providers: ProvidersConfig(
          entries: {
            'goose': ProviderEntry(
              executable: 'goose',
              options: {
                'credentials_required': false,
                'acp_validation_result': validation['goose']!.toJson(),
                'acp_validation_owned': true,
              },
            ),
            'vibe': ProviderEntry(
              executable: 'vibe-acp',
              options: {
                'credentials_required': false,
                'acp_validation_result': validation['vibe']!.toJson(),
                'acp_validation_owned': true,
              },
            ),
          },
        ),
        registry: CredentialRegistry(credentials: const CredentialsConfig.defaults()),
        defaultProvider: 'goose',
      );

      await service.probe(
        commandProbe: probeResults({'goose': probeOk('goose 1.0.0'), 'vibe-acp': probeOk('vibe 1.0.0')}),
      );

      final statuses = {for (final status in service.all) status.id: status};

      expect(statuses['goose']!.securityClassification, 'guard_mediated');
      expect(statuses['goose']!.validationEvidence!.first['operation'], 'prompt_response');
      expect(statuses['vibe']!.securityClassification, 'container_isolation_only');
      expect(statuses, isNot(contains('missing_acp_agent')));
    });

    test('ignores forged ACP evidence fields outside validator result payload', () async {
      final service = ProviderStatusService(
        providers: const ProvidersConfig(
          entries: {
            'goose': ProviderEntry(
              executable: 'goose',
              options: {
                'credentials_required': false,
                'acp_validation_result': {
                  'securityClassification': 'guard_mediated',
                  'evidence': [
                    {'operation': 'prompt_response', 'status': 'guard_mediated'},
                  ],
                },
                'security_classification': 'guard_mediated',
                'validation_evidence': [
                  {'operation': 'prompt_response', 'status': 'guard_mediated'},
                ],
              },
            ),
          },
        ),
        registry: CredentialRegistry(credentials: const CredentialsConfig.defaults()),
        defaultProvider: 'goose',
      );

      await service.probe(commandProbe: probeResults({'goose': probeOk('goose 1.0.0')}));

      expect(service.all.single.securityClassification, isNull);
      expect(service.all.single.validationEvidence, isNull);
    });
  });
}

Future<Iterable<AcpTargetOperationEvidence>> _guardMediatedProbe(String providerId, AcpAgentConfig config) async {
  return [
    for (final operation in AcpTargetOperation.values)
      AcpTargetOperationEvidence(
        operation: operation,
        status: AcpTargetEvidenceStatus.guardMediated,
        rawMethod: operation.rawMethod,
      ),
  ];
}
