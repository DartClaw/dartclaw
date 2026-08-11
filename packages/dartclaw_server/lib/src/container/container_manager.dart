import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_bridge/dartclaw_bridge.dart' show BridgeSurface;
import 'package:dartclaw_core/dartclaw_core.dart' show ContainerExecutor, canonicalizePathWithExistingAncestors;
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

/// Container mount point for one authority's generated client configuration.
const containerGeneratedStatePath = '/home/dartclaw/.dartclaw';

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

  /// Create and start the container with security flags.
  @override
  Future<void> start() async {
    if (await isHealthy()) {
      _log.info('Container $containerName ($profileId) already running');
      return;
    }

    // Remove stale container if exists
    await _run('docker', ['rm', '-f', containerName]);
    _validateLocalPathProjectMounts();
    await _createGeneratedStateDir();

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
      '-e', 'ANTHROPIC_BASE_URL=$providerBridgeUrl',
      ...effectiveExtraMounts.expand((m) => ['-v', m]),
      ...config.extraArgs,
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
  /// name is never reused, so nothing else would ever reclaim it — the caller
  /// has to hear about it.
  Future<void> stop() async {
    await _run('docker', ['stop', '-t', '5', containerName]);
    final removal = await _run('docker', ['rm', '-f', containerName]);
    // Generated state is deleted whether or not removal succeeded: a leaked
    // container must not also leave a readable generated home behind.
    await _deleteGeneratedStateDir();
    if (removal.exitCode != 0 && await isHealthy()) {
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

  /// Restricted containers keep non-workspace mounts but never get access to
  /// the project/workspace filesystem via extra mounts.
  List<String> get effectiveExtraMounts => profileId == 'restricted'
      ? config.extraMounts.where((mount) => !_isWorkspaceRelatedMount(mount)).toList(growable: false)
      : config.extraMounts;

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

  /// Check if the container is running.
  Future<bool> isHealthy() async {
    final result = await _run('docker', ['inspect', '--format', '{{.State.Running}}', containerName]);
    return result.exitCode == 0 && (result.stdout as String).trim() == 'true';
  }

  bool _hasContainerMountTarget(String containerPath) {
    for (final mount in [...workspaceMounts, ...effectiveExtraMounts, _generatedStateMount]) {
      final parts = mount.split(':');
      if (parts.length >= 2 && parts[1] == containerPath) {
        return true;
      }
    }
    return false;
  }

  bool _isWorkspaceRelatedMount(String mount) {
    final parts = mount.split(':');
    if (parts.length < 2) return false;
    return parts[1] == '/project' || parts[1] == '/workspace';
  }

  /// Translates a host path into the corresponding container path for a mounted directory.
  ///
  /// Returns null when the host path is not covered by any configured mount.
  @override
  String? containerPathForHostPath(String hostPath) {
    final normalizedHostPath = canonicalizePathWithExistingAncestors(hostPath);
    for (final mount in [...workspaceMounts, ...effectiveExtraMounts, _generatedStateMount]) {
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
