import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

void main() {
  group('WorkflowCliRunner', () {
    test('builds Claude one-shot args and parses structured output', () async {
      late String executable;
      late List<String> arguments;
      final runner = WorkflowCliRunner(
        providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          executable = exe;
          arguments = List<String>.from(args);
          return Process.start('/bin/sh', [
            '-lc',
            "printf '%s' '${jsonEncode({
              'session_id': 'claude-session-1',
              'input_tokens': 10,
              'output_tokens': 5,
              'cache_read_tokens': 3,
              'duration_ms': 1200,
              'structured_output': {
                'verdict': {'pass': true},
              },
            }).replaceAll("'", "'\\''")}'",
          ]);
        },
      );

      final result = await runner.executeTurn(
        provider: 'claude',
        prompt: 'Review this',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
        providerSessionId: 'previous-session',
        model: 'claude-opus-4',
        effort: 'high',
        maxTurns: 5,
        jsonSchema: const {
          'type': 'object',
          'additionalProperties': false,
          'required': ['verdict'],
          'properties': {
            'verdict': {
              'type': 'object',
              'additionalProperties': false,
              'required': ['pass'],
              'properties': {
                'pass': {'type': 'boolean'},
              },
            },
          },
        },
      );

      expect(executable, 'claude');
      expect(arguments, containsAll(['-p', '--output-format', 'json', '--resume', 'previous-session']));
      expect(arguments, contains('--json-schema'));
      expect(result.providerSessionId, 'claude-session-1');
      expect(result.structuredOutput?['verdict'], {'pass': true});
    });

    test('builds Codex one-shot args and parses JSONL final message', () async {
      late String executable;
      late List<String> arguments;
      final stdout = [
        jsonEncode({'type': 'thread.started', 'thread_id': 'codex-thread-1'}),
        jsonEncode({
          'type': 'item.completed',
          'item': {
            'type': 'agent_message',
            'text': jsonEncode({
              'items': [
                {'path': 'lib/main.dart'},
              ],
            }),
          },
        }),
        jsonEncode({
          'type': 'turn.completed',
          'usage': {'input_tokens': 20, 'output_tokens': 8, 'cache_read_tokens': 4},
        }),
      ].join('\n');
      final runner = WorkflowCliRunner(
        providers: const {
          'codex': WorkflowCliProviderConfig(executable: 'codex', options: {'sandbox': 'danger-full-access'}),
        },
        processStarter: (exe, args, {workingDirectory, environment}) async {
          executable = exe;
          arguments = List<String>.from(args);
          return Process.start('/bin/sh', ['-lc', "printf '%s' '${stdout.replaceAll("'", "'\\''")}'"]);
        },
      );

      final result = await runner.executeTurn(
        provider: 'codex',
        prompt: 'List changed files',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
        providerSessionId: 'thread-prev',
        model: 'gpt-5-codex',
        jsonSchema: const {
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
        },
      );

      expect(executable, 'codex');
      expect(arguments, containsAll(['exec', '--json', '--full-auto', '--skip-git-repo-check']));
      expect(arguments, contains('resume'));
      expect(arguments, contains('thread-prev'));
      expect(arguments, contains('--output-schema'));
      expect(result.providerSessionId, 'codex-thread-1');
      expect(result.structuredOutput?['items'], isA<List<dynamic>>());
    });

    test('deletes temporary Codex schema file after execution', () async {
      late List<String> arguments;
      late String schemaPath;
      final workingDirectory = await Directory.systemTemp.createTemp('workflow-cli-runner-test');
      addTearDown(() async {
        if (await workingDirectory.exists()) {
          await workingDirectory.delete(recursive: true);
        }
      });

      final stdout = [
        jsonEncode({'type': 'thread.started', 'thread_id': 'codex-thread-1'}),
        jsonEncode({
          'type': 'item.completed',
          'item': {
            'type': 'agent_message',
            'text': jsonEncode({
              'items': [
                {'path': 'lib/main.dart'},
              ],
            }),
          },
        }),
      ].join('\n');
      final escapedStdout = stdout.replaceAll("'", "'\\''");

      final runner = WorkflowCliRunner(
        providers: const {'codex': WorkflowCliProviderConfig(executable: 'codex')},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          arguments = List<String>.from(args);
          final schemaFlagIndex = arguments.indexOf('--output-schema');
          schemaPath = arguments[schemaFlagIndex + 1];
          expect(await File(schemaPath).exists(), isTrue);
          return Process.start('/bin/sh', ['-lc', "printf '%s' '$escapedStdout'"]);
        },
      );

      await runner.executeTurn(
        provider: 'codex',
        prompt: 'List changed files',
        workingDirectory: workingDirectory.path,
        profileId: 'workspace',
        jsonSchema: const {
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
        },
      );

      final schemaFlagIndex = arguments.indexOf('--output-schema');
      expect(schemaFlagIndex, isNonNegative);
      expect(await File(schemaPath).exists(), isFalse);
    });

    test('deletes temporary Codex schema file after failure', () async {
      late String schemaPath;
      final workingDirectory = await Directory.systemTemp.createTemp('workflow-cli-runner-test');
      addTearDown(() async {
        if (await workingDirectory.exists()) {
          await workingDirectory.delete(recursive: true);
        }
      });

      final runner = WorkflowCliRunner(
        providers: const {'codex': WorkflowCliProviderConfig(executable: 'codex')},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          final schemaFlagIndex = args.indexOf('--output-schema');
          schemaPath = args[schemaFlagIndex + 1];
          expect(await File(schemaPath).exists(), isTrue);
          return Process.start('/bin/sh', ['-lc', "printf '%s' 'schema failure' >&2; exit 1"]);
        },
      );

      await expectLater(
        () => runner.executeTurn(
          provider: 'codex',
          prompt: 'List changed files',
          workingDirectory: workingDirectory.path,
          profileId: 'workspace',
          jsonSchema: const {
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
          },
        ),
        throwsA(isA<StateError>()),
      );

      expect(await File(schemaPath).exists(), isFalse);
    });

    test('translates working directory and schema path for container execution', () async {
      final workingDirectory = await Directory.systemTemp.createTemp('workflow-cli-runner-test');
      addTearDown(() async {
        if (await workingDirectory.exists()) {
          await workingDirectory.delete(recursive: true);
        }
      });

      final container = _FakeContainerExecutor(hostRoot: workingDirectory.path, containerRoot: '/workspace');

      final runner = WorkflowCliRunner(
        providers: const {'codex': WorkflowCliProviderConfig(executable: 'codex')},
        containerManagers: {'workspace': container},
      );

      await runner.executeTurn(
        provider: 'codex',
        prompt: 'List changed files',
        workingDirectory: workingDirectory.path,
        profileId: 'workspace',
        jsonSchema: const {
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
        },
      );

      expect(container.lastWorkingDirectory, '/workspace');
      final schemaFlagIndex = container.lastCommand.indexOf('--output-schema');
      expect(schemaFlagIndex, isNonNegative);
      expect(container.lastCommand[schemaFlagIndex + 1], startsWith('/workspace/.dartclaw-codex-schema-'));
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
  late List<String> lastCommand;
  String? lastWorkingDirectory;

  _FakeContainerExecutor({required this.hostRoot, required this.containerRoot});

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
    return Process.start('/bin/sh', [
      '-lc',
      "printf '%s' '${jsonEncode({'type': 'thread.started', 'thread_id': 'codex-thread-1'}).replaceAll("'", "'\\''")}\n${jsonEncode({
        'type': 'item.completed',
        'item': {
          'type': 'agent_message',
          'text': jsonEncode({
            'items': [
              {'path': 'lib/main.dart'},
            ],
          }),
        },
      }).replaceAll("'", "'\\''")}'",
    ]);
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
