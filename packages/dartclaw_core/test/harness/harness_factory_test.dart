import 'dart:async';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
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
        harnessConfig: const HarnessLaunchOptions(model: 'sonnet', effort: 'medium'),
        containerManager: containerManager,
        guardChain: guardChain,
        auditLogger: auditLogger,
        onMemoryApply: (payload) async => {'applied': payload},
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
      expect(claude.onMemoryApply, isNotNull);
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
        harnessConfig: const HarnessLaunchOptions(
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

    test('registerFirstClaim preserves the first registrar claim', () {
      final first = FakeAgentHarness();
      final second = FakeAgentHarness();
      final factory = HarnessFactory()
        ..registerFirstClaim('third-party', (_) => first)
        ..registerFirstClaim('third-party', (_) => second);

      expect(factory.create('third-party', const HarnessFactoryConfig(cwd: '/tmp')), same(first));
    });

    test('the first extension claim replaces a constructor-installed built-in', () {
      final first = FakeAgentHarness();
      final second = FakeAgentHarness();
      final factory = HarnessFactory()
        ..registerFirstClaim('claude', (_) => first)
        ..registerFirstClaim('claude', (_) => second);

      expect(factory.create('claude', const HarnessFactoryConfig(cwd: '/tmp')), same(first));
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
