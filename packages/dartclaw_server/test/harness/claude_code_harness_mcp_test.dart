import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show containerGeneratedStatePath;
import 'package:dartclaw_models/dartclaw_models.dart' show ContainerConfig;
import 'package:dartclaw_server/src/container/container_manager.dart';
import 'package:dartclaw_server/src/container/gateway/gateway_models.dart' show mcpBridgePort;
import 'package:dartclaw_core/src/harness/claude_code_harness.dart';
import 'package:dartclaw_core/src/harness/claude_protocol.dart'
    show claudeContainerHardeningEnvVars, claudeHardeningEnvVars, containerClaudePlaceholderApiKey;
import 'package:dartclaw_core/src/harness/harness_config.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show CapturingFakeProcess, FakeProcess, makeVersionProbeProcess;
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

ProcessResult _result({int exitCode = 0, String stdout = ''}) => ProcessResult(0, exitCode, stdout, '');

Future<ProcessResult> _defaultProbe(String exe, List<String> args) async => _result(exitCode: 0, stdout: '1.0.0');

Future<void> _noOpDelay(Duration _) async {}

FakeProcess _bufferedFakeProcess() => FakeProcess(
  stdoutController: StreamController<List<int>>(),
  stderrController: StreamController<List<int>>(),
  completeExitOnKill: true,
);

CapturingFakeProcess _bufferedCapturingFakeProcess() => CapturingFakeProcess(
  stdoutController: StreamController<List<int>>(),
  stderrController: StreamController<List<int>>(),
  completeExitOnKill: true,
);

Future<Process> Function(
  String,
  List<String>, {
  String? workingDirectory,
  Map<String, String>? environment,
  bool includeParentEnvironment,
})
_processFactory(FakeProcess process, {void Function(List<String>, Map<String, String>?)? onSpawn}) {
  return (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
    onSpawn?.call(args, environment);
    scheduleMicrotask(() {
      process.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
    });
    return process;
  };
}

ClaudeCodeHarness _mcpHarness(FakeProcess process, {void Function(List<String>, Map<String, String>?)? onSpawn}) =>
    ClaudeCodeHarness(
      cwd: '/tmp',
      processFactory: _processFactory(process, onSpawn: onSpawn),
      commandProbe: _defaultProbe,
      delayFactory: _noOpDelay,
      environment: {'ANTHROPIC_API_KEY': 'sk-test'},
      harnessConfig: const HarnessConfig(mcpServerUrl: 'http://127.0.0.1:3000/mcp', mcpGatewayToken: 'test-token'),
    );

/// Distinct sentinels for every host-side secret a containerized launch must
/// never expose, so a leak names its own source.
const _hostApiKeySentinel = 'sk-ant-HOST-API-KEY-SENTINEL';
const _hostOauthSentinel = 'oauth-HOST-LOGIN-SENTINEL';
const _sharedMcpBearerSentinel = 'shared-operator-MCP-BEARER-SENTINEL';

/// A `docker exec` stand-in that answers the executable probe and then serves
/// the harness process, recording the argument vector of the real spawn.
StartCommand _containerStartCommand(FakeProcess process, {void Function(List<String>)? onSpawn}) =>
    (
      exe,
      args, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
    }) async {
      if (args.last == '--version') return makeVersionProbeProcess('claude 1.0.0');
      onSpawn?.call(args);
      scheduleMicrotask(() {
        process.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
      });
      return process;
    };

void _expectContainerSecurityExecArgs(List<String> args) {
  for (final entry in claudeContainerHardeningEnvVars.entries) {
    expect(args, contains('${entry.key}=${entry.value}'));
  }
  // The subprocess env-scrub is explicitly disabled inside the container.
  expect(args, contains('CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0'));
}

void _expectSecurityEnvironment(Map<String, String>? environment) {
  expect(environment, isNotNull);
  for (final entry in claudeHardeningEnvVars.entries) {
    expect(environment![entry.key], equals(entry.value));
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('MCP config temp file lifecycle', () {
    test('writes MCP config temp file when mcpServerUrl and mcpGatewayToken set', () async {
      late List<String> capturedArgs;
      final fake = _bufferedFakeProcess();

      final harness = _mcpHarness(fake, onSpawn: (args, _) => capturedArgs = args);

      await harness.start();

      // Verify --mcp-config arg was passed
      expect(capturedArgs, contains('--mcp-config'));
      final mcpConfigIdx = capturedArgs.indexOf('--mcp-config');
      final mcpConfigPath = capturedArgs[mcpConfigIdx + 1];
      expect(mcpConfigPath, contains('dartclaw-mcp-config-'));

      // Verify temp file exists and has correct JSON content
      final configFile = File(mcpConfigPath);
      expect(configFile.existsSync(), isTrue);

      final json = jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
      final mcpServers = json['mcpServers'] as Map<String, dynamic>;
      final dartclaw = mcpServers['dartclaw'] as Map<String, dynamic>;
      expect(dartclaw['type'], equals('http'));
      expect(dartclaw['url'], equals('http://127.0.0.1:3000/mcp'));
      final headers = dartclaw['headers'] as Map<String, dynamic>;
      expect(headers['Authorization'], equals('Bearer test-token'));

      // Clean up
      await harness.dispose();
    });

    test('temp file has 0600 permissions', () async {
      final fake = _bufferedFakeProcess();
      String? mcpConfigPath;

      final harness = _mcpHarness(
        fake,
        onSpawn: (args, _) {
          final idx = args.indexOf('--mcp-config');
          if (idx != -1) mcpConfigPath = args[idx + 1];
        },
      );

      await harness.start();

      expect(mcpConfigPath, isNotNull);
      final stat = File(mcpConfigPath!).statSync();
      // 0600 = owner read+write only. Dart returns mode as decimal.
      // 33152 = 0100600 (regular file + 0600) on macOS/Linux.
      final modeBits = stat.mode & 0x1FF; // lower 9 bits = rwxrwxrwx
      expect(modeBits, equals(0x180)); // 0600 = 0b110000000 = 0x180

      await harness.dispose();
    }, testOn: 'mac-os || linux');

    test('temp file cleaned up on stop()', () async {
      final fake = _bufferedFakeProcess();
      String? mcpConfigPath;

      final harness = _mcpHarness(
        fake,
        onSpawn: (args, _) {
          final idx = args.indexOf('--mcp-config');
          if (idx != -1) mcpConfigPath = args[idx + 1];
        },
      );

      await harness.start();
      expect(File(mcpConfigPath!).existsSync(), isTrue);

      await harness.stop();
      expect(File(mcpConfigPath!).existsSync(), isFalse);

      // Final cleanup (dispose after stop is safe)
      await harness.dispose();
    });

    test('temp file cleaned up on dispose()', () async {
      final fake = _bufferedFakeProcess();
      String? mcpConfigPath;

      final harness = _mcpHarness(
        fake,
        onSpawn: (args, _) {
          final idx = args.indexOf('--mcp-config');
          if (idx != -1) mcpConfigPath = args[idx + 1];
        },
      );

      await harness.start();
      expect(File(mcpConfigPath!).existsSync(), isTrue);

      await harness.dispose();
      expect(File(mcpConfigPath!).existsSync(), isFalse);
    });

    test('containerized MCP config names only the scoped bridge and carries no bearer', () async {
      final fake = _bufferedFakeProcess();
      final stateDir = Directory.systemTemp.createTempSync('dartclaw-state-');
      addTearDown(() => stateDir.deleteSync(recursive: true));
      final dockerCalls = <List<String>>[];
      List<String>? capturedExecArgs;

      final containerManager = ContainerManager(
        config: const ContainerConfig(enabled: true),
        containerName: 'dartclaw-test1234-restricted',
        profileId: 'restricted',
        workspaceMounts: const [],
        generatedStateDir: stateDir.path,
        hasMcpBridge: true,
        bridgeBinaryPath: '/tmp/dartclaw-bridge',
        workingDir: '/tmp',
        runCommand: (exe, args) async {
          dockerCalls.add([exe, ...args]);
          if (args.first == 'inspect') {
            return ProcessResult(0, 0, 'true\n', '');
          }
          return ProcessResult(0, 0, '', '');
        },
        startCommand: _containerStartCommand(fake, onSpawn: (args) => capturedExecArgs = args),
      );

      final harness = ClaudeCodeHarness(
        cwd: '/tmp',
        commandProbe: _defaultProbe,
        delayFactory: _noOpDelay,
        environment: {'ANTHROPIC_API_KEY': _hostApiKeySentinel},
        // Host MCP settings, which a containerized launch must not use: the
        // shared operator bearer is exactly what the scoped bridge replaces.
        harnessConfig: const HarnessConfig(
          mcpServerUrl: 'http://127.0.0.1:3000/mcp',
          mcpGatewayToken: _sharedMcpBearerSentinel,
        ),
        containerManager: containerManager,
      );

      await harness.start();

      final mcpConfigIdx = capturedExecArgs!.indexOf('--mcp-config');
      expect(mcpConfigIdx, isNot(-1));
      final containerConfigPath = capturedExecArgs![mcpConfigIdx + 1];
      expect(containerConfigPath, startsWith('$containerGeneratedStatePath/'));

      final hostConfig = File(
        '${stateDir.path}/${containerConfigPath.substring(containerGeneratedStatePath.length + 1)}',
      );
      expect(hostConfig.existsSync(), isTrue);
      final written = hostConfig.readAsStringSync();
      expect(written, contains('http://127.0.0.1:$mcpBridgePort/mcp'));
      expect(written, isNot(contains('127.0.0.1:3000')));
      expect(written, isNot(contains(_sharedMcpBearerSentinel)));
      expect(written, isNot(contains('Authorization')));

      // Delivered by the bind mount, so no in-container copy is involved.
      expect(dockerCalls.where((call) => call.length > 1 && call[1] == 'cp'), isEmpty);

      await harness.stop();
      expect(hostConfig.existsSync(), isFalse);
      await harness.dispose();
    });

    test('no MCP server is configured when the authority was granted no tools', () async {
      final fake = _bufferedFakeProcess();
      final stateDir = Directory.systemTemp.createTempSync('dartclaw-state-');
      addTearDown(() => stateDir.deleteSync(recursive: true));
      List<String>? capturedExecArgs;

      final containerManager = ContainerManager(
        config: const ContainerConfig(enabled: true),
        containerName: 'dartclaw-test1234-restricted-notools',
        profileId: 'restricted',
        workspaceMounts: const [],
        generatedStateDir: stateDir.path,
        bridgeBinaryPath: '/tmp/dartclaw-bridge',
        workingDir: '/tmp',
        runCommand: (exe, args) async =>
            args.first == 'inspect' ? ProcessResult(0, 0, 'true\n', '') : ProcessResult(0, 0, '', ''),
        startCommand: _containerStartCommand(fake, onSpawn: (args) => capturedExecArgs = args),
      );

      final harness = ClaudeCodeHarness(
        cwd: '/tmp',
        commandProbe: _defaultProbe,
        delayFactory: _noOpDelay,
        environment: {'ANTHROPIC_API_KEY': _hostApiKeySentinel},
        harnessConfig: const HarnessConfig(
          mcpServerUrl: 'http://127.0.0.1:3000/mcp',
          mcpGatewayToken: _sharedMcpBearerSentinel,
        ),
        containerManager: containerManager,
      );

      await harness.start();

      expect(capturedExecArgs, isNot(contains('--mcp-config')));
      expect(stateDir.listSync(), isEmpty);

      await harness.dispose();
    });

    test('containerized spawn carries a placeholder key so the CLI reaches the bridge', () async {
      // With no key at all the claude CLI refuses at its own local auth gate
      // (`duration_api_ms: 0`, "Not logged in") and never reaches the provider
      // bridge, so mediation could never happen.
      final fake = _bufferedFakeProcess();
      final stateDir = Directory.systemTemp.createTempSync('dartclaw-state-');
      addTearDown(() => stateDir.deleteSync(recursive: true));
      List<String>? capturedExecArgs;

      final containerManager = ContainerManager(
        config: const ContainerConfig(enabled: true),
        containerName: 'dartclaw-test1234-workspace-placeholder',
        profileId: 'workspace',
        workspaceMounts: const [],
        generatedStateDir: stateDir.path,
        bridgeBinaryPath: '/tmp/dartclaw-bridge',
        workingDir: '/tmp',
        runCommand: (exe, args) async =>
            args.first == 'inspect' ? ProcessResult(0, 0, 'true\n', '') : ProcessResult(0, 0, '', ''),
        startCommand: _containerStartCommand(fake, onSpawn: (args) => capturedExecArgs = args),
      );

      final harness = ClaudeCodeHarness(
        cwd: '/tmp',
        commandProbe: _defaultProbe,
        delayFactory: _noOpDelay,
        environment: {'ANTHROPIC_API_KEY': _hostApiKeySentinel},
        harnessConfig: const HarnessConfig(),
        containerManager: containerManager,
      );

      await harness.start();

      expect(capturedExecArgs, contains('ANTHROPIC_API_KEY=$containerClaudePlaceholderApiKey'));
      // The placeholder is not, and must never be, the host credential.
      expect(containerClaudePlaceholderApiKey, isNot(_hostApiKeySentinel));
      expect(capturedExecArgs!.join(' '), isNot(contains(_hostApiKeySentinel)));

      await harness.dispose();
    });

    test('a container granted no MCP tools is not handed the SDK memory tools instead', () async {
      // Deny-by-default must not invert: less authority cannot mean more
      // declared tools.
      final fake = _bufferedCapturingFakeProcess();
      final stateDir = Directory.systemTemp.createTempSync('dartclaw-state-');
      addTearDown(() => stateDir.deleteSync(recursive: true));

      final containerManager = ContainerManager(
        config: const ContainerConfig(enabled: true),
        containerName: 'dartclaw-test1234-restricted-nosdk',
        profileId: 'restricted',
        workspaceMounts: const [],
        generatedStateDir: stateDir.path,
        bridgeBinaryPath: '/tmp/dartclaw-bridge',
        workingDir: '/tmp',
        runCommand: (exe, args) async =>
            args.first == 'inspect' ? ProcessResult(0, 0, 'true\n', '') : ProcessResult(0, 0, '', ''),
        startCommand: _containerStartCommand(fake),
      );

      final harness = ClaudeCodeHarness(
        cwd: '/tmp',
        commandProbe: _defaultProbe,
        delayFactory: _noOpDelay,
        environment: {'ANTHROPIC_API_KEY': _hostApiKeySentinel},
        harnessConfig: const HarnessConfig(),
        containerManager: containerManager,
        onMemorySave: (payload) async => {'saved': payload},
        onMemorySearch: (payload) async => {'searched': payload},
        onMemoryRead: (payload) async => {'read': payload},
      );

      await harness.start();

      final initialize = fake.capturedStdinJson.firstWhere((message) => message['type'] == 'control_request');
      final request = initialize['request'] as Map<String, dynamic>;
      expect(request.containsKey('sdkMcpServers'), isFalse);

      await harness.dispose();
    });

    test('containerized spawn carries no provider credential or shared bearer', () async {
      final fake = _bufferedFakeProcess();
      final stateDir = Directory.systemTemp.createTempSync('dartclaw-state-');
      addTearDown(() => stateDir.deleteSync(recursive: true));
      List<String>? capturedExecArgs;

      final containerManager = ContainerManager(
        config: const ContainerConfig(enabled: true),
        containerName: 'dartclaw-test1234-workspace-secrets',
        profileId: 'workspace',
        workspaceMounts: const [],
        generatedStateDir: stateDir.path,
        hasMcpBridge: true,
        bridgeBinaryPath: '/tmp/dartclaw-bridge',
        workingDir: '/tmp',
        runCommand: (exe, args) async =>
            args.first == 'inspect' ? ProcessResult(0, 0, 'true\n', '') : ProcessResult(0, 0, '', ''),
        startCommand: _containerStartCommand(fake, onSpawn: (args) => capturedExecArgs = args),
      );

      final harness = ClaudeCodeHarness(
        cwd: '/tmp',
        commandProbe: _defaultProbe,
        delayFactory: _noOpDelay,
        environment: {'ANTHROPIC_API_KEY': _hostApiKeySentinel, 'CLAUDE_CODE_OAUTH_TOKEN': _hostOauthSentinel},
        harnessConfig: const HarnessConfig(
          mcpServerUrl: 'http://127.0.0.1:3000/mcp',
          mcpGatewayToken: _sharedMcpBearerSentinel,
        ),
        containerManager: containerManager,
      );

      await harness.start();

      final rendered = capturedExecArgs!.join('\u0000');
      for (final sentinel in [_hostApiKeySentinel, _hostOauthSentinel, _sharedMcpBearerSentinel]) {
        expect(rendered, isNot(contains(sentinel)));
      }
      for (final entry in stateDir.listSync().whereType<File>()) {
        final contents = entry.readAsStringSync();
        for (final sentinel in [_hostApiKeySentinel, _hostOauthSentinel, _sharedMcpBearerSentinel]) {
          expect(contents, isNot(contains(sentinel)));
        }
      }

      await harness.dispose();
    });

    test('no temp file when mcpServerUrl is null', () async {
      late List<String> capturedArgs;
      final fake = _bufferedFakeProcess();

      final harness = ClaudeCodeHarness(
        cwd: '/tmp',
        processFactory: _processFactory(fake, onSpawn: (args, _) => capturedArgs = args),
        commandProbe: _defaultProbe,
        delayFactory: _noOpDelay,
        environment: {'ANTHROPIC_API_KEY': 'sk-test', ...claudeHardeningEnvVars},
        harnessConfig: const HarnessConfig(),
      );

      await harness.start();

      expect(capturedArgs, isNot(contains('--mcp-config')));

      await harness.dispose();
    });

    test('writes an unauthenticated MCP config when URL is set without a gateway token', () async {
      late List<String> capturedArgs;
      final fake = _bufferedFakeProcess();
      final harness = ClaudeCodeHarness(
        cwd: '/tmp',
        processFactory: _processFactory(fake, onSpawn: (args, _) => capturedArgs = args),
        commandProbe: _defaultProbe,
        delayFactory: _noOpDelay,
        environment: {'ANTHROPIC_API_KEY': 'sk-test'},
        harnessConfig: const HarnessConfig(mcpServerUrl: 'http://localhost:3000/mcp'),
      );

      await harness.start();

      final mcpConfigIndex = capturedArgs.indexOf('--mcp-config');
      expect(mcpConfigIndex, isNonNegative);
      final config = jsonDecode(File(capturedArgs[mcpConfigIndex + 1]).readAsStringSync()) as Map<String, dynamic>;
      final server = (config['mcpServers'] as Map<String, dynamic>)['dartclaw'] as Map<String, dynamic>;
      expect(server['url'], 'http://localhost:3000/mcp');
      expect(server, isNot(contains('headers')));

      await harness.dispose();
    });

    test('skips sdkMcpServers when mcpServerUrl is set', () async {
      final fake = _bufferedCapturingFakeProcess();

      final harness = ClaudeCodeHarness(
        cwd: '/tmp',
        processFactory: _processFactory(fake),
        commandProbe: _defaultProbe,
        delayFactory: _noOpDelay,
        environment: {'ANTHROPIC_API_KEY': 'sk-test'},
        onMemorySave: (args) async => {'status': 'ok'},
        onMemorySearch: (args) async => {'results': []},
        onMemoryRead: (args) async => {'content': ''},
        harnessConfig: const HarnessConfig(mcpServerUrl: 'http://127.0.0.1:3000/mcp', mcpGatewayToken: 'test-token'),
      );

      await harness.start();

      // Find the initialize control_request
      final initMsg = fake.capturedStdinJson.firstWhere(
        (msg) => msg['type'] == 'control_request',
        orElse: () => <String, dynamic>{},
      );
      final request = initMsg['request'] as Map<String, dynamic>?;
      expect(request, isNotNull);
      expect(request!.containsKey('sdkMcpServers'), isFalse);

      await harness.dispose();
    });

    test('includes sdkMcpServers without double nesting when mcpServerUrl is null', () async {
      final fake = _bufferedCapturingFakeProcess();

      final harness = ClaudeCodeHarness(
        cwd: '/tmp',
        processFactory: _processFactory(fake),
        commandProbe: _defaultProbe,
        delayFactory: _noOpDelay,
        environment: {'ANTHROPIC_API_KEY': 'sk-test'},
        onMemorySave: (args) async => {'status': 'ok'},
        onMemorySearch: (args) async => {'results': []},
        onMemoryRead: (args) async => {'content': ''},
        harnessConfig: const HarnessConfig(),
      );

      await harness.start();

      final initMsg = fake.capturedStdinJson.firstWhere(
        (msg) => msg['type'] == 'control_request',
        orElse: () => <String, dynamic>{},
      );
      final request = initMsg['request'] as Map<String, dynamic>?;
      expect(request, isNotNull);
      final sdkMcpServers = request!['sdkMcpServers'] as Map<String, dynamic>?;
      expect(sdkMcpServers, isNotNull);
      expect(sdkMcpServers!.containsKey('dartclaw'), isTrue);
      expect(sdkMcpServers.containsKey('dartclaw-memory'), isFalse);
      expect(sdkMcpServers.containsKey('sdkMcpServers'), isFalse);
      final memoryServer = sdkMcpServers['dartclaw'] as Map<String, dynamic>;
      expect(memoryServer['type'], equals('sdk_mcp_server'));

      await harness.dispose();
    });
  });

  group('harness spawn hardening', () {
    ContainerManager makeContainerManager(String profileId, List<String> capturedArgs) {
      final fake = _bufferedFakeProcess();
      final stateDir = Directory.systemTemp.createTempSync('dartclaw-state-');
      addTearDown(() => stateDir.deleteSync(recursive: true));
      return ContainerManager(
        config: const ContainerConfig(enabled: true),
        containerName: 'dartclaw-test1234-$profileId',
        profileId: profileId,
        workspaceMounts: const [],
        generatedStateDir: stateDir.path,
        bridgeBinaryPath: '/tmp/dartclaw-bridge',
        workingDir: '/tmp',
        runCommand: (exe, args) async {
          if (args.first == 'inspect') return ProcessResult(0, 0, 'true\n', '');
          return ProcessResult(0, 0, '', '');
        },
        startCommand: _containerStartCommand(fake, onSpawn: capturedArgs.addAll),
      );
    }

    test('restricted container includes simple mode and hardened env vars', () async {
      final capturedArgs = <String>[];
      final containerManager = makeContainerManager('restricted', capturedArgs);

      final harness = ClaudeCodeHarness(
        cwd: '/tmp',
        commandProbe: _defaultProbe,
        delayFactory: _noOpDelay,
        environment: {'ANTHROPIC_API_KEY': 'sk-test'},
        harnessConfig: const HarnessConfig(),
        containerManager: containerManager,
      );

      await harness.start();

      expect(capturedArgs, contains('CLAUDE_CODE_SIMPLE=1'));
      _expectContainerSecurityExecArgs(capturedArgs);
      expect(capturedArgs, isNot(contains('--dangerously-skip-permissions')));
      expect(capturedArgs, containsAll(['--permission-prompt-tool', 'stdio']));

      await harness.dispose();
    });

    test('workspace container includes hardened env vars without simple mode', () async {
      final capturedArgs = <String>[];
      final containerManager = makeContainerManager('workspace', capturedArgs);

      final harness = ClaudeCodeHarness(
        cwd: '/tmp',
        commandProbe: _defaultProbe,
        delayFactory: _noOpDelay,
        environment: {'ANTHROPIC_API_KEY': 'sk-test'},
        harnessConfig: const HarnessConfig(),
        containerManager: containerManager,
      );

      await harness.start();

      expect(capturedArgs, isNot(contains('CLAUDE_CODE_SIMPLE=1')));
      _expectContainerSecurityExecArgs(capturedArgs);
      expect(capturedArgs, contains('--dangerously-skip-permissions'));
      expect(capturedArgs, isNot(contains('--permission-prompt-tool')));

      await harness.dispose();
    });

    test('direct execution uses default setting sources and hardened env vars', () async {
      Map<String, String>? capturedEnvironment;
      List<String>? capturedArgs;
      final fake = _bufferedFakeProcess();

      final harness = ClaudeCodeHarness(
        cwd: '/tmp',
        processFactory: _processFactory(
          fake,
          onSpawn: (args, environment) {
            capturedArgs = args;
            capturedEnvironment = environment;
          },
        ),
        commandProbe: _defaultProbe,
        delayFactory: _noOpDelay,
        environment: {'ANTHROPIC_API_KEY': 'sk-test', ...claudeHardeningEnvVars},
        harnessConfig: const HarnessConfig(),
      );

      await harness.start();

      expect(capturedArgs, isNot(contains('--setting-sources')));
      expect(capturedArgs, isNot(contains('project')));
      expect(capturedArgs, isNot(contains('--bare')));
      _expectSecurityEnvironment(capturedEnvironment);
      expect(capturedEnvironment, isNotNull);
      expect(capturedEnvironment!.containsKey('CLAUDE_CODE_SIMPLE'), isFalse);

      await harness.dispose();
    });
  });

  group('OAuth-backed startup', () {
    test('startup succeeds with local OAuth auth when ANTHROPIC_API_KEY is absent', () async {
      final fake = _bufferedFakeProcess();

      final harness = ClaudeCodeHarness(
        cwd: '/tmp',
        processFactory: _processFactory(fake),
        // Simulate `claude auth status` returning logged in via OAuth.
        commandProbe: (exe, args) async {
          if (exe == 'which') return _result(stdout: '/usr/local/bin/claude');
          if (args.contains('--version')) return _result(stdout: '2.1.87');
          if (args.contains('auth')) {
            return _result(stdout: jsonEncode({'loggedIn': true, 'authMethod': 'claude.ai'}));
          }
          return _result();
        },
        delayFactory: _noOpDelay,
        // No ANTHROPIC_API_KEY — OAuth only.
        environment: const {...claudeHardeningEnvVars},
        harnessConfig: const HarnessConfig(),
      );

      await harness.start();
      expect(harness.state.name, equals('idle'));

      await harness.dispose();
    });
  });
}
