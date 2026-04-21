import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show ContainerExecutor;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:dartclaw_models/dartclaw_models.dart' show ContainerConfig;

import '../path_canonicalization.dart';

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

/// Manages Docker container lifecycle for agent isolation.
///
/// Uses `docker create` + `docker start` for fast container restart,
/// and `docker exec` for each turn to avoid per-turn container startup.
class ContainerManager implements ContainerExecutor {
  static final _log = Logger('ContainerManager');
  static const _proxyPort = 8080;

  final ContainerConfig config;
  final String containerName;
  @override
  final String profileId;
  final List<String> workspaceMounts;
  final List<String> localPathAllowlist;
  final String proxySocketDir;
  final String? hostClaudeJsonPath;
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
    this.localPathAllowlist = const [],
    required this.proxySocketDir,
    this.hostClaudeJsonPath,
    String? buildContextDir,
    this.workingDir = '/project',
    RunCommand? runCommand,
    StartCommand? startCommand,
  }) : buildContextDir = buildContextDir ?? Directory.current.path,
       _run = runCommand ?? Process.run,
       _start = startCommand ?? Process.start;

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

    final args = [
      'create',
      '--name', containerName,
      '--network', 'none',
      '--cap-drop', 'ALL',
      '--read-only',
      '--tmpfs', '/tmp:rw,noexec,nosuid,size=100m',
      '--security-opt', 'no-new-privileges',
      ...workspaceMounts.expand((mount) => ['-v', mount]),
      '-v', '$proxySocketDir:/var/run/dartclaw',
      if (hostClaudeJsonPath != null) ...['-v', '$hostClaudeJsonPath:/home/dartclaw/.claude.json:ro'],
      '-e', 'ANTHROPIC_BASE_URL=http://localhost:$_proxyPort',
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

    await startSocatBridge();
    _log.info('Container $containerName ($profileId) started');
  }

  /// Start the in-container TCP-to-Unix-socket bridge for Claude API requests.
  Future<void> startSocatBridge() async {
    final result = await _run('docker', [
      'exec',
      '-d',
      containerName,
      'socat',
      'TCP-LISTEN:$_proxyPort,fork,reuseaddr',
      'UNIX-CLIENT:/var/run/dartclaw/proxy.sock',
    ]);
    if (result.exitCode != 0) {
      throw StateError('Failed to start socat bridge: ${result.stderr}');
    }
  }

  /// Stop and remove the container.
  Future<void> stop() async {
    await _run('docker', ['stop', '-t', '5', containerName]);
    await _run('docker', ['rm', '-f', containerName]);
    _log.info('Container $containerName ($profileId) stopped and removed');
  }

  /// Restricted containers keep non-workspace mounts but never get access to
  /// the project/workspace filesystem via extra mounts.
  List<String> get effectiveExtraMounts => profileId == 'restricted'
      ? config.extraMounts.where((mount) => !_isWorkspaceRelatedMount(mount)).toList(growable: false)
      : config.extraMounts;

  @override
  bool get hasProjectMount => _hasContainerMountTarget('/project');

  @override
  Future<void> copyFileToContainer(String hostPath, String containerPath) async {
    final result = await _run('docker', ['cp', hostPath, '$containerName:$containerPath']);
    if (result.exitCode != 0) {
      throw StateError('Failed to copy file into container: ${result.stderr}');
    }
  }

  @override
  Future<void> deleteFileInContainer(String containerPath) async {
    final result = await _run('docker', ['exec', containerName, 'rm', '-f', containerPath]);
    if (result.exitCode != 0) {
      throw StateError('Failed to delete file in container: ${result.stderr}');
    }
  }

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
    for (final mount in [...workspaceMounts, ...effectiveExtraMounts]) {
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
    for (final mount in [...workspaceMounts, ...effectiveExtraMounts]) {
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
