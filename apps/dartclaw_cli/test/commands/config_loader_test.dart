import 'package:dartclaw_acp/dartclaw_acp.dart' show acpConfigFor;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_cli/src/commands/config_loader.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show resolveChannelConfig;
import 'package:test/test.dart';

void main() {
  test('standalone workflow config resolution prefers the cwd-local ./.dartclaw/dartclaw.yaml', () {
    final resolved = resolveStandaloneWorkflowConfigPath(
      env: const {'HOME': '/home/testuser'},
      currentDirectory: '/repo',
      exists: (path) => path == '/repo/.dartclaw/dartclaw.yaml',
    );

    expect(resolved, '/repo/.dartclaw/dartclaw.yaml');
  });

  test('standalone workflow config resolution ignores legacy ./dartclaw/dartclaw.yaml', () {
    final resolved = resolveStandaloneWorkflowConfigPath(
      env: const {'HOME': '/home/testuser'},
      currentDirectory: '/repo',
      exists: (path) => path == '/repo/dartclaw/dartclaw.yaml',
    );

    expect(resolved, '/home/testuser/.dartclaw/dartclaw.yaml');
  });

  test('standalone workflow config resolution falls back to home default when no cwd-local config exists', () {
    final resolved = resolveStandaloneWorkflowConfigPath(
      env: const {'HOME': '/home/testuser'},
      currentDirectory: '/repo',
      exists: (_) => false,
    );

    expect(resolved, '/home/testuser/.dartclaw/dartclaw.yaml');
  });

  test('standalone workflow config resolution keeps explicit and env overrides authoritative', () {
    expect(
      resolveStandaloneWorkflowConfigPath(
        configPath: '/tmp/explicit.yaml',
        env: const {'HOME': '/home/testuser'},
        currentDirectory: '/repo',
        exists: (_) => true,
      ),
      '/tmp/explicit.yaml',
    );
    expect(
      resolveStandaloneWorkflowConfigPath(
        env: const {'HOME': '/home/testuser', 'DARTCLAW_CONFIG': '/tmp/env.yaml'},
        currentDirectory: '/repo',
        exists: (_) => true,
      ),
      '/tmp/env.yaml',
    );
    expect(
      resolveStandaloneWorkflowConfigPath(
        env: const {'HOME': '/home/testuser', 'DARTCLAW_HOME': '/tmp/dartclaw-home'},
        currentDirectory: '/repo',
        exists: (path) => path == '/repo/.dartclaw/dartclaw.yaml',
      ),
      '/tmp/dartclaw-home/dartclaw.yaml',
    );
  });

  test('loadCliConfig resolves every bundled channel section and surfaces its warnings', () {
    final config = loadCliConfig(
      configPath: '/tmp/dartclaw.yaml',
      env: const {'HOME': '/home/testuser'},
      fileReader: (path) => path == '/tmp/dartclaw.yaml'
          ? '''
channels:
  google_chat:
    typing_indicator: invalid
  signal:
    port: invalid
  whatsapp:
    enabled: true
    gowa_port: invalid
'''
          : null,
    );

    expect(() => resolveChannelConfig<Object>(config, ChannelType.googlechat), returnsNormally);
    expect(() => resolveChannelConfig<Object>(config, ChannelType.signal), returnsNormally);
    expect(() => resolveChannelConfig<Object>(config, ChannelType.whatsapp), returnsNormally);
    expect(config.warnings, contains('Invalid google_chat.typing_indicator: "invalid" — using default'));
    expect(config.warnings, contains('Invalid type for signal.port: "String" — using default'));
    expect(config.warnings, contains('Invalid type for whatsapp.gowa_port: "String" — using default'));
  });

  test('loadCliConfig registers the github extension parser', () {
    final config = loadCliConfig(
      configPath: '/tmp/dartclaw.yaml',
      env: const {'HOME': '/home/testuser'},
      fileReader: (path) => path == '/tmp/dartclaw.yaml'
          ? '''
github:
  enabled: true
  webhook_secret: secret
'''
          : null,
    );

    expect(config.extension<GitHubWebhookConfig>('github').enabled, isTrue);
  });

  test('loadCliConfig primes ACP for every CLI command', () {
    final config = loadCliConfig(
      configPath: '/tmp/dartclaw.yaml',
      fileReader: (_) => '''
harness:
  acp:
    agents:
      goose:
        binary: goose
        topology: direct
''',
    );

    expect(acpConfigFor(config).agents, contains('goose'));
  });

  test('an explicitly ACP-free host refuses the unclaimed section', () {
    expect(
      () => loadCliConfig(
        configPath: '/tmp/dartclaw.yaml',
        fileReader: (_) => '''
harness:
  acp:
    agents:
      goose:
        binary: goose
        topology: direct
''',
        harnessSectionPrimers: const {},
      ),
      throwsA(isA<StateError>().having((error) => error.message, 'message', contains('harness.acp'))),
    );
  });
}
