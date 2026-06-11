import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

void main() {
  group('ClaudeCliProvider', () {
    test('happy path: command vector contains expected flags', () async {
      late String executable;
      late List<String> arguments;
      final runner = WorkflowCliRunner(
        providers: const {
          'claude': WorkflowCliProviderConfig(executable: 'claude', options: {'permissionMode': 'dontAsk'}),
        },
        processStarter: (exe, args, {workingDirectory, environment}) async {
          executable = exe;
          arguments = List<String>.from(args);
          final payload = _streamJsonStdout({
            'session_id': 'claude-provider-test',
            'result': 'hello',
            'usage': {'input_tokens': 5, 'output_tokens': 2},
          }).replaceAll("'", "'\\''");
          return Process.start('/bin/sh', ['-lc', "printf '%s' '$payload'"]);
        },
      );

      await runner.executeTurn(
        provider: 'claude',
        prompt: 'Hi',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
        model: 'claude-opus-4',
        maxTurns: 3,
      );

      expect(executable, 'claude');
      expect(
        arguments,
        containsAll(['-p', '--output-format', 'stream-json', '--verbose', '--include-partial-messages']),
      );
      expect(arguments, containsAll(['--model', 'claude-opus-4']));
      expect(arguments, containsAll(['--max-turns', '3']));
      expect(arguments, isNot(contains('--setting-sources')));
      expect(arguments, isNot(contains('--dangerously-skip-permissions')));
      expect(arguments, containsAll(['--permission-mode', 'dontAsk']));
    });

    test('inherit_user_settings false adds project setting sources before model', () async {
      late List<String> arguments;
      final runner = WorkflowCliRunner(
        providers: const {
          'claude': WorkflowCliProviderConfig(executable: 'claude', options: {'inherit_user_settings': false}),
        },
        processStarter: (exe, args, {workingDirectory, environment}) async {
          arguments = List<String>.from(args);
          final payload = _streamJsonStdout({
            'session_id': 'claude-provider-test',
            'result': 'hello',
          }).replaceAll("'", "'\\''");
          return Process.start('/bin/sh', ['-lc', "printf '%s' '$payload'"]);
        },
      );

      await runner.executeTurn(
        provider: 'claude',
        prompt: 'Hi',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
        model: 'claude-opus-4',
      );

      final settingIndex = arguments.indexOf('--setting-sources');
      final modelIndex = arguments.indexOf('--model');
      expect(settingIndex, isNonNegative);
      expect(arguments[settingIndex + 1], 'project');
      expect(modelIndex, isNonNegative);
      expect(settingIndex, lessThan(modelIndex));
    });

    test('container manager: working directory translated to container path', () async {
      final workingDirectory = await Directory.systemTemp.createTemp('claude-provider-container');
      addTearDown(() async {
        if (await workingDirectory.exists()) await workingDirectory.delete(recursive: true);
      });

      final container = _FakeContainerExecutor(
        hostRoot: workingDirectory.path,
        containerRoot: '/workspace',
        stdout: _streamJsonStdout({'session_id': 'claude-container-provider', 'result': 'ok'}),
      );

      final runner = WorkflowCliRunner(
        providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
        containerManagers: {'workspace': container},
      );

      await runner.executeTurn(
        provider: 'claude',
        prompt: 'Test',
        workingDirectory: workingDirectory.path,
        profileId: 'workspace',
      );

      expect(container.lastWorkingDirectory, '/workspace');
      expect(container.lastCommand, isNot(contains('--setting-sources')));
    });

    test('parses tokens from the terminal result event usage map, ignoring earlier events', () async {
      late WorkflowCliTurnResult result;
      final runner = WorkflowCliRunner(
        providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          // Preceding stream events (including a decoy with conflicting token
          // fields) must be skipped; only the terminal `result` event counts.
          final payload = _streamJsonStdout(
            {
              'session_id': 'claude-usage-test',
              'result': 'done',
              'total_cost_usd': 0.5,
              'usage': {
                'input_tokens': 11,
                'output_tokens': 22,
                'cache_read_input_tokens': 33,
                'cache_creation_input_tokens': 44,
              },
            },
            events: [
              {
                'type': 'assistant',
                'usage': {'input_tokens': 999, 'output_tokens': 999},
              },
            ],
          ).replaceAll("'", "'\\''");
          return Process.start('/bin/sh', ['-lc', "printf '%s' '$payload'"]);
        },
      );

      result = await runner.executeTurn(
        provider: 'claude',
        prompt: 'Hi',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
      );

      expect(result.responseText, 'done');
      expect(result.providerSessionId, 'claude-usage-test');
      expect(result.inputTokens, 11);
      expect(result.outputTokens, 22);
      expect(result.cacheReadTokens, 33);
      expect(result.cacheWriteTokens, 44);
      expect(result.totalCostUsd, 0.5);
    });

    test('non-zero exit surfaces the stdout result-JSON diagnostic, not just the stderr warning', () async {
      final runner = WorkflowCliRunner(
        providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          // claude -p reports turn errors in the stdout result JSON; stderr
          // carries only the benign env-scrub warning. Exit 1.
          final payload = _streamJsonStdout({
            'subtype': 'error_during_execution',
            'is_error': true,
            'result': 'reviewer panel crashed',
          }).replaceAll("'", "'\\''");
          const warning = 'Permission mode forced to default — CLAUDE_CODE_SUBPROCESS_ENV_SCRUB is set';
          return Process.start('/bin/sh', ['-lc', "printf '%s' '$payload'; printf '%s' '$warning' 1>&2; exit 1"]);
        },
      );

      await expectLater(
        runner.executeTurn(
          provider: 'claude',
          prompt: 'Review',
          workingDirectory: Directory.systemTemp.path,
          profileId: 'workspace',
        ),
        throwsA(
          isA<Object>().having(
            (e) => e.toString(),
            'message',
            allOf([
              contains('exit code 1'),
              contains('subtype=error_during_execution'),
              contains('is_error=true'),
              contains('result=reviewer panel crashed'),
            ]),
          ),
        ),
      );
    });
  });
}

/// Builds claude `--output-format stream-json` stdout: a leading `system/init`
/// event, any [events], then the terminal `result` event carrying [result]'s
/// fields. Mirrors the real CLI's NDJSON-per-line output.
String _streamJsonStdout(Map<String, dynamic> result, {List<Map<String, dynamic>> events = const []}) {
  final lines = <String>[
    jsonEncode({'type': 'system', 'subtype': 'init', 'session_id': result['session_id'] ?? 'sess'}),
    ...events.map(jsonEncode),
    jsonEncode({'type': 'result', ...result}),
  ];
  return lines.join('\n');
}

class _FakeContainerExecutor implements ContainerExecutor {
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

  _FakeContainerExecutor({required this.hostRoot, required this.containerRoot, String? stdout})
    : stdout = stdout ?? _streamJsonStdout({'session_id': 'fake', 'result': 'ok'});

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
    final escaped = stdout.replaceAll("'", "'\\''");
    return Process.start('/bin/sh', ['-lc', "printf '%s' '$escaped'"]);
  }

  @override
  String? containerPathForHostPath(String hostPath) {
    final normalizedHostPath = File(hostPath).absolute.path;
    final normalizedHostRoot = Directory(hostRoot).absolute.path;
    if (normalizedHostPath == normalizedHostRoot) return containerRoot;
    if (!normalizedHostPath.startsWith('$normalizedHostRoot${Platform.pathSeparator}')) return null;
    final relative = normalizedHostPath.substring(normalizedHostRoot.length + 1).replaceAll('\\', '/');
    return '$containerRoot/$relative';
  }
}
