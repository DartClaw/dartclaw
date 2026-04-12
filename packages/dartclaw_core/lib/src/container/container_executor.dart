import 'dart:io';

/// Path to the Claude binary inside the container image.
const containerClaudeExecutable = '/home/dartclaw/.local/bin/claude';

/// Minimal container execution seam consumed by core harnesses.
abstract interface class ContainerExecutor {
  String get profileId;

  String get workingDir;

  bool get hasProjectMount;

  Future<void> start();

  Future<void> copyFileToContainer(String hostPath, String containerPath);

  Future<void> deleteFileInContainer(String containerPath);

  Future<Process> exec(List<String> command, {Map<String, String>? env, String? workingDirectory});

  String? containerPathForHostPath(String hostPath);
}
