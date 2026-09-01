import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/init/init_command.dart';
import 'package:dartclaw_cli/src/commands/init/setup_checks.dart';
import 'package:dartclaw_cli/src/commands/init/setup_state.dart';
import 'package:dartclaw_cli/src/commands/service/service_backend.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

SetupChecks _passingChecks() => SetupChecks(
  probeBinary: (_) async => BinaryProbeOutcome.responded,
  configParseable: (_) async => true,
  writeProbeFile: (_) {},
  portFree: (_) async => true,
  providerVerified: (_, _, _) async => true,
);

SetupChecks _preflightFailureChecks() => SetupChecks(
  probeBinary: (_) async => BinaryProbeOutcome.notFound,
  configParseable: (_) async => true,
  writeProbeFile: (_) {},
  portFree: (_) async => true,
  providerVerified: (_, _, _) async => true,
);

/// `configParseable` is post-write-only, so this fails verification without
/// touching preflight. An executable-keyed `probeBinary` would isolate the same
/// way; `portFree` and `writeProbeFile` would fail preflight first.
SetupChecks _postWriteFailureChecks() => SetupChecks(
  probeBinary: (_) async => BinaryProbeOutcome.responded,
  configParseable: (_) async => false,
  writeProbeFile: (_) {},
  portFree: (_) async => true,
  providerVerified: (_, _, _) async => true,
);

SetupChecks _unverifiedChecks() => SetupChecks(
  probeBinary: (_) async => BinaryProbeOutcome.responded,
  configParseable: (_) async => true,
  writeProbeFile: (_) {},
  portFree: (_) async => true,
  providerVerified: (_, _, _) async => false,
);

InitCommand _nonInteractiveCmd({
  List<SetupState>? captureInto,
  List<String>? outputCapture,
  SetupChecks? setupChecks,
  ServiceBackend? serviceBackend,
  DartclawConfig? Function(String? configPath)? loadConfig,
}) {
  return InitCommand(
    hasTerminal: () => false,
    setupChecks: setupChecks ?? _passingChecks(),
    applySetup: (state) async {
      captureInto?.add(state);
      return [state.configPath];
    },
    writeLine: outputCapture != null ? outputCapture.add : (_) {},
    serviceBackend: serviceBackend,
    loadConfig: loadConfig ?? ((_) => null),
  );
}

/// Records what `init` hands each stage, so the two call sites stay pinned to
/// their positions around `SetupApply.apply`.
class _RecordingChecks extends SetupChecks {
  final List<List<String>> preflightCalls = [];
  final List<bool> preflightWorkflowTrack = [];
  final List<bool> verifySkipPortCheck = [];
  final List<List<String>> providerCalls = [];
  final List<String> configCalls = [];

  new({Future<bool> Function(String, String, String)? providerVerified})
    : super(
        probeBinary: (_) async => BinaryProbeOutcome.responded,
        configParseable: (_) async => true,
        writeProbeFile: (_) {},
        portFree: (_) async => true,
        providerVerified: providerVerified ?? ((_, _, _) async => true),
      );

  @override
  Future<PreflightResult> preflight({
    required List<String> providers,
    required int port,
    required String instanceDir,
    bool workflowTrack = false,
  }) {
    preflightCalls.add(providers);
    preflightWorkflowTrack.add(workflowTrack);
    return super.preflight(providers: providers, port: port, instanceDir: instanceDir, workflowTrack: workflowTrack);
  }

  @override
  Future<SetupVerificationResult> verify({
    required String configPath,
    required List<String> providerIds,
    required String instanceDir,
    required int port,
    bool skipNetwork = false,
    bool skipPortCheck = false,
  }) {
    configCalls.add(configPath);
    providerCalls.add(providerIds);
    verifySkipPortCheck.add(skipPortCheck);
    return super.verify(
      configPath: configPath,
      providerIds: providerIds,
      instanceDir: instanceDir,
      port: port,
      skipNetwork: skipNetwork,
      skipPortCheck: skipPortCheck,
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
    required ServiceScope scope,
    String? sourceDir,
    String? serviceUser,
  }) async {
    ops.add('install:$instanceDir:${scope.name}');
    return const ServiceResult(success: true, message: 'installed');
  }

  @override
  Future<ServiceResult> uninstall({required String instanceDir, required ServiceScope scope}) async {
    ops.add('uninstall:$instanceDir');
    return const ServiceResult(success: true, message: 'uninstalled');
  }

  @override
  Future<ServiceStatus> status({required String instanceDir, required ServiceScope scope}) async =>
      ServiceStatus.stopped;

  @override
  Future<ServiceResult> start({required String instanceDir, required ServiceScope scope}) async {
    ops.add('start:$instanceDir:${scope.name}');
    return const ServiceResult(success: true, message: 'started');
  }

  @override
  Future<ServiceResult> stop({required String instanceDir, required ServiceScope scope}) async {
    ops.add('stop:$instanceDir');
    return const ServiceResult(success: true, message: 'stopped');
  }
}

void main() {
  group('InitCommand', () {
    test('registers the expected command surface', () {
      final options = InitCommand().argParser.options.keys;
      expect(
        options,
        containsAll([
          'workflow',
          'personalize',
          'apply-drafts',
          'provider',
          'primary-provider',
          'auth-claude',
          'auth-codex',
          'model-claude',
        ]),
      );
    });

    test('personalize re-seeds onboarding without running setup preflight', () async {
      final tempDir = Directory.systemTemp.createTempSync('init_personalize_test_');
      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });
      final checks = _RecordingChecks();
      final output = <String>[];
      final cmd = _nonInteractiveCmd(outputCapture: output, setupChecks: checks);
      final runner = CommandRunner<void>('test', 'test')..addCommand(cmd);

      await runner.run(['init', '--personalize', '--instance-dir', tempDir.path]);

      expect(checks.preflightCalls, isEmpty);
      final onboarding = File('${tempDir.path}/workspace/ONBOARDING.md');
      expect(onboarding.existsSync(), isTrue);
      expect(onboarding.readAsStringSync(), contains('Rerun: true'));
      expect(output, contains('Onboarding re-seeded for ${tempDir.path}'));
    });

    test('apply-drafts applies onboarding drafts without running full setup', () async {
      final tempDir = Directory.systemTemp.createTempSync('init_apply_drafts_test_');
      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });
      final workspace = Directory('${tempDir.path}/workspace')..createSync(recursive: true);
      File('${workspace.path}/USER.md').writeAsStringSync('# User Context\n\n## Identity\n\nOld\n');
      File('${workspace.path}/USER.md.draft').writeAsStringSync('# User Context\n\n## Identity\n\nNew\n');
      final checks = _RecordingChecks();
      final output = <String>[];
      final cmd = _nonInteractiveCmd(outputCapture: output, setupChecks: checks);
      final runner = CommandRunner<void>('test', 'test')..addCommand(cmd);

      await runner.run(['init', '--apply-drafts', '--instance-dir', tempDir.path]);

      expect(checks.preflightCalls, isEmpty);
      expect(File('${workspace.path}/USER.md').readAsStringSync(), contains('New'));
      expect(File('${workspace.path}/USER.md.draft').existsSync(), isFalse);
      expect(output, contains('Applied onboarding drafts:'));
    });

    test('apply-drafts leaves SOUL draft in non-interactive mode', () async {
      final tempDir = Directory.systemTemp.createTempSync('init_apply_soul_drafts_test_');
      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });
      final workspace = Directory('${tempDir.path}/workspace')..createSync(recursive: true);
      File('${workspace.path}/SOUL.md').writeAsStringSync('Curated soul\n');
      File('${workspace.path}/SOUL.md.draft').writeAsStringSync('New soul\n');
      final output = <String>[];
      final cmd = _nonInteractiveCmd(outputCapture: output);
      final runner = CommandRunner<void>('test', 'test')..addCommand(cmd);

      await runner.run(['init', '--apply-drafts', '--instance-dir', tempDir.path]);

      expect(File('${workspace.path}/SOUL.md').readAsStringSync(), 'Curated soul\n');
      expect(File('${workspace.path}/SOUL.md.draft').existsSync(), isTrue);
      expect(output, contains('SOUL.md.draft requires interactive confirmation; left unchanged.'));
    });

    test('workflow non-interactive flow resolves minimal standalone setup state', () async {
      final captured = <SetupState>[];
      final output = <String>[];
      final checks = _RecordingChecks(providerVerified: (_, _, _) async => true);
      final cmd = _nonInteractiveCmd(captureInto: captured, outputCapture: output, setupChecks: checks);
      final runner = CommandRunner<void>('test', 'test')..addCommand(cmd);

      await runner.run([
        'init',
        '--workflow',
        '--non-interactive',
        '--provider',
        'claude',
        '--auth-claude',
        'oauth',
        '--model-claude',
        'sonnet',
      ]);

      final state = captured.single;
      expect(state.workflowTrack, isTrue);
      expect(state.instanceDir, './.dartclaw');
      expect(state.configPath, './.dartclaw/dartclaw.yaml');
      expect(state.provider, 'claude');
      expect(state.providers, ['claude']);
      expect(state.authMethod, 'oauth');
      expect(state.model, 'sonnet');
      expect(checks.preflightWorkflowTrack.single, isTrue);
      expect(
        checks.verifySkipPortCheck.single,
        isTrue,
        reason: 'the workflow track skips the port check in both stages',
      );
      expect(output, contains('Run a workflow: dartclaw workflow run --standalone code-review'));
      expect(output.any((line) => line.contains('Start the server')), isFalse);
    });

    test('workflow init writes a discoverable .dartclaw config and allowlist gitignore', () async {
      final tempDir = Directory.systemTemp.createTempSync('init_workflow_dotdir_test_');
      final savedCwd = Directory.current;
      addTearDown(() {
        Directory.current = savedCwd;
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });
      Directory.current = tempDir;
      final output = <String>[];
      final cmd = InitCommand(
        hasTerminal: () => false,
        setupChecks: _passingChecks(),
        writeLine: output.add,
        loadConfig: (_) => null,
      );
      final runner = CommandRunner<void>('test', 'test')..addCommand(cmd);

      await runner.run([
        'init',
        '--workflow',
        '--non-interactive',
        '--provider',
        'claude',
        '--auth-claude',
        'oauth',
        '--model-claude',
        'sonnet',
      ]);

      final configPath = p.join(tempDir.path, '.dartclaw', 'dartclaw.yaml');
      expect(File(configPath).existsSync(), isTrue);
      final config = DartclawConfig.load(configPath: configPath, env: {'HOME': tempDir.path});
      expect(config.server.dataDir, p.join(tempDir.path, '.dartclaw'));
      expect(config.tasksDbPath, p.join(tempDir.path, '.dartclaw', 'tasks.db'));
      expect(config.searchDbPath, p.join(tempDir.path, '.dartclaw', 'search.db'));
      expect(Directory(p.join(tempDir.path, 'dartclaw')).existsSync(), isFalse);
      expect(
        File(p.join(tempDir.path, '.dartclaw', '.gitignore')).readAsStringSync(),
        '*\n!.gitignore\n!dartclaw.yaml\n!workflows/\n!workflows/**\nworkflows/**/.DS_Store\nworkflows/built-in/\nworkflows/runs/\n',
      );
      expect(output, contains('Run a workflow: dartclaw workflow run --standalone code-review'));
      expect(output.any((line) => line.contains('--config')), isFalse);
    });

    test('workflow track with a custom instance dir prints the --config next-step form', () async {
      final captured = <SetupState>[];
      final output = <String>[];
      final checks = _RecordingChecks(providerVerified: (_, _, _) async => true);
      final cmd = _nonInteractiveCmd(captureInto: captured, outputCapture: output, setupChecks: checks);
      final runner = CommandRunner<void>('test', 'test')..addCommand(cmd);

      await runner.run([
        'init',
        '--workflow',
        '--non-interactive',
        '--instance-dir',
        '/tmp/custom-dc',
        '--provider',
        'claude',
        '--auth-claude',
        'oauth',
        '--model-claude',
        'sonnet',
      ]);

      // A non-default config folder is not found by the bare standalone resolver,
      // so the next step must carry --config pointing at the written config.
      expect(
        output,
        contains(
          'Run a workflow: dartclaw workflow run --standalone --config /tmp/custom-dc/dartclaw.yaml code-review',
        ),
      );
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
      final checks = _RecordingChecks(providerVerified: (_, _, _) async => true);
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
      final cmd = _nonInteractiveCmd(captureInto: captured, setupChecks: checks, loadConfig: (_) => config);
      final runner = CommandRunner<void>('test', 'test')
        ..argParser.addOption('config')
        ..addCommand(cmd);

      await runner.run(['--config', '/tmp/custom.yaml', 'init']);

      expect(captured.single.configPath, '/tmp/custom.yaml');
      expect(checks.configCalls, ['/tmp/custom.yaml']);
    });

    test('preflight failure stops before apply', () async {
      var applyCalled = false;
      final cmd = InitCommand(
        hasTerminal: () => false,
        setupChecks: _preflightFailureChecks(),
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
        throwsA(
          isA<UsageException>().having(
            (e) => e.message,
            'message',
            'Setup preflight failed — fix the issues above and re-run.',
          ),
        ),
      );
      expect(applyCalled, isFalse);
    });

    test('verification failure after apply returns UsageException', () async {
      final applied = <SetupState>[];
      final cmd = _nonInteractiveCmd(captureInto: applied, setupChecks: _postWriteFailureChecks());
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
        throwsA(
          isA<UsageException>().having(
            (e) => e.message,
            'message',
            'Post-setup verification failed — fix the issues above.',
          ),
        ),
      );
      expect(applied, hasLength(1), reason: 'the post-write stage reports after the files are written');
    });

    test('configured but unverified state is surfaced when provider verification fails', () async {
      final output = <String>[];
      final cmd = _nonInteractiveCmd(outputCapture: output, setupChecks: _unverifiedChecks());
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
      final checks = _RecordingChecks(providerVerified: (providerId, _, _) async => providerId == 'claude');
      final cmd = _nonInteractiveCmd(outputCapture: output, setupChecks: checks);
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

      expect(checks.providerCalls.single, ['claude', 'codex']);
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

      expect(backend.ops, contains('install:/tmp/service-instance:user'));
      expect(backend.ops, contains('start:/tmp/service-instance:user'));
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
        security: const SecurityConfig(contentGuardEnabled: false),
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
    });
  });
}
