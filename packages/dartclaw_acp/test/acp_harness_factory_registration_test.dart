import 'dart:io';

import 'package:dartclaw_acp/dartclaw_acp.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

import 'support/load_config.dart';

final class _FakeContainerExecutor implements ContainerExecutor {
  @override
  final String profileId = 'workspace';

  @override
  final String workingDir = '/project';

  @override
  final bool hasProjectMount = true;

  @override
  final String generatedStateDir = '/host/state';

  @override
  final String providerBridgeUrl = 'http://127.0.0.1:8080';

  @override
  final String? mcpBridgeUrl = null;

  const new();

  @override
  String? containerPathForHostPath(String hostPath) => hostPath;

  @override
  Future<Process> exec(List<String> command, {Map<String, String>? env, String? workingDirectory}) {
    throw UnimplementedError();
  }

  @override
  Future<void> start() async {}
}

void main() {
  group('ACP registration on the harness factory', () {
    test('registered ACP agents receive guard, permission, and audit seams', () async {
      final factory = HarnessFactory();
      final guardChain = GuardChain(guards: const []);
      void audit(AcpReverseCallAuditEvent event) {}

      factory.registerAcpAgent(
        'goose-direct',
        const AcpAgentConfig(binary: 'goose', args: ['acp'], containerIsolationRequired: false),
        reverseCallAudit: audit,
      );

      final harness = factory.create(
        'goose-direct',
        HarnessFactoryConfig(cwd: '/tmp/workspace', guardChain: guardChain),
      ) as AcpHarness;

      expect(harness.guardChain, same(guardChain));
      expect(harness.onReverseCallAudit, same(audit));
      // The decision is derived from this runner's own chain rather than handed
      // in, so per-runner tool policy cannot be bypassed by the seam.
      final decision = harness.permissionDecision;
      expect(decision, isNotNull);
      final verdict = await decision!(
        const AcpPermissionRequest(operation: 'shell', params: {}, sessionId: 's', agentId: 'a'),
      );
      expect(verdict.granted, isTrue);
    });

    test('a registration built without a guard chain derives no permission decision', () {
      final factory = HarnessFactory();
      factory.registerAcpAgent('goose-direct', const AcpAgentConfig(binary: 'goose', args: ['acp']));

      final harness = factory.create('goose-direct', const HarnessFactoryConfig(cwd: '/tmp/workspace')) as AcpHarness;

      expect(harness.permissionDecision, isNull);
    });

    for (final providerId in const ['claude', 'codex']) {
      test('an ACP registration named $providerId replaces the built-in factory and keeps its first claim', () {
        final factory = HarnessFactory();
        factory.registerAcpAgent(providerId, const AcpAgentConfig(binary: 'first-acp', args: ['serve']));
        factory.registerAcpAgent(providerId, const AcpAgentConfig(binary: 'second-acp'));

        final harness = factory.create(providerId, const HarnessFactoryConfig(cwd: '/tmp/workspace')) as AcpHarness;

        expect(harness.executable, 'first-acp');
        expect(harness.arguments, ['serve']);
      });
    }

    test('the registrar rejects configured collisions with built-in provider IDs', () {
      final config = DartclawConfig(
        harness: HarnessConfig(
          sections: {
            'acp': {
              'agents': {
                'claude': {'binary': Platform.resolvedExecutable, 'topology': 'direct'},
              },
            },
          },
        ),
      );

      expect(
        () => const AcpHarnessRegistrar().declare(config),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Invalid harness.acp.agents.claude: provider ID is built in',
          ),
        ),
      );
    });

    test('registrar refuses a guarded profile requiring withdrawn terminal capability', () async {
      final config = loadYaml('''
harness:
  acp:
    agents:
      goose:
        binary: goose
        args: ["acp", "--with-builtin", "developer"]
        topology: direct
        model_provider: anthropic
        verification: a0_1_goose_direct
        requires_guard_mediation: true
        required_builtins: ["developer"]
''');

      await expectLater(
        const AcpHarnessRegistrar().activate(config, HarnessFactory()),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('guarded goose requires advertised terminal capability'),
          ),
        ),
      );
      expect(
        const AcpTargetValidator().validateConfig(
          'vibe',
          const AcpAgentConfig(
            binary: 'vibe-acp',
            topology: AcpAgentTopology.direct,
            modelProvider: 'mistral',
            verification: 'vibe_acp_direct_probe',
            requiresGuardMediation: true,
          ),
          advertisedCapabilities: {'fs'},
        ),
        isEmpty,
      );
    });

    test('container-required ACP agents fail closed without a container manager', () {
      final factory = HarnessFactory();
      factory.registerAcpAgent('goose-relay', const AcpAgentConfig(binary: 'goose', containerIsolationRequired: true));

      expect(
        () => factory.create('goose-relay', const HarnessFactoryConfig(cwd: '/tmp/workspace')),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('requires container isolation but no container manager is wired'),
          ),
        ),
      );
    });

    test('ACP agents refuse a supplied container manager instead of discarding it', () {
      final factory = HarnessFactory();
      factory.registerAcpAgent(
        'goose-direct',
        const AcpAgentConfig(binary: 'goose', args: ['acp'], topology: AcpAgentTopology.direct),
      );

      expect(
        () => factory.create(
          'goose-direct',
          const HarnessFactoryConfig(
            cwd: '/tmp/workspace',
            containerManager: _FakeContainerExecutor(),
            environment: {'ANTHROPIC_API_KEY': 'host-secret'},
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('was given a container manager'),
              contains('no container provider-credential or host-capability mediation'),
              isNot(contains('host-secret')),
            ),
          ),
        ),
      );
    });
  });
}
