import 'dart:async';
import 'dart:io';

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

  const _FakeContainerExecutor();

  @override
  String? containerPathForHostPath(String hostPath) => hostPath;

  @override
  Future<void> copyFileToContainer(String hostPath, String containerPath) async {}

  @override
  Future<void> deleteFileInContainer(String containerPath) async {}

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
      final factory = HarnessFactory();
      final config = HarnessFactoryConfig(
        cwd: '/tmp/workspace',
        executable: '/usr/local/bin/codex',
        turnTimeout: const Duration(seconds: 42),
        guardChain: guardChain,
      );

      final harness = factory.create('codex', config);

      expect(harness, isA<CodexHarness>());
      final codex = harness as CodexHarness;
      expect(codex.cwd, '/tmp/workspace');
      expect(codex.executable, '/usr/local/bin/codex');
      expect(codex.turnTimeout, const Duration(seconds: 42));
      expect(codex.guardChain, same(guardChain));
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
