import 'dart:async';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' show AcpAgentConfig, AcpAgentTopology, PlatformCapabilities;
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

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

  const _FakeContainerExecutor();

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
  group('HarnessFactory', () {
    test('registers claude by default', () {
      final factory = HarnessFactory();

      expect(factory.supports('claude'), isTrue);
      expect(factory.supports('codex'), isTrue);
      expect(factory.registeredProviders, containsAll(['claude', 'codex']));
    });

    test('creates a ClaudeCodeHarness from the built-in claude provider', () {
      final containerManager = const _FakeContainerExecutor();
      final guardChain = GuardChain(guards: const []);
      final auditLogger = GuardAuditLogger();
      final factory = HarnessFactory();
      final config = HarnessFactoryConfig(
        cwd: '/tmp/workspace',
        executable: '/usr/local/bin/claude',
        turnTimeout: const Duration(seconds: 42),
        harnessConfig: const HarnessConfig(model: 'sonnet', effort: 'medium'),
        containerManager: containerManager,
        guardChain: guardChain,
        auditLogger: auditLogger,
        onMemorySave: (payload) async => {'saved': payload},
        onMemorySearch: (payload) async => {'searched': payload},
        onMemoryRead: (payload) async => {'read': payload},
      );

      final harness = factory.create('claude', config);

      expect(harness, isA<ClaudeCodeHarness>());
      final claude = harness as ClaudeCodeHarness;
      expect(claude.cwd, '/tmp/workspace');
      expect(claude.claudeExecutable, '/usr/local/bin/claude');
      expect(claude.turnTimeout, const Duration(seconds: 42));
      expect(claude.harnessConfig.model, 'sonnet');
      expect(claude.harnessConfig.effort, 'medium');
      expect(claude.containerManager, same(containerManager));
      expect(claude.guardChain, same(guardChain));
      expect(claude.auditLogger, same(auditLogger));
      expect(claude.providerOptions, isEmpty);
      expect(claude.onMemorySave, isNotNull);
      expect(claude.onMemorySearch, isNotNull);
      expect(claude.onMemoryRead, isNotNull);
    });

    test('gives the codex harness the same container as claude', () {
      // Without this the effective policy would silently mean host execution
      // for one provider and container execution for the other.
      const containerManager = _FakeContainerExecutor();
      final harness = HarnessFactory().create(
        'codex',
        const HarnessFactoryConfig(cwd: '/tmp/workspace', containerManager: containerManager),
      );

      expect((harness as CodexHarness).containerManager, same(containerManager));
    });

    test('passes claude providerOptions through the factory config', () {
      final factory = HarnessFactory();
      final harness = factory.create(
        'claude',
        const HarnessFactoryConfig(
          cwd: '/tmp/workspace',
          providerOptions: {
            'permissionMode': 'auto',
            'sandbox': {'enabled': true},
          },
        ),
      );

      expect(harness, isA<ClaudeCodeHarness>());
      final claude = harness as ClaudeCodeHarness;
      expect(claude.providerOptions, {
        'permissionMode': 'auto',
        'sandbox': {'enabled': true},
      });
    });

    test('creates a CodexHarness from the built-in codex provider', () {
      final guardChain = GuardChain(guards: const []);
      final platformCapabilities = PlatformCapabilities(operatingSystem: 'windows');
      final factory = HarnessFactory();
      final config = HarnessFactoryConfig(
        cwd: '/tmp/workspace',
        executable: '/usr/local/bin/codex',
        turnTimeout: const Duration(seconds: 42),
        guardChain: guardChain,
        platformCapabilities: platformCapabilities,
      );

      final harness = factory.create('codex', config);

      expect(harness, isA<CodexHarness>());
      final codex = harness as CodexHarness;
      expect(codex.cwd, '/tmp/workspace');
      expect(codex.executable, '/usr/local/bin/codex');
      expect(codex.turnTimeout, const Duration(seconds: 42));
      expect(codex.guardChain, same(guardChain));
      expect(codex.platformCapabilities, same(platformCapabilities));
    });

    test('defaults codex to the codex binary when executable is not set explicitly', () {
      final factory = HarnessFactory();
      final harness = factory.create('codex', const HarnessFactoryConfig(cwd: '/tmp/workspace'));

      expect(harness, isA<CodexHarness>());
      final codex = harness as CodexHarness;
      expect(codex.executable, 'codex');
    });

    test('passes codex harnessConfig and providerOptions through the factory config', () {
      final factory = HarnessFactory();
      final config = HarnessFactoryConfig(
        cwd: '/tmp/workspace',
        executable: '/usr/local/bin/codex',
        turnTimeout: const Duration(seconds: 42),
        harnessConfig: const HarnessConfig(
          model: 'gpt-5',
          mcpServerUrl: 'http://127.0.0.1:3333/mcp',
          mcpGatewayToken: 'test-token',
        ),
        providerOptions: const {'sandbox': 'workspace-write', 'approval': 'on-request'},
      );

      final harness = factory.create('codex', config) as CodexHarness;

      expect(harness.cwd, '/tmp/workspace');
      expect(harness.executable, '/usr/local/bin/codex');
      expect(harness.turnTimeout, const Duration(seconds: 42));
      expect(harness.harnessConfig.model, 'gpt-5');
      expect(harness.harnessConfig.mcpServerUrl, 'http://127.0.0.1:3333/mcp');
      expect(harness.harnessConfig.mcpGatewayToken, 'test-token');
      expect(harness.providerOptions, {'sandbox': 'workspace-write', 'approval': 'on-request'});
    });

    test('throws for unknown providers', () {
      final factory = HarnessFactory();

      expect(
        () => factory.create('unknown', const HarnessFactoryConfig(cwd: '/tmp')),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            contains('No harness factory registered for provider: unknown'),
          ),
        ),
      );
    });

    test('supports custom registrations', () {
      final factory = HarnessFactory();
      factory.register('fake', (_) => FakeAgentHarness());

      expect(factory.supports('fake'), isTrue);
      expect(factory.registeredProviders, contains('fake'));

      final harness = factory.create('fake', const HarnessFactoryConfig(cwd: '/tmp'));
      expect(harness, isA<FakeAgentHarness>());
    });

    test('registered ACP agents receive guard, permission, and audit seams', () {
      final factory = HarnessFactory();
      final guardChain = GuardChain(guards: const []);
      Future<AcpPermissionResult> permissionDecision(AcpPermissionRequest request) async {
        return const AcpPermissionResult(granted: true);
      }

      void audit(AcpReverseCallAuditEvent event) {}

      factory.registerAcpAgent(
        'goose-direct',
        const AcpAgentConfig(binary: 'goose', args: ['acp'], containerIsolationRequired: false),
      );

      final harness =
          factory.create(
                'goose-direct',
                HarnessFactoryConfig(
                  cwd: '/tmp/workspace',
                  guardChain: guardChain,
                  acpPermissionDecision: permissionDecision,
                  acpReverseCallAudit: audit,
                ),
              )
              as AcpHarness;

      expect(harness.guardChain, same(guardChain));
      expect(harness.permissionDecision, same(permissionDecision));
      expect(harness.onReverseCallAudit, same(audit));
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

    test('probeContinuityProviders returns built-in providers that support session continuity', () {
      final factory = HarnessFactory();

      final providers = factory.probeContinuityProviders();

      expect(providers, containsAll(['claude', 'codex']));
    });

    test('probeContinuityProviders excludes custom providers without continuity', () {
      final factory = HarnessFactory();
      factory.register('no-continuity', (_) => FakeAgentHarness());

      final providers = factory.probeContinuityProviders();

      expect(providers, isNot(contains('no-continuity')));
    });
  });
}
