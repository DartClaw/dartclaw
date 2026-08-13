import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_bridge/dartclaw_bridge.dart' show BridgeSurface;
import 'package:dartclaw_core/dartclaw_core.dart'
    show ContainerExecutor, canonicalizePathWithExistingAncestors, containerGeneratedStatePath, containerImageUidGid;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:dartclaw_models/dartclaw_models.dart' show ContainerConfig;

import 'bridge_binary.dart';
import 'gateway/gateway_models.dart';
import 'gateway/process_bridge_channel.dart';

/// Testable callback used for one-shot CLI commands such as `docker inspect`.
typedef RunCommand = Future<ProcessResult> Function(String executable, List<String> arguments);

/// Testable callback used for long-lived processes such as `docker exec -i`.
typedef StartCommand =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment,
    });

/// Three-valued container liveness.
///
/// [unknown] is the load-bearing state: a `docker inspect` that fails to reach
/// the daemon (or errors for any reason other than an explicit "no such
/// object") proves nothing about the container and must never be read as death.
enum ContainerHealth { running, notRunning, unknown }

/// Thrown when a container authority's container has been lost and cannot be
/// reattached, so the execution needs a fresh authority.
///
/// A named subtype of [StateError] — existing callers that catch [StateError]
/// keep their behavior, while the primary lane and tests can match this cause
/// specifically instead of a bare internal error.
class ContainerAuthorityLostException extends StateError {
  ContainerAuthorityLostException({required this.containerName, required this.profileId})
    : super(
        'Container $containerName ($profileId) is no longer running and cannot be reattached: its host bridges died '
        'with it, so this execution must acquire a new container authority.',
      );

  final String containerName;
  final String profileId;
}

/// Container mount point for the host-owned artifacts directory an execution
/// writes its durable outputs to.
const containerArtifactsPath = '/artifacts';

/// Manages Docker container lifecycle for agent isolation.
///
/// Uses `docker create` + `docker start` for fast container restart,
/// and `docker exec` for each turn to avoid per-turn container startup.
class ContainerManager implements ContainerExecutor {
  static final _log = Logger('ContainerManager');

  final ContainerConfig config;
  final String containerName;
  @override
  final String profileId;
  final List<String> workspaceMounts;
  final List<String> localPathAllowlist;

  /// Host path of the Linux bridge executable delivered read-only into the
  /// container, or `null` when this deployment has no host mediation.
  final String? bridgeBinaryPath;

  @override
  final String generatedStateDir;

  /// Host directory this execution writes durable artifacts to, mounted
  /// read-write at [containerArtifactsPath].
  ///
  /// The host computes the path, creates it, and reads the results back after
  /// the execution, so it must be reachable from inside the boundary. `null`
  /// when the execution has no artifacts contract.
  final String? artifactsDir;

  /// Whether this authority was granted host MCP tools, which is what decides
  /// if an MCP bridge exists to configure a client against.
  final bool hasMcpBridge;

  final String buildContextDir;
  @override
  final String workingDir;
  final RunCommand _run;
  final StartCommand _start;

  ContainerManager({
    required this.config,
    required this.containerName,
    required this.profileId,
    required this.workspaceMounts,
    required this.generatedStateDir,
    this.artifactsDir,
    this.hasMcpBridge = false,
    this.localPathAllowlist = const [],
    this.bridgeBinaryPath,
    String? buildContextDir,
    this.workingDir = '/project',
    RunCommand? runCommand,
    StartCommand? startCommand,
  }) : buildContextDir = buildContextDir ?? Directory.current.path,
       _run = runCommand ?? Process.run,
       _start = startCommand ?? Process.start;

  @override
  String get providerBridgeUrl => 'http://127.0.0.1:$providerBridgePort';

  @override
  String? get mcpBridgeUrl => hasMcpBridge ? 'http://127.0.0.1:$mcpBridgePort/mcp' : null;

  /// The generated-state mount, written as a Docker `-v` spec.
  String get _generatedStateMount => '$generatedStateDir:$containerGeneratedStatePath:rw';

  /// The artifacts mount, written as a Docker `-v` spec, when one exists.
  String? get _artifactsMount => artifactsDir == null ? null : '$artifactsDir:$containerArtifactsPath:rw';

  /// Every host object this container can see, as Docker `-v` specs.
  List<String> get _allMounts => [...workspaceMounts, _generatedStateMount, ?_artifactsMount];

  /// Format: `dartclaw-<stableHash(dataDir)>-<profileId>`
  static String generateName(String dataDir, String profileId) {
    final hash = _stableHexHash(dataDir);
    return 'dartclaw-$hash-$profileId';
  }

  // FNV-1a is sufficient here: we need a deterministic, Docker-safe suffix
  // for local container names, not a cryptographic digest.
  static String _stableHexHash(String value) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(value)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  /// Check if Docker is available and running.
  Future<bool> isDockerAvailable() async {
    try {
      final result = await _run('docker', ['version']);
      return result.exitCode == 0;
    } catch (e) {
      _log.fine('Docker not available: $e');
      return false;
    }
  }

  /// Ensure the container image exists (build or pull).
  Future<void> ensureImage() async {
    final result = await _run('docker', ['image', 'inspect', config.image]);
    if (result.exitCode == 0) {
      _log.info('Container image ${config.image} found for $profileId');
      return;
    }
    _log.info('Building container image ${config.image} for $profileId...');
    final dockerContextDir = p.join(buildContextDir, 'docker');
    final buildResult = await _run('docker', ['build', '-t', config.image, dockerContextDir]);
    if (buildResult.exitCode != 0) {
      throw StateError('Failed to build Docker image: ${buildResult.stderr}');
    }
  }

  /// Whether this manager has already created (or adopted) its container.
  bool _created = false;

  /// Create and start the container with security flags.
  ///
  /// Single-use: once a container exists, a later call either finds it healthy
  /// or throws. A container authority is one container, one pipe set, one
  /// lifetime — the bridges are `docker exec` processes that died with the
  /// container and host-gateway revocation is permanent, so recreating the
  /// container here would hand a harness a live shell behind dead mediation.
  /// The execution must acquire a new authority instead.
  @override
  Future<void> start() async {
    if (config.extraMounts.isNotEmpty) {
      throw StateError('container.mounts is unsupported because arbitrary host mounts bypass the execution boundary');
    }
    if (config.extraArgs.isNotEmpty) {
      throw StateError('container.extra_args is unsupported because raw Docker arguments bypass mandatory hardening');
    }
    if (await health() == ContainerHealth.running) {
      _log.info('Container $containerName ($profileId) already running');
      _created = true;
      return;
    }
    if (_created) {
      throw ContainerAuthorityLostException(containerName: containerName, profileId: profileId);
    }

    // Remove stale container if exists
    await _run('docker', ['rm', '-f', containerName]);
    _validateLocalPathProjectMounts();
    await _createGeneratedStateDir();
    // Bind-mount ownership passes through verbatim on native Linux, so the
    // artifacts dir must be owned by the image uid or the container cannot
    // write its outputs. The dir is created host-side before this point.
    if (artifactsDir case final dir?) {
      await _chownToImageUid(dir);
    }

    final args = [
      'create',
      '--name', containerName,
      '--network', 'none',
      '--cap-drop', 'ALL',
      '--read-only',
      '--tmpfs', '/tmp:rw,noexec,nosuid,size=100m',
      '--security-opt', 'no-new-privileges',
      ...workspaceMounts.expand((mount) => ['-v', mount]),
      // The only host object the container gets is a read-only executable the
      // host controls: no socket, no writable channel, no network attachment.
      if (bridgeBinaryPath != null) ...['-v', '$bridgeBinaryPath:${BridgeBinaryProvisioner.containerPath}:ro'],
      // Per-authority scratch for generated client configuration. No host home
      // is ever mounted: provider login state stays outside the boundary.
      '-v', _generatedStateMount,
      // Host-owned artifacts destination: the execution writes its durable
      // outputs where the host reads them back from, inside the boundary.
      if (_artifactsMount case final mount?) ...['-v', mount],
      '-e', 'ANTHROPIC_BASE_URL=$providerBridgeUrl',
      config.image,
      'sleep', 'infinity', // Keep container alive for docker exec
    ];

    final createResult = await _run('docker', args);
    if (createResult.exitCode != 0) {
      throw StateError('Failed to create container: ${createResult.stderr}');
    }

    final startResult = await _run('docker', ['start', containerName]);
    if (startResult.exitCode != 0) {
      throw StateError('Failed to start container: ${startResult.stderr}');
    }

    _created = true;
    _log.info('Container $containerName ($profileId) started');
  }

  /// Reports the Docker engine's architecture, which decides which bridge
  /// variant the container can execute.
  ///
  /// The engine, not the host process, is authoritative: a macOS arm64 host
  /// can run an amd64 Linux engine.
  Future<String?> serverArchitecture() async {
    final result = await _run('docker', ['version', '--format', '{{.Server.Arch}}']);
    if (result.exitCode != 0) return null;
    return BridgeBinaryProvisioner.architectureFor(result.stdout as String);
  }

  /// Starts one long-lived in-container bridge process for [surface].
  ///
  /// The returned channel *is* the authority for that surface: it exists only
  /// as long as this process does, and nothing inside the container can create
  /// another one.
  Future<BridgeChannel> startBridge(BridgeSurface surface, int port) async {
    if (bridgeBinaryPath == null) {
      throw StateError('Container $containerName has no bridge binary, so it cannot reach host mediation');
    }
    final process = await _start('docker', [
      'exec',
      '-i',
      containerName,
      BridgeBinaryProvisioner.containerPath,
      '--surface=${surface.name}',
      '--port=$port',
    ], includeParentEnvironment: true);
    return ProcessBridgeChannel(process, label: '$containerName/${surface.name}');
  }

  /// Stop and remove the container.
  ///
  /// Throws when removal cannot be confirmed. A container that outlives its
  /// authority still holds that authority's mounts and root process, and its
  /// name is never reused, so the owning authority must retain it for retry.
  Future<void> stop() async {
    await _run('docker', ['stop', '-t', '5', containerName]);
    final removal = await _run('docker', ['rm', '-f', containerName]);
    // Generated state is deleted whether or not removal succeeded: a leaked
    // container must not also leave a readable generated home behind.
    await _deleteGeneratedStateDir();
    // Only an explicitly-confirmed absence lets a failed removal pass: a daemon
    // error is `unknown`, and admitting it as success would leak a live
    // container (with its mounts) while returning its capacity.
    if (removal.exitCode != 0 && await health() != ContainerHealth.notRunning) {
      throw StateError('Failed to destroy container $containerName: ${removal.stderr}');
    }
    _log.info('Container $containerName ($profileId) stopped and removed');
  }

  /// Creates an empty, owner-only generated-state directory.
  ///
  /// Recreated from scratch on every start so a restarted container cannot
  /// inherit configuration written for an earlier one.
  Future<void> _createGeneratedStateDir() async {
    final directory = Directory(generatedStateDir);
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
    await directory.create(recursive: true);
    if (!Platform.isWindows) {
      final result = await Process.run('chmod', ['700', generatedStateDir]);
      if (result.exitCode != 0) {
        throw StateError('Failed to restrict permissions on $generatedStateDir: ${result.stderr}');
      }
      await _chownToImageUid(generatedStateDir);
    }
  }

  /// Best-effort chown of a per-authority host mount dir to the image uid so the
  /// container's uid-1000 `dartclaw` user owns the bind-mounted state.
  ///
  /// On native Linux bind-mount ownership is verbatim, so a host service uid
  /// other than 1000 hands the container mounts it cannot use — every
  /// containerized turn's state write and the `/artifacts` write fail. Chowning
  /// the host side to 1000 is the standard bind-mount-uid fix and keeps the
  /// container running as the user its image was built for.
  ///
  /// Best-effort on purpose: this fixes the privileged-host case (root or
  /// CAP_CHOWN), which succeeds silently. An unprivileged host cannot chown to
  /// another uid — including every Docker Desktop run, where the mount works
  /// regardless via uid remapping — so a failure is logged at fine and not
  /// thrown; throwing would regress those working deployments. An unprivileged
  /// non-1000 host still cannot use the mount, surfacing later as the turn's own
  /// write failure (the pre-existing state), and rootless/userns-remapped Docker
  /// is the fix there.
  Future<void> _chownToImageUid(String dir) async {
    if (Platform.isWindows) return;
    final result = await _run('chown', [containerImageUidGid, dir]);
    if (result.exitCode != 0) {
      _log.fine('Could not chown $dir to $containerImageUidGid (host may lack CAP_CHOWN): ${result.stderr}');
    }
  }

  Future<void> _deleteGeneratedStateDir() async {
    try {
      final directory = Directory(generatedStateDir);
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } catch (error, stackTrace) {
      _log.warning('Failed to delete generated state for $containerName', error, stackTrace);
    }
  }

  @override
  bool get hasProjectMount => _hasContainerMountTarget('/project');

  /// Execute a command inside the running container, returning a Process
  /// for JSONL communication.
  @override
  Future<Process> exec(List<String> command, {Map<String, String>? env, String? workingDirectory}) async {
    final envArgs = <String>[];
    if (env != null) {
      for (final entry in env.entries) {
        envArgs.addAll(['-e', '${entry.key}=${entry.value}']);
      }
    }

    // Keep the host PATH so the parent process can resolve `docker`; this does
    // not affect the environment inside the container.
    return _start('docker', [
      'exec',
      '-i',
      '-w',
      workingDirectory ?? workingDir,
      ...envArgs,
      containerName,
      ...command,
    ], includeParentEnvironment: true);
  }

  void _validateLocalPathProjectMounts() {
    if (localPathAllowlist.isEmpty) {
      return;
    }

    final normalizedAllowlist = localPathAllowlist.map(canonicalizePathWithExistingAncestors).toList(growable: false);
    for (final mount in workspaceMounts) {
      final parts = mount.split(':');
      if (parts.length < 2) continue;
      final hostPath = canonicalizePathWithExistingAncestors(parts[0]);
      final containerPath = parts[1];
      if (!containerPath.startsWith('/projects/')) {
        continue;
      }
      final allowed = normalizedAllowlist.any((root) => p.equals(hostPath, root) || p.isWithin(root, hostPath));
      if (!allowed) {
        throw StateError('Refusing to mount local project path outside allowlist: $hostPath');
      }
    }
  }

  /// Reports whether the container is running, not running, or unknown.
  ///
  /// A zero-exit `docker inspect` is authoritative (`true`/anything else). A
  /// non-zero exit is only proof of death when Docker says so explicitly ("no
  /// such object"); a daemon-connection or other inspect failure is [unknown]
  /// and callers must not treat it as death.
  Future<ContainerHealth> health() async {
    final result = await _run('docker', ['inspect', '--format', '{{.State.Running}}', containerName]);
    if (result.exitCode == 0) {
      return (result.stdout as String).trim() == 'true' ? ContainerHealth.running : ContainerHealth.notRunning;
    }
    return _confirmsAbsence(result.stderr) ? ContainerHealth.notRunning : ContainerHealth.unknown;
  }

  /// Check if the container is confirmed running.
  Future<bool> isHealthy() async => await health() == ContainerHealth.running;

  /// Whether Docker's stderr explicitly reports the container is absent. Only
  /// this — never a bare non-zero exit — confirms a not-running state; anything
  /// else (a daemon-connection failure) stays [ContainerHealth.unknown].
  static bool _confirmsAbsence(Object? stderr) {
    final text = (stderr is String ? stderr : stderr?.toString() ?? '').toLowerCase();
    return text.contains('no such object') || text.contains('no such container');
  }

  bool _hasContainerMountTarget(String containerPath) {
    for (final mount in _allMounts) {
      final parts = mount.split(':');
      if (parts.length >= 2 && parts[1] == containerPath) {
        return true;
      }
    }
    return false;
  }

  /// Translates a host path into the corresponding container path for a mounted directory.
  ///
  /// Returns null when the host path is not covered by any configured mount.
  @override
  String? containerPathForHostPath(String hostPath) {
    final normalizedHostPath = canonicalizePathWithExistingAncestors(hostPath);
    for (final mount in _allMounts) {
      final parts = mount.split(':');
      if (parts.length < 2) continue;
      final hostRoot = canonicalizePathWithExistingAncestors(parts[0]);
      final containerRoot = parts[1];
      if (normalizedHostPath == hostRoot) {
        return containerRoot;
      }
      if (!p.isWithin(hostRoot, normalizedHostPath)) {
        continue;
      }
      final relative = p.relative(normalizedHostPath, from: hostRoot);
      return p.posix.join(containerRoot, p.posix.normalize(relative.replaceAll(r'\', '/')));
    }
    return null;
  }
}
