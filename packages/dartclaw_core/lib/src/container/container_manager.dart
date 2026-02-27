import 'dart:io';

import 'package:logging/logging.dart';

import 'container_config.dart';

typedef RunCommand = Future<ProcessResult> Function(String executable, List<String> arguments);
typedef StartCommand = Future<Process> Function(
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
class ContainerManager {
  static final _log = Logger('ContainerManager');

  final ContainerConfig config;
  final String workspaceDir;
  final String projectDir;
  final String proxySocketDir;
  final RunCommand _run;
  final StartCommand _start;

  static const _containerName = 'dartclaw-agent';

  ContainerManager({
    required this.config,
    required this.workspaceDir,
    required this.projectDir,
    required this.proxySocketDir,
    RunCommand? runCommand,
    StartCommand? startCommand,
  }) : _run = runCommand ?? Process.run,
       _start = startCommand ?? Process.start;

  /// Check if Docker is available and running.
  Future<bool> isDockerAvailable() async {
    try {
      final result = await _run('docker', ['version']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Ensure the container image exists (build or pull).
  Future<void> ensureImage() async {
    final result = await _run('docker', ['image', 'inspect', config.image]);
    if (result.exitCode == 0) {
      _log.info('Container image ${config.image} found');
      return;
    }
    _log.info('Building container image ${config.image}...');
    final buildResult = await _run('docker', ['build', '-t', config.image, 'docker/']);
    if (buildResult.exitCode != 0) {
      throw StateError('Failed to build Docker image: ${buildResult.stderr}');
    }
  }

  /// Create and start the container with security flags.
  Future<void> start() async {
    // Remove stale container if exists
    await _run('docker', ['rm', '-f', _containerName]);

    final args = [
      'create',
      '--name', _containerName,
      '--network', 'none',
      '--cap-drop', 'ALL',
      '--read-only',
      '--tmpfs', '/tmp:rw,noexec,nosuid,size=100m',
      '--security-opt', 'no-new-privileges',
      '-v', '$workspaceDir:/workspace:rw',
      '-v', '$projectDir:/project:ro',
      '-v', '$proxySocketDir:/var/run/dartclaw',
      '-e', 'ANTHROPIC_BASE_URL=http+unix:///var/run/dartclaw/proxy.sock',
      ...config.extraMounts.expand((m) => ['-v', m]),
      ...config.extraArgs,
      config.image,
      'sleep', 'infinity', // Keep container alive for docker exec
    ];

    final createResult = await _run('docker', args);
    if (createResult.exitCode != 0) {
      throw StateError('Failed to create container: ${createResult.stderr}');
    }

    final startResult = await _run('docker', ['start', _containerName]);
    if (startResult.exitCode != 0) {
      throw StateError('Failed to start container: ${startResult.stderr}');
    }

    _log.info('Container $_containerName started');
  }

  /// Stop and remove the container.
  Future<void> stop() async {
    await _run('docker', ['stop', '-t', '5', _containerName]);
    await _run('docker', ['rm', '-f', _containerName]);
    _log.info('Container $_containerName stopped and removed');
  }

  /// Execute a command inside the running container, returning a Process
  /// for JSONL communication.
  Future<Process> exec(
    List<String> command, {
    Map<String, String>? env,
  }) async {
    final envArgs = <String>[];
    if (env != null) {
      for (final entry in env.entries) {
        envArgs.addAll(['-e', '${entry.key}=${entry.value}']);
      }
    }

    return _start(
      'docker',
      ['exec', '-i', ...envArgs, _containerName, ...command],
      includeParentEnvironment: false,
    );
  }

  /// Check if the container is running.
  Future<bool> isHealthy() async {
    final result = await _run('docker', ['inspect', '--format', '{{.State.Running}}', _containerName]);
    return result.exitCode == 0 && (result.stdout as String).trim() == 'true';
  }
}
