import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show ContainerExecutor, EventBus;
import 'package:dartclaw_server/dartclaw_server.dart' show WorkflowCliProviderConfig, WorkflowCliRunner;
import 'package:dartclaw_server/src/task/cli_provider.dart' show CliProvider, CliTurnRequest;
import 'package:dartclaw_server/src/task/workflow_cli_runner.dart'
    show WorkflowCliProcessStarter, WorkflowCliTurnResult;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeProcess;
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

WorkflowCliRunner claudeRunner({
  WorkflowCliProcessStarter? processStarter,
  Map<String, dynamic> options = const {},
  Map<String, ContainerExecutor> containerManagers = const {},
  EventBus? eventBus,
}) {
  return WorkflowCliRunner(
    providers: {'claude': WorkflowCliProviderConfig(executable: 'claude', options: options)},
    containerManagers: containerManagers,
    eventBus: eventBus,
    processStarter: processStarter,
  );
}

WorkflowCliRunner codexRunner({
  WorkflowCliProcessStarter? processStarter,
  Map<String, dynamic> options = const {},
  Map<String, ContainerExecutor> containerManagers = const {},
  EventBus? eventBus,
}) {
  return WorkflowCliRunner(
    providers: {'codex': WorkflowCliProviderConfig(executable: 'codex', options: options)},
    containerManagers: containerManagers,
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
    profileId: 'workspace',
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
  FakeContainerExecutor({required this.hostRoot, required this.containerRoot, String? stdout})
    : stdout =
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
  final String profileId = 'workspace';

  @override
  final String workingDir = '/workspace';

  @override
  final bool hasProjectMount = true;

  final String hostRoot;
  final String containerRoot;
  final String stdout;
  late List<String> lastCommand;
  String? lastWorkingDirectory;

  @override
  Future<void> start() async {}

  @override
  Future<void> copyFileToContainer(String hostPath, String containerPath) async {}

  @override
  Future<void> deleteFileInContainer(String containerPath) async {}

  @override
  Future<Process> exec(List<String> command, {Map<String, String>? env, String? workingDirectory}) async {
    lastCommand = List<String>.from(command);
    lastWorkingDirectory = workingDirectory;
    final escapedStdout = stdout.replaceAll("'", "'\\''");
    return Process.start('/bin/sh', ['-lc', "printf '%s' '$escapedStdout'"]);
  }

  @override
  String? containerPathForHostPath(String hostPath) {
    final normalizedHostPath = File(hostPath).absolute.path;
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
