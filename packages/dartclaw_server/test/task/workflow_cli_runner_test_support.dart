import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' show ExecutionPolicy;
import 'package:dartclaw_core/dartclaw_core.dart' show CanonicalTool, ContainerExecutor, EventBus;
import 'package:dartclaw_server/dartclaw_server.dart'
    show
        ContainerAuthorityLease,
        ContainerAuthorityProvider,
        WorkflowCliProviderConfig,
        WorkflowCliRunner,
        containerArtifactsPath;
import 'package:dartclaw_server/src/task/cli_provider.dart' show CliProvider, CliTurnRequest;
import 'package:dartclaw_server/src/task/workflow_cli_runner.dart'
    show WorkflowCliProcessStarter, WorkflowCliTurnResult;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeProcess, makeVersionProbeProcess;
import 'package:test/test.dart';

const readOnlyShellAllow = [
  'Bash(git ls-files)',
  'Bash(git rev-parse --abbrev-ref HEAD)',
  'Bash(git rev-parse --show-toplevel)',
  'Bash(git status --porcelain)',
  'Bash(git status --short)',
  'Bash(git status)',
  'Bash(pwd)',
  'Glob',
  'Grep',
  'LS',
  'Read',
];

const writeDeny = ['Edit', 'NotebookEdit', 'Write'];

const itemsSchema = {
  'type': 'object',
  'additionalProperties': false,
  'required': ['items'],
  'properties': {
    'items': {
      'type': 'array',
      'items': {
        'type': 'object',
        'additionalProperties': false,
        'required': ['path'],
        'properties': {
          'path': {'type': 'string'},
        },
      },
    },
  },
};

Future<Process> printfProcess(String stdout) =>
    Process.start('/bin/sh', ['-lc', "printf '%s' '${stdout.replaceAll("'", "'\\''")}'"]);

WorkflowCliProcessStarter claudeStub({
  Map<String, dynamic> result = const {'session_id': 'claude-session', 'result': 'ok'},
  void Function(String exe, List<String> args)? onArgs,
}) {
  return (exe, args, {workingDirectory, environment}) async {
    onArgs?.call(exe, List<String>.from(args));
    final lines = <String>[
      jsonEncode({'type': 'system', 'subtype': 'init', 'session_id': result['session_id'] ?? 'sess'}),
      jsonEncode({'type': 'result', ...result}),
    ];
    return printfProcess(lines.join('\n'));
  };
}

WorkflowCliProcessStarter codexStub({
  required List<Map<String, dynamic>> events,
  void Function(String exe, List<String> args)? onArgs,
}) {
  return (exe, args, {workingDirectory, environment}) async {
    onArgs?.call(exe, List<String>.from(args));
    return printfProcess(events.map(jsonEncode).join('\n'));
  };
}

/// Canonical-name grant filter mirroring the deleted package-level derivation.
///
/// The real deny/servable derivation is owned by `HarnessWiring` and tested
/// there; container runners here inject this so [WorkflowCliRunner] does not
/// fail closed for lack of a resolver. Records the acquire when a test needs to
/// assert the step leased exactly one container.
Set<String> testBridgedMcpTools(List<String>? allowedTools) {
  if (allowedTools == null || allowedTools.isEmpty) return const {};
  final canonicalNames = {
    for (final tool in CanonicalTool.values)
      if (tool != CanonicalTool.mcpCall) tool.stableName,
  };
  return allowedTools.map((tool) => tool.trim()).where(canonicalNames.contains).toSet();
}

/// Leases [container] once per step, recording each acquire (via
/// [grantedMcpTools]) and each [released] so a test can prove one container is
/// held for the whole step and released exactly once.
ContainerAuthorityProvider fakeContainerAuthorities(
  ContainerExecutor container, {
  List<String>? released,
  List<Set<String>>? grantedMcpTools,
  List<String?>? mountedArtifactsDirs,
}) => (principal, {Set<String> allowedMcpTools = const {}, String? artifactsDir}) async {
  grantedMcpTools?.add(allowedMcpTools);
  mountedArtifactsDirs?.add(artifactsDir);
  // The real authority mounts the artifacts dir when it creates the container,
  // so the fake only becomes able to translate that path once leased with one.
  if (container is FakeContainerExecutor) container.artifactsDir = artifactsDir;
  await container.start();
  return FakeContainerAuthorityLease(container, released ?? <String>[], principal.sessionId);
};

/// A lease over a pre-built container executor.
final class FakeContainerAuthorityLease implements ContainerAuthorityLease {
  FakeContainerAuthorityLease(this.container, this.released, this.sessionId);

  @override
  final ContainerExecutor container;

  final List<String> released;
  final String sessionId;

  @override
  Future<void> release() async => released.add(sessionId);
}

WorkflowCliRunner claudeRunner({
  WorkflowCliProcessStarter? processStarter,
  Map<String, dynamic> options = const {},
  ContainerExecutor? container,
  EventBus? eventBus,
  List<Set<String>>? grantedMcpTools,
  Set<String> Function(List<String>? allowedTools)? bridgedMcpToolsResolver,
}) {
  return WorkflowCliRunner(
    providers: {'claude': WorkflowCliProviderConfig(executable: 'claude', options: options)},
    containerAuthorities: container == null
        ? null
        : fakeContainerAuthorities(container, grantedMcpTools: grantedMcpTools),
    bridgedMcpToolsResolver: container == null ? null : (bridgedMcpToolsResolver ?? testBridgedMcpTools),
    eventBus: eventBus,
    processStarter: processStarter,
  );
}

WorkflowCliRunner codexRunner({
  WorkflowCliProcessStarter? processStarter,
  Map<String, dynamic> options = const {},
  ContainerExecutor? container,
  EventBus? eventBus,
  List<Set<String>>? grantedMcpTools,
  Set<String> Function(List<String>? allowedTools)? bridgedMcpToolsResolver,
}) {
  return WorkflowCliRunner(
    providers: {'codex': WorkflowCliProviderConfig(executable: 'codex', options: options)},
    containerAuthorities: container == null
        ? null
        : fakeContainerAuthorities(container, grantedMcpTools: grantedMcpTools),
    bridgedMcpToolsResolver: container == null ? null : (bridgedMcpToolsResolver ?? testBridgedMcpTools),
    eventBus: eventBus,
    processStarter: processStarter,
  );
}

Future<List<String>> capturedClaudeArgs({
  Map<String, dynamic> options = const {},
  List<String>? allowedTools,
  bool readOnly = false,
  String prompt = 'Review this',
}) async {
  late List<String> arguments;
  final runner = claudeRunner(
    options: options,
    processStarter: claudeStub(
      result: {'session_id': 'claude-session', 'result': 'ok'},
      onArgs: (exe, args) => arguments = args,
    ),
  );
  await runner.executeTurn(
    provider: 'claude',
    prompt: prompt,
    workingDirectory: Directory.systemTemp.path,
    policy: const ExecutionPolicy.host(),
    allowedTools: allowedTools,
    readOnly: readOnly,
  );
  return arguments;
}

Map<String, dynamic> decodedClaudeSettings(List<String> arguments) {
  final settingsIndex = arguments.indexOf('--settings');
  expect(settingsIndex, isNonNegative);
  return jsonDecode(arguments[settingsIndex + 1]) as Map<String, dynamic>;
}

class FakeCliProvider implements CliProvider {
  const FakeCliProvider(this.onRun);

  final void Function() onRun;

  @override
  Future<WorkflowCliTurnResult> run(CliTurnRequest request) async {
    onRun();
    return WorkflowCliTurnResult(providerSessionId: 'fake-session', responseText: 'fake-response', newInputTokens: 0);
  }

  @override
  Future<void> cancelInflight({bool cancelFutureProcesses = false}) async {}
}

class SigkillOnlyFakeProcess extends FakeProcess {
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killCalled = true;
    lastKillSignal = signal;
    killSignals.add(signal);
    if (signal == ProcessSignal.sigkill) {
      super.exit(-9);
    }
    return true;
  }
}

final class RecordingCliProvider implements CliProvider {
  final requests = <CliTurnRequest>[];

  @override
  Future<WorkflowCliTurnResult> run(CliTurnRequest request) async {
    requests.add(request);
    return WorkflowCliTurnResult(providerSessionId: 'recorded-session', responseText: 'ok', newInputTokens: 0);
  }

  @override
  Future<void> cancelInflight({bool cancelFutureProcesses = false}) async {}
}

class FakeContainerExecutor implements ContainerExecutor {
  FakeContainerExecutor({
    required this.hostRoot,
    required this.containerRoot,
    this.profileId = 'workspace',
    this.mcpBridgeUrl,
    this.executableRunnable = true,
    String? stdout,
  }) : generatedStateDir = Directory('$hostRoot/.dartclaw-state').absolute.path,
       stdout =
           stdout ??
           '${jsonEncode({'type': 'thread.started', 'thread_id': 'codex-thread-1'})}\n'
               '${jsonEncode({
                 'type': 'item.completed',
                 'item': {
                   'type': 'agent_message',
                   'text': jsonEncode({
                     'items': [
                       {'path': 'lib/main.dart'},
                     ],
                   }),
                 },
               })}';

  @override
  final String profileId;

  @override
  final String workingDir = '/workspace';

  @override
  final bool hasProjectMount = true;

  @override
  final String generatedStateDir;

  @override
  final String providerBridgeUrl = 'http://127.0.0.1:8080';

  @override
  final String? mcpBridgeUrl;

  /// `false` fakes an image whose packaged CLI cannot run.
  final bool executableRunnable;

  final String hostRoot;
  final String containerRoot;
  final String stdout;

  /// Host artifacts dir the leasing authority mounted, mapped to `/artifacts`.
  String? artifactsDir;
  late List<String> lastCommand;
  String? lastWorkingDirectory;
  Map<String, String>? lastEnv;

  /// Observes the spawn while its generated state still exists – the authority
  /// destroys that state as soon as the turn ends.
  void Function(List<String> command)? onExec;

  @override
  Future<void> start() async {
    Directory(generatedStateDir).createSync(recursive: true);
  }

  @override
  Future<Process> exec(List<String> command, {Map<String, String>? env, String? workingDirectory}) async {
    lastCommand = List<String>.from(command);
    lastWorkingDirectory = workingDirectory;
    lastEnv = env == null ? null : Map<String, String>.from(env);
    if (command.length == 2 && command[1] == '--version') {
      return executableRunnable ? makeVersionProbeProcess('1.0.0') : makeVersionProbeProcess('', exitCode: 127);
    }
    onExec?.call(lastCommand);
    final escapedStdout = stdout.replaceAll("'", "'\\''");
    return Process.start('/bin/sh', ['-lc', "printf '%s' '$escapedStdout'"]);
  }

  @override
  String? containerPathForHostPath(String hostPath) {
    final normalizedHostPath = File(hostPath).absolute.path;
    final artifacts = artifactsDir;
    if (artifacts != null) {
      final normalizedArtifacts = Directory(artifacts).absolute.path;
      if (normalizedHostPath == normalizedArtifacts) return containerArtifactsPath;
      if (normalizedHostPath.startsWith('$normalizedArtifacts${Platform.pathSeparator}')) {
        final relative = normalizedHostPath.substring(normalizedArtifacts.length + 1).replaceAll('\\', '/');
        return '$containerArtifactsPath/$relative';
      }
    }
    final normalizedHostRoot = Directory(hostRoot).absolute.path;
    if (normalizedHostPath == normalizedHostRoot) {
      return containerRoot;
    }
    if (!normalizedHostPath.startsWith('$normalizedHostRoot${Platform.pathSeparator}')) {
      return null;
    }
    final relative = normalizedHostPath.substring(normalizedHostRoot.length + 1).replaceAll('\\', '/');
    return '$containerRoot/$relative';
  }
}
