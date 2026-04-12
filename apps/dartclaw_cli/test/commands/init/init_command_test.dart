import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/init/init_command.dart';
import 'package:dartclaw_cli/src/commands/init/setup_preflight.dart';
import 'package:dartclaw_cli/src/commands/init/setup_state.dart';
import 'package:dartclaw_cli/src/commands/service/service_backend.dart';
import 'package:dartclaw_cli/src/commands/service/setup_verifier.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

Future<SetupPreflight> _passingPreflight({
  required List<String> providers,
  required int port,
  required String instanceDir,
  Future<ProcessResult> Function(String, List<String>)? runProcess,
}) async => const SetupPreflight(errors: [], warnings: []);

Future<SetupPreflight> _failingPreflight({
  required List<String> providers,
  required int port,
  required String instanceDir,
  Future<ProcessResult> Function(String, List<String>)? runProcess,
}) async => const SetupPreflight(errors: ['Provider binary not found'], warnings: []);

SetupVerifier _verifiedVerifier() => SetupVerifier(
  binaryExists: (_) async => true,
  configParseable: (_) async => true,
  dirWritable: (_) async => true,
  portFree: (_) async => true,
  providerVerified: (_, _, _) async => true,
);

SetupVerifier _localFailureVerifier() => SetupVerifier(
  binaryExists: (_) async => false,
  configParseable: (_) async => true,
  dirWritable: (_) async => true,
  portFree: (_) async => true,
  providerVerified: (_, _, _) async => true,
);

SetupVerifier _unverifiedVerifier() => SetupVerifier(
  binaryExists: (_) async => true,
  configParseable: (_) async => true,
  dirWritable: (_) async => true,
  portFree: (_) async => true,
  providerVerified: (_, _, _) async => false,
);

InitCommand _nonInteractiveCmd({
  List<SetupState>? captureInto,
  List<String>? outputCapture,
  SetupVerifier? verifier,
  ServiceBackend? serviceBackend,
  Future<SetupPreflight> Function({
    required List<String> providers,
    required int port,
    required String instanceDir,
    Future<ProcessResult> Function(String, List<String>)? runProcess,
  })?
  runPreflight,
  DartclawConfig? Function(String? configPath)? loadConfig,
}) {
  return InitCommand(
    hasTerminal: () => false,
    runPreflight: runPreflight ?? _passingPreflight,
    applySetup: (state) async {
      captureInto?.add(state);
      return [state.configPath];
    },
    writeLine: outputCapture != null ? outputCapture.add : (_) {},
    verifier: verifier ?? _verifiedVerifier(),
    serviceBackend: serviceBackend,
    loadConfig: loadConfig ?? ((_) => null),
  );
}

class _RecordingVerifier extends SetupVerifier {
  final List<List<String>> providerCalls = [];
  final List<String> configCalls = [];

  _RecordingVerifier({required Future<bool> Function(String, String, String) providerVerified})
    : super(
        binaryExists: (_) async => true,
        configParseable: (_) async => true,
        dirWritable: (_) async => true,
        portFree: (_) async => true,
        providerVerified: providerVerified,
      );

  @override
  Future<SetupVerificationResult> verify({
    required String configPath,
    required List<String> providerIds,
    required String instanceDir,
    required int port,
    bool skipNetwork = false,
  }) {
    configCalls.add(configPath);
    providerCalls.add(providerIds);
    return super.verify(
      configPath: configPath,
      providerIds: providerIds,
      instanceDir: instanceDir,
      port: port,
      skipNetwork: skipNetwork,
    );
  }
}

class _FakeServiceBackend implements ServiceBackend {
  final List<String> ops = [];

  @override
  Future<ServiceResult> install({
    required String binPath,
    required String configPath,
    required int port,
    required String instanceDir,
    String? sourceDir,
  }) async {
    ops.add('install:$instanceDir');
    return const ServiceResult(success: true, message: 'installed');
  }

  @override
  Future<ServiceResult> uninstall({required String instanceDir}) async {
    ops.add('uninstall:$instanceDir');
    return const ServiceResult(success: true, message: 'uninstalled');
  }

  @override
  Future<ServiceStatus> status({required String instanceDir}) async => ServiceStatus.stopped;

  @override
  Future<ServiceResult> start({required String instanceDir}) async {
    ops.add('start:$instanceDir');
    return const ServiceResult(success: true, message: 'started');
  }

  @override
  Future<ServiceResult> stop({required String instanceDir}) async {
    ops.add('stop:$instanceDir');
    return const ServiceResult(success: true, message: 'stopped');
  }
}

void main() {
  group('InitCommand', () {
    test('registers the expected command surface', () {
      final options = InitCommand().argParser.options.keys;
      expect(options, containsAll(['provider', 'primary-provider', 'auth-claude', 'auth-codex', 'model-claude']));
    });

    test('non-interactive single-provider flow resolves setup state from flags', () async {
      final captured = <SetupState>[];
      final cmd = _nonInteractiveCmd(captureInto: captured);
      final runner = CommandRunner<void>('test', 'test')..addCommand(cmd);

      await runner.run([
        'init',
        '--non-interactive',
        '--provider',
        'claude',
        '--auth-claude',
        'env',
        '--model-claude',
        'sonnet',
        '--port',
        '4000',
        '--instance-dir',
        '/tmp/test-instance',
        '--instance-name',
        'MyBot',
        '--gateway-auth',
        'none',
      ]);

      final state = captured.single;
      expect(state.provider, 'claude');
      expect(state.providers, ['claude']);
      expect(state.authMethod, 'env');
      expect(state.model, 'sonnet');
      expect(state.port, 4000);
      expect(state.instanceDir, '/tmp/test-instance');
      expect(state.instanceName, 'MyBot');
      expect(state.gatewayAuthMode, 'none');
    });

    test('non-interactive multi-provider flow requires primary provider and captures per-provider config', () async {
      final captured = <SetupState>[];
      final cmd = _nonInteractiveCmd(captureInto: captured);
      final runner = CommandRunner<void>('test', 'test')..addCommand(cmd);

      await runner.run([
        'init',
        '--non-interactive',
        '--provider',
        'claude',
        '--provider',
        'codex',
        '--auth-claude',
        'oauth',
        '--auth-codex',
        'env',
        '--model-claude',
        'haiku',
        '--model-codex',
        'gpt-5',
        '--primary-provider',
        'codex',
      ]);

      final state = captured.single;
      expect(state.provider, 'codex');
      expect(state.providers, containsAll(['claude', 'codex']));
      expect(state.providerAuthMethods['claude'], 'oauth');
      expect(state.providerAuthMethods['codex'], 'env');
      expect(state.providerModels['claude'], 'haiku');
      expect(state.providerModels['codex'], 'gpt-5');
    });

    test('missing required non-interactive inputs are reported precisely', () async {
      final cmd = _nonInteractiveCmd();
      final runner = CommandRunner<void>('test', 'test')..addCommand(cmd);

      await expectLater(
        runner.run(['init', '--non-interactive', '--provider', 'claude']),
        throwsA(isA<UsageException>().having((error) => error.message, 'message', contains('--model-claude'))),
      );
    });

    test('non-terminal fallback announces that it is running non-interactively', () async {
      final output = <String>[];
      final cmd = _nonInteractiveCmd(outputCapture: output);
      final runner = CommandRunner<void>('test', 'test')..addCommand(cmd);

      await runner.run(['init', '--provider', 'claude', '--auth-claude', 'oauth', '--model-claude', 'sonnet']);

      expect(output, anyElement(contains('No terminal detected - running in non-interactive mode.')));
    });

    test('explicit-config rerun defaults are loaded from the provided config path', () async {
      final captured = <SetupState>[];
      final config = DartclawConfig(
        server: const ServerConfig(name: 'Existing', dataDir: '/tmp/existing', port: 4444),
        agent: const AgentConfig(provider: 'codex', model: 'gpt-5'),
        gateway: const GatewayConfig(authMode: 'none'),
        providers: const ProvidersConfig(
          entries: {
            'codex': ProviderEntry(executable: 'codex', options: {'auth_method': 'oauth', 'model': 'gpt-5'}),
          },
        ),
      );
      final cmd = _nonInteractiveCmd(
        captureInto: captured,
        loadConfig: (configPath) {
          expect(configPath, '/tmp/custom.yaml');
          return config;
        },
      );
      final runner = CommandRunner<void>('test', 'test')
        ..argParser.addOption('config')
        ..addCommand(cmd);

      await runner.run(['--config', '/tmp/custom.yaml', 'init']);

      final state = captured.single;
      expect(state.instanceName, 'Existing');
      expect(state.instanceDir, '/tmp/existing');
      expect(state.port, 4444);
      expect(state.provider, 'codex');
      expect(state.model, 'gpt-5');
      expect(state.gatewayAuthMode, 'none');
    });

    test('explicit-config rerun preserves selected config target through apply and verify', () async {
      final captured = <SetupState>[];
      final verifier = _RecordingVerifier(providerVerified: (_, _, _) async => true);
      final config = DartclawConfig(
        server: const ServerConfig(name: 'Existing', dataDir: '/tmp/existing', port: 4444),
        agent: const AgentConfig(provider: 'codex', model: 'gpt-5'),
        gateway: const GatewayConfig(authMode: 'none'),
        providers: const ProvidersConfig(
          entries: {
            'codex': ProviderEntry(executable: 'codex', options: {'auth_method': 'oauth', 'model': 'gpt-5'}),
          },
        ),
      );
      final cmd = _nonInteractiveCmd(captureInto: captured, verifier: verifier, loadConfig: (_) => config);
      final runner = CommandRunner<void>('test', 'test')
        ..argParser.addOption('config')
        ..addCommand(cmd);

      await runner.run(['--config', '/tmp/custom.yaml', 'init']);

      expect(captured.single.configPath, '/tmp/custom.yaml');
      expect(verifier.configCalls, ['/tmp/custom.yaml']);
    });

    test('preflight failure stops before apply', () async {
      var applyCalled = false;
      final cmd = InitCommand(
        hasTerminal: () => false,
        runPreflight: _failingPreflight,
        applySetup: (_) async {
          applyCalled = true;
          return [];
        },
        writeLine: (_) {},
      );
      final runner = CommandRunner<void>('test', 'test')..addCommand(cmd);

      await expectLater(
        runner.run([
          'init',
          '--non-interactive',
          '--provider',
          'claude',
          '--auth-claude',
          'oauth',
          '--model-claude',
          'sonnet',
        ]),
        throwsA(isA<UsageException>()),
      );
      expect(applyCalled, isFalse);
    });

    test('verification failure after apply returns UsageException', () async {
      final cmd = _nonInteractiveCmd(verifier: _localFailureVerifier());
      final runner = CommandRunner<void>('test', 'test')..addCommand(cmd);

      await expectLater(
        runner.run([
          'init',
          '--non-interactive',
          '--provider',
          'claude',
          '--auth-claude',
          'oauth',
          '--model-claude',
          'sonnet',
        ]),
        throwsA(isA<UsageException>()),
      );
    });

    test('configured but unverified state is surfaced when provider verification fails', () async {
      final output = <String>[];
      final cmd = _nonInteractiveCmd(outputCapture: output, verifier: _unverifiedVerifier());
      final runner = CommandRunner<void>('test', 'test')..addCommand(cmd);

      await runner.run([
        'init',
        '--non-interactive',
        '--provider',
        'claude',
        '--auth-claude',
        'oauth',
        '--model-claude',
        'sonnet',
      ]);

      expect(output.join('\n'), contains('configured but unverified'));
    });

    test('multi-provider verification checks every configured provider', () async {
      final output = <String>[];
      final verifier = _RecordingVerifier(providerVerified: (providerId, _, _) async => providerId == 'claude');
      final cmd = _nonInteractiveCmd(outputCapture: output, verifier: verifier);
      final runner = CommandRunner<void>('test', 'test')..addCommand(cmd);

      await runner.run([
        'init',
        '--non-interactive',
        '--provider',
        'claude',
        '--provider',
        'codex',
        '--auth-claude',
        'oauth',
        '--auth-codex',
        'oauth',
        '--model-claude',
        'sonnet',
        '--model-codex',
        'gpt-5',
        '--primary-provider',
        'claude',
      ]);

      expect(verifier.providerCalls.single, ['claude', 'codex']);
      expect(output.join('\n'), contains('configured but unverified'));
      expect(output.join('\n'), contains('codex'));
    });

    test('launch=service installs and starts the selected instance service', () async {
      final backend = _FakeServiceBackend();
      final cmd = _nonInteractiveCmd(serviceBackend: backend);
      final runner = CommandRunner<void>('test', 'test')..addCommand(cmd);

      await runner.run([
        'init',
        '--non-interactive',
        '--provider',
        'claude',
        '--auth-claude',
        'oauth',
        '--model-claude',
        'sonnet',
        '--launch',
        'service',
        '--instance-dir',
        '/tmp/service-instance',
      ]);

      expect(backend.ops, contains('install:/tmp/service-instance'));
      expect(backend.ops, contains('start:/tmp/service-instance'));
    });

    test('full-track flags populate supported advanced fields', () async {
      final captured = <SetupState>[];
      final cmd = _nonInteractiveCmd(captureInto: captured);
      final runner = CommandRunner<void>('test', 'test')..addCommand(cmd);

      await runner.run([
        'init',
        '--non-interactive',
        '--provider',
        'claude',
        '--auth-claude',
        'oauth',
        '--model-claude',
        'sonnet',
        '--google-chat',
        '--google-chat-service-account',
        '/etc/sa.json',
        '--google-chat-audience-type',
        'project-number',
        '--google-chat-audience',
        '123456789',
        '--no-content-guard',
      ]);

      final state = captured.single;
      expect(state.googleChatEnabled, isTrue);
      expect(state.googleChatAudienceType, 'project-number');
      expect(state.googleChatAudience, '123456789');
      expect(state.contentGuardEnabled, isFalse);
    });

    test('full-track rerun hydrates advanced defaults from existing config', () async {
      final captured = <SetupState>[];
      final config = DartclawConfig(
        server: const ServerConfig(name: 'Existing', dataDir: '/tmp/existing', port: 4444),
        agent: const AgentConfig(provider: 'claude', model: 'sonnet'),
        gateway: const GatewayConfig(authMode: 'token'),
        providers: const ProvidersConfig(
          entries: {
            'claude': ProviderEntry(executable: 'claude', options: {'auth_method': 'oauth', 'model': 'sonnet'}),
          },
        ),
        channels: const ChannelConfig(
          channelConfigs: {
            'whatsapp': {'enabled': true, 'gowa_executable': 'wa-bin', 'gowa_port': 3100},
          },
        ),
        container: const ContainerConfig(enabled: true, image: 'dartclaw-agent:v2'),
        security: const SecurityConfig(contentGuardEnabled: false, inputSanitizerEnabled: false),
      );
      final cmd = _nonInteractiveCmd(captureInto: captured, loadConfig: (_) => config);
      final runner = CommandRunner<void>('test', 'test')
        ..argParser.addOption('config')
        ..addCommand(cmd);

      await runner.run(['--config', '/tmp/custom.yaml', 'init', '--track', 'full']);

      final state = captured.single;
      expect(state.manageAdvancedSettings, isTrue);
      expect(state.whatsappEnabled, isTrue);
      expect(state.gowaExecutable, 'wa-bin');
      expect(state.gowaPort, 3100);
      expect(state.containerEnabled, isTrue);
      expect(state.containerImage, 'dartclaw-agent:v2');
      expect(state.contentGuardEnabled, isFalse);
      expect(state.inputSanitizerEnabled, isFalse);
    });
  });
}
