import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:path/path.dart' as p;
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

    test('forwards appendSystemPrompt to Claude when provided', () async {
      late List<String> arguments;
      final runner = WorkflowCliRunner(
        providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          arguments = List<String>.from(args);
          final stdout = jsonEncode({'session_id': 'claude-session-append', 'result': 'ok'}).replaceAll("'", "'\\''");
          return Process.start('/bin/sh', ['-lc', "printf '%s' '$stdout'"]);
        },
      );

      await runner.executeTurn(
        provider: 'claude',
        prompt: 'Review this',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
        appendSystemPrompt: 'Follow the workflow rules',
      );

      expect(arguments, contains('--append-system-prompt'));
      expect(arguments, contains('Follow the workflow rules'));
    });

    test('builds Claude one-shot args with permissionMode and structured settings', () async {
      late List<String> arguments;
      final runner = WorkflowCliRunner(
        providers: const {
          'claude': WorkflowCliProviderConfig(
            executable: 'claude',
            options: {
              'permissionMode': 'dontAsk',
              'sandbox': {'enabled': true, 'autoAllowBashIfSandboxed': true},
              'permissions': {
                'allow': ['Bash(git *)'],
              },
            },
          ),
        },
        processStarter: (exe, args, {workingDirectory, environment}) async {
          arguments = List<String>.from(args);
          final stdout = jsonEncode({'session_id': 'claude-session-2', 'result': 'ok'}).replaceAll("'", "'\\''");
          return Process.start('/bin/sh', ['-lc', "printf '%s' '$stdout'"]);
        },
      );

      await runner.executeTurn(
        provider: 'claude',
        prompt: 'Review this',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
      );

      expect(arguments, containsAll(['--setting-sources', 'project']));
      expect(arguments, containsAll(['--permission-mode', 'dontAsk']));
      expect(arguments, isNot(contains('--dangerously-skip-permissions')));
      final settingsIndex = arguments.indexOf('--settings');
      expect(settingsIndex, isNonNegative);
      final decoded = jsonDecode(arguments[settingsIndex + 1]) as Map<String, dynamic>;
      expect(decoded['sandbox'], {'enabled': true, 'autoAllowBashIfSandboxed': true});
      expect(decoded['permissions'], {
        'allow': ['Bash(git *)'],
      });
    });

    test('preserves path-based Claude settings when structured overlays are also configured', () async {
      late List<String> arguments;
      final runner = WorkflowCliRunner(
        providers: const {
          'claude': WorkflowCliProviderConfig(
            executable: 'claude',
            options: {
              'settings': '/tmp/claude-settings.json',
              'sandbox': {'enabled': true},
            },
          ),
        },
        processStarter: (exe, args, {workingDirectory, environment}) async {
          arguments = List<String>.from(args);
          final stdout = jsonEncode({'session_id': 'claude-session-path', 'result': 'ok'}).replaceAll("'", "'\\''");
          return Process.start('/bin/sh', ['-lc', "printf '%s' '$stdout'"]);
        },
      );

      await runner.executeTurn(
        provider: 'claude',
        prompt: 'Review this',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
      );

      final settingsIndex = arguments.indexOf('--settings');
      expect(arguments[settingsIndex + 1], '/tmp/claude-settings.json');
    });

    test('merges base Claude settings with structured sandbox and permissions', () async {
      late List<String> arguments;
      final runner = WorkflowCliRunner(
        providers: const {
          'claude': WorkflowCliProviderConfig(
            executable: 'claude',
            options: {
              'settings': {
                'permissions': {'defaultMode': 'plan'},
                'sandbox': {'failIfUnavailable': true},
              },
              'sandbox': {'enabled': true},
              'permissions': {
                'allow': ['Bash(git *)'],
              },
            },
          ),
        },
        processStarter: (exe, args, {workingDirectory, environment}) async {
          arguments = List<String>.from(args);
          final stdout = jsonEncode({'session_id': 'claude-session-3', 'result': 'ok'}).replaceAll("'", "'\\''");
          return Process.start('/bin/sh', ['-lc', "printf '%s' '$stdout'"]);
        },
      );

      await runner.executeTurn(
        provider: 'claude',
        prompt: 'Review this',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
      );

      final settingsIndex = arguments.indexOf('--settings');
      final decoded = jsonDecode(arguments[settingsIndex + 1]) as Map<String, dynamic>;
      expect(decoded['permissions'], {
        'defaultMode': 'plan',
        'allow': ['Bash(git *)'],
      });
      expect(decoded['sandbox'], {'failIfUnavailable': true, 'enabled': true});
    });

    test('merges raw JSON Claude settings string with structured sandbox and permissions', () async {
      late List<String> arguments;
      final runner = WorkflowCliRunner(
        providers: const {
          'claude': WorkflowCliProviderConfig(
            executable: 'claude',
            options: {
              'settings': '{"permissions":{"defaultMode":"plan"},"sandbox":{"failIfUnavailable":true}}',
              'sandbox': {'enabled': true},
              'permissions': {
                'allow': ['Bash(git *)'],
              },
            },
          ),
        },
        processStarter: (exe, args, {workingDirectory, environment}) async {
          arguments = List<String>.from(args);
          final stdout = jsonEncode({'session_id': 'claude-session-raw', 'result': 'ok'}).replaceAll("'", "'\\''");
          return Process.start('/bin/sh', ['-lc', "printf '%s' '$stdout'"]);
        },
      );

      await runner.executeTurn(
        provider: 'claude',
        prompt: 'Review this',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
      );

      final settingsIndex = arguments.indexOf('--settings');
      final decoded = jsonDecode(arguments[settingsIndex + 1]) as Map<String, dynamic>;
      expect(decoded['permissions'], {
        'defaultMode': 'plan',
        'allow': ['Bash(git *)'],
      });
      expect(decoded['sandbox'], {'failIfUnavailable': true, 'enabled': true});
    });

    test('rejects interactive Claude permission modes in one-shot mode', () async {
      final runner = WorkflowCliRunner(
        providers: const {
          'claude': WorkflowCliProviderConfig(executable: 'claude', options: {'permissionMode': 'plan'}),
        },
        processStarter: (exe, args, {workingDirectory, environment}) async {
          final stdout = jsonEncode({'session_id': 'claude-session-4', 'result': 'ok'}).replaceAll("'", "'\\''");
          return Process.start('/bin/sh', ['-lc', "printf '%s' '$stdout'"]);
        },
      );

      await expectLater(
        () => runner.executeTurn(
          provider: 'claude',
          prompt: 'Review this',
          workingDirectory: Directory.systemTemp.path,
          profileId: 'workspace',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('does not support interactive permissionMode "plan"'),
          ),
        ),
      );
    });

    test('rejects unsupported Claude permissionMode values in one-shot mode', () async {
      final runner = WorkflowCliRunner(
        providers: const {
          'claude': WorkflowCliProviderConfig(executable: 'claude', options: {'permissionMode': 'dontask'}),
        },
      );

      await expectLater(
        () => runner.executeTurn(
          provider: 'claude',
          prompt: 'Review this',
          workingDirectory: Directory.systemTemp.path,
          profileId: 'workspace',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Unsupported Claude permissionMode "dontask"'),
          ),
        ),
      );
    });

    test('rejects non-string Claude permissionMode values in one-shot mode', () async {
      final runner = WorkflowCliRunner(
        providers: const {
          'claude': WorkflowCliProviderConfig(executable: 'claude', options: {'permissionMode': 7}),
        },
      );

      await expectLater(
        () => runner.executeTurn(
          provider: 'claude',
          prompt: 'Review this',
          workingDirectory: Directory.systemTemp.path,
          profileId: 'workspace',
        ),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('Unsupported Claude permissionMode'))),
      );
    });

    test('does not force project setting sources for containerized Claude one-shot runs', () async {
      final workingDirectory = await Directory.systemTemp.createTemp('workflow-cli-runner-claude-container');
      addTearDown(() async {
        if (await workingDirectory.exists()) {
          await workingDirectory.delete(recursive: true);
        }
      });

      final container = _FakeContainerExecutor(
        hostRoot: workingDirectory.path,
        containerRoot: '/workspace',
        stdout: jsonEncode({'session_id': 'claude-session-container', 'result': 'ok'}),
      );
      final runner = WorkflowCliRunner(
        providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
        containerManagers: {'workspace': container},
      );

      await runner.executeTurn(
        provider: 'claude',
        prompt: 'Review this',
        workingDirectory: workingDirectory.path,
        profileId: 'workspace',
      );

      expect(container.lastCommand, isNot(contains('--setting-sources')));
      expect(container.lastWorkingDirectory, '/workspace');
    });

    test('translates path-based Claude settings for containerized one-shot runs', () async {
      final workingDirectory = await Directory.systemTemp.createTemp('workflow-cli-runner-claude-settings-container');
      addTearDown(() async {
        if (await workingDirectory.exists()) {
          await workingDirectory.delete(recursive: true);
        }
      });

      final settingsPath = p.join(workingDirectory.path, 'claude-settings.json');
      File(settingsPath).writeAsStringSync('{}');

      final container = _FakeContainerExecutor(
        hostRoot: workingDirectory.path,
        containerRoot: '/workspace',
        stdout: jsonEncode({'session_id': 'claude-session-settings-container', 'result': 'ok'}),
      );
      final runner = WorkflowCliRunner(
        providers: {
          'claude': WorkflowCliProviderConfig(
            executable: 'claude',
            options: {
              'settings': settingsPath,
              'sandbox': {'enabled': true},
            },
          ),
        },
        containerManagers: {'workspace': container},
      );

      await runner.executeTurn(
        provider: 'claude',
        prompt: 'Review this',
        workingDirectory: workingDirectory.path,
        profileId: 'workspace',
      );

      final settingsIndex = container.lastCommand.indexOf('--settings');
      expect(settingsIndex, isNonNegative);
      expect(container.lastCommand[settingsIndex + 1], '/workspace/claude-settings.json');
    });

    test('translates plain path-based Claude settings for containerized one-shot runs without overlays', () async {
      final workingDirectory = await Directory.systemTemp.createTemp('workflow-cli-runner-claude-settings-plain');
      addTearDown(() async {
        if (await workingDirectory.exists()) {
          await workingDirectory.delete(recursive: true);
        }
      });

      final settingsPath = p.join(workingDirectory.path, 'claude-settings.json');
      File(settingsPath).writeAsStringSync('{}');

      final container = _FakeContainerExecutor(
        hostRoot: workingDirectory.path,
        containerRoot: '/workspace',
        stdout: jsonEncode({'session_id': 'claude-session-settings-plain', 'result': 'ok'}),
      );
      final runner = WorkflowCliRunner(
        providers: {
          'claude': WorkflowCliProviderConfig(executable: 'claude', options: {'settings': settingsPath}),
        },
        containerManagers: {'workspace': container},
      );

      await runner.executeTurn(
        provider: 'claude',
        prompt: 'Review this',
        workingDirectory: workingDirectory.path,
        profileId: 'workspace',
      );

      final settingsIndex = container.lastCommand.indexOf('--settings');
      expect(settingsIndex, isNonNegative);
      expect(container.lastCommand[settingsIndex + 1], '/workspace/claude-settings.json');
    });

    test('translates relative path-based Claude settings for containerized one-shot runs', () async {
      final workingDirectory = await Directory.systemTemp.createTemp('workflow-cli-runner-claude-settings-relative');
      addTearDown(() async {
        if (await workingDirectory.exists()) {
          await workingDirectory.delete(recursive: true);
        }
      });

      final settingsPath = p.join(workingDirectory.path, '.claude', 'settings.json');
      Directory(p.dirname(settingsPath)).createSync(recursive: true);
      File(settingsPath).writeAsStringSync('{}');

      final container = _FakeContainerExecutor(
        hostRoot: workingDirectory.path,
        containerRoot: '/workspace',
        stdout: jsonEncode({'session_id': 'claude-session-settings-relative', 'result': 'ok'}),
      );
      final runner = WorkflowCliRunner(
        providers: const {
          'claude': WorkflowCliProviderConfig(executable: 'claude', options: {'settings': '.claude/settings.json'}),
        },
        containerManagers: {'workspace': container},
      );

      await runner.executeTurn(
        provider: 'claude',
        prompt: 'Review this',
        workingDirectory: workingDirectory.path,
        profileId: 'workspace',
      );

      final settingsIndex = container.lastCommand.indexOf('--settings');
      expect(settingsIndex, isNonNegative);
      expect(container.lastCommand[settingsIndex + 1], '/workspace/.claude/settings.json');
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
      expect(result.inputTokens, 20);
      expect(result.cacheReadTokens, 4);
      expect(result.newInputTokens, 16);
    });

    test('Codex turn.completed uses assignment semantics for cumulative usage', () async {
      final stdout = [
        jsonEncode({'type': 'thread.started', 'thread_id': 'codex-thread-2'}),
        jsonEncode({
          'type': 'turn.completed',
          'usage': {'input_tokens': 119659, 'output_tokens': 1900, 'cache_read_tokens': 115000},
        }),
        jsonEncode({
          'type': 'turn.completed',
          'usage': {'input_tokens': 121000, 'output_tokens': 2000, 'cache_read_tokens': 116000},
        }),
      ].join('\n');
      final runner = WorkflowCliRunner(
        providers: const {'codex': WorkflowCliProviderConfig(executable: 'codex')},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          return Process.start('/bin/sh', ['-lc', "printf '%s' '${stdout.replaceAll("'", "'\\''")}'"]);
        },
      );

      final result = await runner.executeTurn(
        provider: 'codex',
        prompt: 'List changed files',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
      );

      expect(result.inputTokens, 121000);
      expect(result.outputTokens, 2000);
      expect(result.cacheReadTokens, 116000);
      expect(result.newInputTokens, 5000);
    });

    test('forwards appendSystemPrompt to Codex via developer_instructions override', () async {
      late List<String> arguments;
      final stdout = [
        jsonEncode({'type': 'thread.started', 'thread_id': 'codex-thread-append'}),
        jsonEncode({'type': 'turn.completed'}),
      ].join('\n');
      final runner = WorkflowCliRunner(
        providers: const {'codex': WorkflowCliProviderConfig(executable: 'codex')},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          arguments = List<String>.from(args);
          return Process.start('/bin/sh', ['-lc', "printf '%s' '${stdout.replaceAll("'", "'\\''")}'"]);
        },
      );

      await runner.executeTurn(
        provider: 'codex',
        prompt: 'List changed files',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
        appendSystemPrompt: 'Keep responses strict',
      );

      expect(arguments, contains('-c'));
      expect(
        arguments.any((arg) => arg.startsWith('developer_instructions=') && arg.contains('Keep responses strict')),
        isTrue,
      );
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
  final String stdout;
  late List<String> lastCommand;
  String? lastWorkingDirectory;

  _FakeContainerExecutor({required this.hostRoot, required this.containerRoot, String? stdout})
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
