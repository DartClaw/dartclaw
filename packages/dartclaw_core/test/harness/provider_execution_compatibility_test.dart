import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

void main() {
  group('ProviderExecutionInventory', () {
    final inventory = ProviderExecutionInventory.of(
      providerIds: const ['claude', 'codex', 'goose'],
      registrarProviderIds: const {'goose'},
    );

    test('built-in providers support host and container execution', () {
      for (final provider in ['claude', 'codex']) {
        for (final policy in [const ExecutionPolicy.host(), const ExecutionPolicy.container('workspace')]) {
          expect(inventory.verdictFor(providerId: provider, policy: policy).isSupported, isTrue);
        }
      }
    });

    test('ACP host execution remains supported', () {
      expect(inventory.verdictFor(providerId: 'goose', policy: const ExecutionPolicy.host()).isSupported, isTrue);
    });

    test('ACP container execution keeps the complete mediation refusal', () {
      final verdict = inventory.verdictFor(providerId: 'goose', policy: const ExecutionPolicy.container('restricted'));

      expect(verdict.reason, ProviderUnavailability.containerMediation);
      expect(
        verdict.message,
        allOf(
          contains('Provider "goose"'),
          contains('container/restricted'),
          contains('harness.acp.agents.goose'),
          contains('provider-credential or host-capability mediation'),
          contains('Select host execution'),
        ),
      );
    });

    test('credential gate is consulted for an otherwise supported combination', () {
      var calls = 0;
      final gated = ProviderExecutionInventory.of(
        providerIds: const ['claude'],
        registrarProviderIds: const {},
        credentialGate: (providerId) {
          calls++;
          return 'credential unavailable for $providerId';
        },
      );

      final verdict = gated.verdictFor(providerId: 'claude', policy: const ExecutionPolicy.host());

      expect(calls, 1);
      expect(verdict.reason, ProviderUnavailability.credential);
      expect(verdict.message, 'credential unavailable for claude');
    });
  });
}
