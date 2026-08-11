import 'dart:io';

/// Path to the Claude binary inside the container image.
const containerClaudeExecutable = '/home/dartclaw/.local/bin/claude';

/// Path to the Codex binary inside the container image.
const containerCodexExecutable = '/home/dartclaw/.local/bin/codex';

/// Minimal container execution seam consumed by core harnesses.
abstract interface class ContainerExecutor {
  String get profileId;

  String get workingDir;

  bool get hasProjectMount;

  /// Container-loopback base URL of this authority's provider bridge.
  ///
  /// The only destination a containerized provider client may be pointed at.
  /// What it reaches is bound host-side to the pipe, never chosen here.
  String get providerBridgeUrl;

  /// Container-loopback base URL of this authority's MCP bridge, or `null`
  /// when the authority was granted no host MCP tools.
  ///
  /// `null` means the surface does not exist, so a client configured against it
  /// would fail closed rather than reach an unauthorized tool.
  String? get mcpBridgeUrl;

  /// Host directory bind-mounted read-write for this authority's generated
  /// client configuration.
  ///
  /// Created empty by [start] and destroyed with the container, so nothing
  /// written here outlives the authority. Never a user home.
  String get generatedStateDir;

  Future<void> start();

  Future<Process> exec(List<String> command, {Map<String, String>? env, String? workingDirectory});

  String? containerPathForHostPath(String hostPath);
}

/// Whether [executable] actually runs inside [container].
///
/// A missing or unrunnable image binary is statically detectable, so callers
/// reject admission on `false` rather than let it surface later as a dead pipe
/// in the middle of a turn.
Future<bool> containerExecutableRuns(ContainerExecutor container, String executable) async {
  final Process process;
  try {
    process = await container.exec([executable, '--version']);
  } on ProcessException {
    return false;
  }
  try {
    await process.stdin.close();
  } catch (_) {} // The probe writes nothing; a closed stdin is not a failure.
  final stdout = process.stdout.transform(const SystemEncoding().decoder).join();
  final drained = process.stderr.drain<void>();
  final exitCode = await process.exitCode;
  await drained;
  return exitCode == 0 && (await stdout).trim().isNotEmpty;
}
