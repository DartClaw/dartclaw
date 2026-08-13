import 'dart:async';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' show PlatformCapabilities, UnsupportedCapabilityError;
import 'package:dartclaw_core/src/container/container_executor.dart';
import 'package:dartclaw_core/src/harness/codex_environment.dart';
import 'package:dartclaw_core/src/harness/codex_harness.dart';
import 'package:dartclaw_core/src/harness/harness_config.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Distinct sentinels for every host-side secret a containerized Codex launch
/// must never expose, so a leak names its own source.
const _hostApiKeySentinel = 'sk-openai-HOST-API-KEY-SENTINEL';
const _hostAuthJsonSentinel = 'HOST-CODEX-AUTH-JSON-SENTINEL';
const _sharedMcpBearerSentinel = 'shared-operator-MCP-BEARER-SENTINEL';

/// Records what a containerized Codex launch actually asked the container to do.
final class _RecordingCodexContainer implements ContainerExecutor {
  new({
    required this.hostRoot,
    this.profileId = 'restricted',
    this.mcpBridgeUrl,
    this.executableRunnable = true,
    this.mountsWorkspace = true,
  });

  final String hostRoot;

  @override
  final String profileId;

  @override
  final String workingDir = '/tmp';

  @override
  final bool hasProjectMount = false;

  @override
  final String? mcpBridgeUrl;

  /// `false` fakes an image whose packaged CLI cannot run.
  final bool executableRunnable;

  /// `false` fakes the restricted profile, which mounts no workspace.
  final bool mountsWorkspace;

  @override
  String get providerBridgeUrl => 'http://127.0.0.1:8080';

  @override
  late final String generatedStateDir = p.join(hostRoot, 'state');

  static const containerStateRoot = '/home/dartclaw/.dartclaw';

  var startCount = 0;
  final commands = <List<String>>[];
  final environments = <Map<String, String>?>[];
  final workingDirectories = <String?>[];
  FakeCodexProcess? spawned;

  @override
  Future<void> start() async {
    startCount++;
    Directory(generatedStateDir).createSync(recursive: true);
  }

  @override
  Future<Process> exec(List<String> command, {Map<String, String>? env, String? workingDirectory}) async {
    commands.add(List<String>.from(command));
    environments.add(env == null ? null : Map<String, String>.from(env));
    workingDirectories.add(workingDirectory);
    if (command.length == 2 && command[1] == '--version') {
      return executableRunnable
          ? makeVersionProbeProcess('codex-cli 0.146.0')
          : makeVersionProbeProcess('', exitCode: 127);
    }
    return spawned = FakeCodexProcess(completeExitOnKill: true);
  }

  static const containerWorkspace = '/project';

  @override
  String? containerPathForHostPath(String hostPath) {
    final normalized = p.absolute(hostPath);
    for (final mount in [
      (p.absolute(generatedStateDir), containerStateRoot),
      if (mountsWorkspace) (p.absolute(hostRoot), containerWorkspace),
    ]) {
      if (p.equals(normalized, mount.$1)) return mount.$2;
      if (p.isWithin(mount.$1, normalized)) {
        return p.posix.join(mount.$2, p.relative(normalized, from: mount.$1).replaceAll(r'\', '/'));
      }
    }
    return null;
  }

  /// The generated Codex home, read from the host side of the bind mount.
  Directory get codexHome => Directory(p.join(generatedStateDir, 'codex-home'));

  String get codexConfig => File(p.join(codexHome.path, 'config.toml')).readAsStringSync();
}

CodexHarness _harness(
  _RecordingCodexContainer container, {
  HarnessConfig harnessConfig = const HarnessConfig(),
  Map<String, String>? environment,
}) => CodexHarness(
  cwd: container.hostRoot,
  containerManager: container,
  environment:
      environment ?? {'OPENAI_API_KEY': _hostApiKeySentinel, 'CODEX_HOME': '/home/tester/.codex', 'PATH': '/usr/bin'},
  harnessConfig: harnessConfig,
  // Points the seeding lifecycle's source at the temp root, so a host home
  // planted below is genuinely copyable and the assertion can fail.
  platformCapabilities: PlatformCapabilities(environment: {'HOME': container.hostRoot}),
  commandProbe: (exe, args) async => throw StateError('containerized Codex must not probe the host binary'),
  delayFactory: noOpDelay,
  killGracePeriod: Duration.zero,
);

Future<void> _start(CodexHarness harness, _RecordingCodexContainer container) async {
  final startFuture = harness.start();
  // The handshake only exists once the container spawn has happened.
  for (var attempt = 0; container.spawned == null && attempt < 200; attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  final process = container.spawned!;
  await waitForSentMessage(process, 'initialize');
  process.emitInitializeResponse(id: latestRequestId(process, 'initialize'));
  await startFuture;
}

/// Plants a credentialed host home where the *seeded* lifecycle copies from,
/// and proves that lifecycle really does copy it – without the control,
/// "was not copied" would pass against an unreadable source.
Future<void> _plantCredentialedHostHome(Directory root) async {
  Directory(p.join(root.path, '.codex')).createSync(recursive: true);
  File(p.join(root.path, '.codex', 'auth.json')).writeAsStringSync('{"token":"$_hostAuthJsonSentinel"}');

  final seeded = CodexEnvironment(
    developerInstructions: 'control',
    useSystemCodexHome: false,
    platformCapabilities: PlatformCapabilities(environment: {'HOME': root.path}),
  );
  final seededHome = await seeded.setup();
  addTearDown(seeded.cleanup);
  expect(
    File(p.join(seededHome, 'auth.json')).readAsStringSync(),
    contains(_hostAuthJsonSentinel),
    reason: 'control: the seeded lifecycle must copy this source, or the auth-clean assertion proves nothing',
  );
}

void main() {
  late Directory root;
  late _RecordingCodexContainer container;

  setUp(() {
    root = Directory.systemTemp.createTempSync('codex-container-');
    container = _RecordingCodexContainer(hostRoot: root.path);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('containerized Codex placement', () {
    test('spawns the image binary inside the container, not on the host', () async {
      final harness = _harness(container);
      await _start(harness, container);

      expect(container.startCount, 1);
      final spawn = container.commands.last;
      expect(spawn.first, containerCodexExecutable);
      expect(spawn, contains('app-server'));
      // The host path the harness was configured with never reaches the image.
      expect(spawn.first, isNot(equals('codex')));

      await harness.stop();
    });

    test('translates the working directory into the container', () async {
      final harness = _harness(container);
      await _start(harness, container);

      expect(container.workingDirectories.last, _RecordingCodexContainer.containerWorkspace);
      // Never the host path the harness was constructed with.
      expect(container.workingDirectories.last, isNot(equals(container.hostRoot)));

      await harness.stop();
    });

    test('disables the Codex OS sandbox – the container is the boundary', () async {
      final harness = _harness(container);
      await _start(harness, container);

      // Codex's own sandbox tooling cannot start under the container
      // hardening, and its failure mode is a completed turn with every tool
      // call silently panicking – so the spawn must always widen to
      // danger-full-access inside the boundary.
      final spawn = container.commands.last.join(' ');
      expect(spawn, contains('sandbox_permissions=["disk-full-read-write-access", "network-full-access"]'));

      await harness.stop();
    });

    test('falls back to the profile working directory when nothing is mounted', () async {
      // The restricted profile mounts no workspace on purpose, so an unmapped
      // default cwd is expected – and a host path must not stand in for it.
      final unmounted = _RecordingCodexContainer(hostRoot: root.path, mountsWorkspace: false);
      final harness = _harness(unmounted);
      await _start(harness, unmounted);

      expect(unmounted.workingDirectories.last, unmounted.workingDir);
      expect(unmounted.workingDirectories.last, isNot(equals(unmounted.hostRoot)));

      await harness.stop();
    });

    test('rejects before spawning when the packaged CLI cannot run', () async {
      final unrunnable = _RecordingCodexContainer(hostRoot: root.path, executableRunnable: false);
      final harness = _harness(unrunnable);

      await expectLater(harness.start(), throwsA(isA<UnsupportedCapabilityError>()));
      // Only the probe ran: no app-server process was ever started.
      expect(unrunnable.commands.every((command) => command.last == '--version'), isTrue);
      expect(unrunnable.spawned, isNull);
    });
  });

  group('auth-clean container home', () {
    test('is created fresh and unseeded even from a credentialed host home', () async {
      await _plantCredentialedHostHome(root);

      final harness = _harness(container);
      await _start(harness, container);

      expect(container.codexHome.existsSync(), isTrue);
      final names = container.codexHome.listSync().map((entry) => p.basename(entry.path)).toSet();
      expect(names, {'config.toml'});
      expect(File(p.join(container.codexHome.path, 'auth.json')).existsSync(), isFalse);
      expect(container.codexConfig, isNot(contains(_hostAuthJsonSentinel)));

      await harness.stop();
    });

    test('selects the custom Responses provider with client auth disabled', () async {
      final harness = _harness(container);
      await _start(harness, container);

      final config = container.codexConfig;
      expect(config, contains('model_provider = "dartclaw"'));
      expect(config, contains('[model_providers.dartclaw]'));
      expect(config, contains('base_url = "http://127.0.0.1:8080/v1"'));
      expect(config, contains('wire_api = "responses"'));
      expect(config, contains('requires_openai_auth = false'));
      // The container never learns a real provider destination.
      expect(config, isNot(contains('api.openai.com')));

      await harness.stop();
    });

    test('points CODEX_HOME at the container path and exports nothing else', () async {
      final harness = _harness(container);
      await _start(harness, container);

      final env = container.environments.last!;
      expect(env, {'CODEX_HOME': '${_RecordingCodexContainer.containerStateRoot}/codex-home'});

      await harness.stop();
    });

    test('is deleted when the harness stops', () async {
      final harness = _harness(container);
      await _start(harness, container);
      expect(container.codexHome.existsSync(), isTrue);

      await harness.stop();

      expect(container.codexHome.existsSync(), isFalse);
    });

    test('is deleted when startup fails after the home was written', () async {
      final failing = _RecordingCodexContainer(hostRoot: root.path);
      final harness = CodexHarness(
        cwd: failing.hostRoot,
        containerManager: failing,
        environment: const {},
        commandProbe: (exe, args) async => throw StateError('unused'),
        delayFactory: noOpDelay,
        killGracePeriod: Duration.zero,
        initializeTimeout: const Duration(milliseconds: 50),
      );

      // No initialize response is ever emitted, so the handshake times out.
      await expectLater(harness.start(), throwsA(isA<StateError>()));

      expect(Directory(p.join(failing.generatedStateDir, 'codex-home')).existsSync(), isFalse);
    });
  });

  group('scoped MCP and native web', () {
    test('names only the execution bridge and carries no shared bearer', () async {
      final scoped = _RecordingCodexContainer(hostRoot: root.path, mcpBridgeUrl: 'http://127.0.0.1:8081/mcp');
      final harness = _harness(
        scoped,
        harnessConfig: const HarnessConfig(
          mcpServerUrl: 'http://127.0.0.1:3000/mcp',
          mcpGatewayToken: _sharedMcpBearerSentinel,
        ),
      );
      await _start(harness, scoped);

      final config = scoped.codexConfig;
      expect(config, contains('[mcp_servers.dartclaw]'));
      expect(config, contains('url = "http://127.0.0.1:8081/mcp"'));
      expect(config, isNot(contains('127.0.0.1:3000')));
      expect(config, isNot(contains('bearer_token_env_var')));
      expect(config, isNot(contains(_sharedMcpBearerSentinel)));
      expect(scoped.environments.last, isNot(contains('DARTCLAW_MCP_TOKEN')));

      await harness.stop();
    });

    test('configures no MCP server when the authority was granted no tools', () async {
      final harness = _harness(
        container,
        harnessConfig: const HarnessConfig(
          mcpServerUrl: 'http://127.0.0.1:3000/mcp',
          mcpGatewayToken: _sharedMcpBearerSentinel,
        ),
      );
      await _start(harness, container);

      expect(container.codexConfig, isNot(contains('mcp_servers')));

      await harness.stop();
    });

    test('disables provider-native web search for a restricted container', () async {
      final harness = _harness(container);
      await _start(harness, container);

      expect(container.codexConfig, contains('web_search = false'));

      await harness.stop();
    });

    test('disables provider-native web search for a workspace container too', () async {
      // Web search runs at the provider, so `network:none` cannot contain it in
      // any profile and the host gateway 403s every request declaring one.
      // Leaving it on for workspace would make each turn fail at the gateway.
      final workspace = _RecordingCodexContainer(hostRoot: root.path, profileId: 'workspace');
      final harness = _harness(workspace);
      await _start(harness, workspace);

      expect(workspace.codexConfig, contains('web_search = false'));

      await harness.stop();
    });
  });

  test('no host credential reaches any container-visible surface', () async {
    final scoped = _RecordingCodexContainer(hostRoot: root.path, mcpBridgeUrl: 'http://127.0.0.1:8081/mcp');
    final harness = _harness(
      scoped,
      harnessConfig: const HarnessConfig(
        mcpServerUrl: 'http://127.0.0.1:3000/mcp',
        mcpGatewayToken: _sharedMcpBearerSentinel,
      ),
    );
    await _start(harness, scoped);

    const sentinels = [_hostApiKeySentinel, _hostAuthJsonSentinel, _sharedMcpBearerSentinel];
    final surfaces = <String>[
      for (final command in scoped.commands) command.join('\n'),
      for (final environment in scoped.environments)
        environment?.entries.map((entry) => '${entry.key}=${entry.value}').join('\n') ?? '',
      for (final entry in scoped.codexHome.listSync().whereType<File>()) entry.readAsStringSync(),
    ];
    for (final surface in surfaces) {
      for (final sentinel in sentinels) {
        expect(surface, isNot(contains(sentinel)));
      }
    }

    await harness.stop();
  });
}
