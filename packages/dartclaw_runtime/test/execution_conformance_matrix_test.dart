import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_acp/dartclaw_acp.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  const providers = ['claude', 'codex', 'goose'];
  const profiles = ['workspace', 'restricted'];
  final inventory = ProviderExecutionInventory.of(providerIds: providers, registrarProviderIds: const {'goose'});

  const runtimeEvidence = <String, (String, String)>{
    'claude/container': (
      'test/integration/container_provider_parity_integration_test.dart',
      'a containerized process joins the container namespace, not the host',
    ),
    'codex/container': (
      'test/integration/container_provider_parity_integration_test.dart',
      'both providers run inside the shipped image',
    ),
    'mediated claude turn': (
      'test/integration/mediated_provider_turn_integration_test.dart',
      'a containerized claude turn writes into the mounted workspace through host mediation',
    ),
    'mediated codex turn': (
      'test/integration/mediated_codex_turn_integration_test.dart',
      'a containerized codex turn writes into the mounted workspace through its auth-clean home',
    ),
  };

  HarnessFactory factoryWithAcp() {
    final factory = HarnessFactory();
    factory.registerAcpAgent(
      'goose',
      const AcpAgentConfig(
        binary: 'goose',
        args: ['acp'],
        topology: AcpAgentTopology.direct,
        modelProvider: 'anthropic',
        verification: 'a0_1_goose_direct',
      ),
    );
    return factory;
  }

  group('advertised combinations run at their real boundary', () {
    for (final providerId in providers) {
      test('$providerId runs on the host with no container authority', () {
        final harness = factoryWithAcp().create(
          providerId,
          const HarnessFactoryConfig(cwd: '/tmp/workspace', executable: '/host/bin/provider'),
        );
        addTearDown(harness.dispose);

        final (ContainerExecutor? container, String executable) = switch (harness) {
          ClaudeCodeHarness() => (harness.containerManager, harness.claudeExecutable),
          CodexHarness() => (harness.containerManager, harness.executable),
          AcpHarness() => (harness.containerManager, harness.executable),
          _ => fail('unexpected harness type for $providerId'),
        };
        expect(container, isNull);
        expect(executable, providerId == 'goose' ? 'goose' : '/host/bin/provider');
      });
    }
  });

  group('required denials', () {
    for (final profile in profiles) {
      test('an ACP provider is refused container/$profile', () {
        final verdict = inventory.verdictFor(providerId: 'goose', policy: ExecutionPolicy.container(profile));
        expect(verdict.reason, ProviderUnavailability.containerMediation);
        expect(verdict.message, contains('harness.acp.agents.goose'));
      });
    }
  });

  group('every advertised combination carries runtime evidence', () {
    late String packageRoot;

    setUpAll(() async {
      final libUri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_runtime/dartclaw_runtime.dart'));
      packageRoot = p.dirname(p.dirname(libUri!.toFilePath()));
    });

    test('the matrix names an observation for every advertised combination', () {
      final advertised = <String>{
        for (final providerId in providers)
          for (final policy in [const ExecutionPolicy.host(), const ExecutionPolicy.container('workspace')])
            if (inventory.verdictFor(providerId: providerId, policy: policy).isSupported)
              '$providerId/${policy.mode.name}',
      };
      final exercisedHere = {for (final providerId in providers) '$providerId/host'};
      expect(advertised.difference(exercisedHere).difference({'claude/container', 'codex/container'}), isEmpty);
    });

    for (final entry in runtimeEvidence.entries) {
      test('${entry.key} is observed by ${entry.value.$2}', () {
        final file = File(p.join(packageRoot, entry.value.$1));
        expect(file.existsSync(), isTrue, reason: '${entry.value.$1} is missing');
        expect(file.readAsStringSync(), contains("test('${entry.value.$2}'"));
      });
    }
  });
}
