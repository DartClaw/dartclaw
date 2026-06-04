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
          final payload = jsonEncode({
            'session_id': 'claude-provider-test',
            'result': 'hello',
            'input_tokens': 5,
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
      expect(arguments, containsAll(['-p', '--output-format', 'json']));
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
          final payload = jsonEncode({
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
        stdout: jsonEncode({'session_id': 'claude-container-provider', 'result': 'ok'}),
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

    test('non-zero exit surfaces the stdout result-JSON diagnostic, not just the stderr warning', () async {
      final runner = WorkflowCliRunner(
        providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          // claude -p reports turn errors in the stdout result JSON; stderr
          // carries only the benign env-scrub warning. Exit 1.
          final payload = jsonEncode({
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
    : stdout = stdout ?? jsonEncode({'session_id': 'fake', 'result': 'ok'});

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
