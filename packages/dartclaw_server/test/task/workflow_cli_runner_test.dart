import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_server/src/task/cli_process_supervisor.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeProcess;
import 'package:fake_async/fake_async.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'workflow_cli_runner_test_support.dart';

void main() {
  group('WorkflowCliRunner', () {
    Future<({Directory workingDirectory, String settingsPath, FakeContainerExecutor container})>
    claudeSettingsContainerFixture(String name, {String relativeSettingsPath = 'claude-settings.json'}) async {
      final workingDirectory = await Directory.systemTemp.createTemp(name);
      addTearDown(() async {
        if (await workingDirectory.exists()) {
          await workingDirectory.delete(recursive: true);
        }
      });

      final settingsPath = p.join(workingDirectory.path, relativeSettingsPath);
      Directory(p.dirname(settingsPath)).createSync(recursive: true);
      File(settingsPath).writeAsStringSync('{}');

      return (
        workingDirectory: workingDirectory,
        settingsPath: settingsPath,
        container: FakeContainerExecutor(
          hostRoot: workingDirectory.path,
          containerRoot: '/workspace',
          stdout: jsonEncode({'session_id': 'claude-session-settings', 'result': 'ok'}),
        ),
      );
    }

    test('builds Claude one-shot args and parses structured output', () async {
      late String executable;
      late List<String> arguments;
      final runner = claudeRunner(
        processStarter: claudeStub(
          onArgs: (exe, args) {
            executable = exe;
            arguments = args;
          },
          result: {
            'session_id': 'claude-session-1',
            'input_tokens': 10,
            'output_tokens': 5,
            'cache_read_tokens': 3,
            'duration_ms': 1200,
            'structured_output': {
              'verdict': {'pass': true},
            },
          },
        ),
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
      expect(arguments, containsAll(['-p', '--output-format', 'stream-json', '--resume', 'previous-session']));
      expect(arguments, contains('--json-schema'));
      expect(result.providerSessionId, 'claude-session-1');
      expect(result.structuredOutput?['verdict'], {'pass': true});
      expect(result.inputTokens, 10);
      expect(result.cacheReadTokens, 3);
      expect(result.newInputTokens, 10);
    });

    test('forwards appendSystemPrompt to Claude when provided', () async {
      late List<String> arguments;
      final runner = claudeRunner(
        processStarter: claudeStub(
          result: {'session_id': 'claude-session-append', 'result': 'ok'},
          onArgs: (exe, args) => arguments = args,
        ),
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

    test('Codex parser tolerates mixed prose plus workflow-context markup', () async {
      final runner = codexRunner(
        processStarter: codexStub(
          events: [
            {'type': 'thread.started', 'thread_id': 'codex-thread-1'},
            {'type': 'turn.started'},
            {
              'type': 'item.completed',
              'item': {
                'id': 'item_0',
                'type': 'agent_message',
                'text':
                    '{"stories":{"items":[{"id":"S01","title":"Story"}]}}'
                    '\n<workflow-context>{"plan":"docs/specs/test/plan.md"}</workflow-context>',
              },
            },
            {
              'type': 'turn.completed',
              'usage': {'input_tokens': 12, 'output_tokens': 7},
            },
          ],
        ),
      );

      final result = await runner.executeTurn(
        provider: 'codex',
        prompt: 'Plan this',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
      );

      expect(result.providerSessionId, 'codex-thread-1');
      expect(result.responseText, contains('<workflow-context>'));
      expect(result.structuredOutput, isNull);
      expect(result.inputTokens, 12);
      expect(result.outputTokens, 7);
    });

    test('dispatches custom provider aliases by configured family', () async {
      final provider = RecordingCliProvider();
      final runner = WorkflowCliRunner(
        providers: const {
          'my_agent': WorkflowCliProviderConfig(
            executable: '/opt/bin/custom-codex',
            environment: {'ALIAS_ENV': '1'},
            options: {'family': 'codex', 'sandbox': 'read-only'},
          ),
        },
        providerImpls: {'codex': provider},
      );

      final result = await runner.executeTurn(
        provider: 'my_agent',
        prompt: 'Review this',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
      );

      expect(result.providerSessionId, 'recorded-session');
      expect(provider.requests, hasLength(1));
      expect(provider.requests.single.providerConfig.executable, '/opt/bin/custom-codex');
      expect(provider.requests.single.providerConfig.environment, {'ALIAS_ENV': '1'});
      expect(provider.requests.single.providerConfig.options['sandbox'], 'read-only');
    });

    test('codex stall monitor starts at subprocess start and kills silent process on cancel', () {
      fakeAsync((async) {
        late FakeProcess fake;
        final eventBus = EventBus();
        final stallEvents = <WorkflowCliStallEvent>[];
        final sub = eventBus.on<WorkflowCliStallEvent>().listen(stallEvents.add);
        final runner = codexRunner(
          eventBus: eventBus,
          processStarter: (exe, args, {workingDirectory, environment}) async {
            fake = FakeProcess(completeExitOnKill: true, killExitCode: -1);
            return fake;
          },
        );

        Object? error;
        unawaited(
          runner
              .executeTurn(
                provider: 'codex',
                prompt: 'silent',
                workingDirectory: Directory.systemTemp.path,
                profileId: 'workspace',
                stepName: 'Implement',
                stallTimeout: const Duration(seconds: 10),
                stallAction: TurnProgressAction.cancel,
              )
              .then<void>((_) => fail('silent process should not complete'), onError: (Object e) => error = e),
        );

        async.flushMicrotasks();
        expect(fake.killCalled, isFalse);
        async.elapse(const Duration(seconds: 9));
        async.flushMicrotasks();
        expect(error, isNull);

        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();

        expect(fake.killCalled, isTrue);
        expect(error, isA<WorkflowCliStallException>());
        expect(stallEvents, hasLength(1));
        expect(stallEvents.single.stepName, 'Implement');
        expect(stallEvents.single.action, 'cancel');
        unawaited(sub.cancel());
        unawaited(eventBus.dispose());
      });
    });

    test('stall cancellation escalates and reports failure only after the process exits', () {
      fakeAsync((async) {
        final fake = SigkillOnlyFakeProcess();
        final supervisor = CliProcessSupervisor(
          process: fake,
          provider: 'codex',
          stepName: 'Escalate',
          stallTimeout: const Duration(seconds: 10),
          stallAction: TurnProgressAction.cancel,
          stepTimeout: null,
          eventBus: null,
          log: Logger('WorkflowCliRunnerTest'),
          terminationGrace: const Duration(seconds: 5),
        )..start();

        Object? error;
        unawaited(
          supervisor.waitForExitCode().then<void>(
            (_) => fail('silent process should not complete'),
            onError: (Object e) => error = e,
          ),
        );

        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();

        expect(fake.killSignals, [ProcessSignal.sigterm]);
        expect(error, isNull, reason: 'failure must wait for the escalated process reap path');

        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();

        expect(fake.killSignals, [ProcessSignal.sigterm, ProcessSignal.sigkill]);
        expect(error, isA<WorkflowCliStallException>());
        supervisor.stop();
      });
    });

    test('terminal result returns after bounded cleanup when exit remains unconfirmed', () {
      fakeAsync((async) {
        final fake = FakeProcess();
        final supervisor = CliProcessSupervisor(
          process: fake,
          provider: 'codex',
          stepName: 'Complete',
          stallTimeout: Duration.zero,
          stallAction: TurnProgressAction.cancel,
          stepTimeout: null,
          eventBus: null,
          log: Logger('WorkflowCliRunnerTest'),
          terminationGrace: Duration.zero,
          postTerminalResultGrace: Duration.zero,
          platformCapabilities: PlatformCapabilities(operatingSystem: 'linux'),
        )..start();

        int? exitCode;
        supervisor.recordTerminalResult();
        unawaited(supervisor.waitForExitCode().then((value) => exitCode = value));
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();

        expect(exitCode, 0);
        expect(supervisor.postTerminalResultExitUnconfirmed, isTrue);
        expect(fake.killSignals, [ProcessSignal.sigterm, ProcessSignal.sigkill]);
        supervisor.stop();
      });
    });

    test('codex parsed output resets the stall timer', () {
      fakeAsync((async) {
        late FakeProcess fake;
        final runner = codexRunner(
          processStarter: (exe, args, {workingDirectory, environment}) async {
            fake = FakeProcess();
            return fake;
          },
        );

        WorkflowCliTurnResult? result;
        Object? error;
        unawaited(
          runner
              .executeTurn(
                provider: 'codex',
                prompt: 'stream',
                workingDirectory: Directory.systemTemp.path,
                profileId: 'workspace',
                stepName: 'Review',
                stallTimeout: const Duration(seconds: 10),
                stallAction: TurnProgressAction.cancel,
              )
              .then<void>((value) => result = value, onError: (Object e) => error = e),
        );

        async.flushMicrotasks();
        fake.emitStdout(jsonEncode({'type': 'thread.started', 'thread_id': 'codex-thread-stream'}));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 9));
        fake.emitStdout(jsonEncode({'type': 'turn.started'}));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 9));
        fake.emitStdout(
          jsonEncode({
            'type': 'turn.completed',
            'usage': {'input_tokens': 2, 'output_tokens': 3},
          }),
        );
        fake.exit(0);
        async.flushMicrotasks();

        expect(fake.killCalled, isFalse);
        expect(error, isNull);
        expect(result?.providerSessionId, 'codex-thread-stream');
      });
    });

    for (final provider in const ['claude', 'codex']) {
      test('$provider unknown protocol chatter does not reset the stall timer', () {
        fakeAsync((async) {
          late FakeProcess fake;
          final runner = switch (provider) {
            'claude' => claudeRunner(
              processStarter: (exe, args, {workingDirectory, environment}) async {
                fake = FakeProcess(completeExitOnKill: true, killExitCode: 143);
                return fake;
              },
            ),
            _ => codexRunner(
              processStarter: (exe, args, {workingDirectory, environment}) async {
                fake = FakeProcess(completeExitOnKill: true, killExitCode: 143);
                return fake;
              },
            ),
          };
          Object? error;
          unawaited(
            runner
                .executeTurn(
                  provider: provider,
                  prompt: 'stream',
                  workingDirectory: Directory.systemTemp.path,
                  profileId: 'workspace',
                  stepName: 'Ignore chatter',
                  stallTimeout: const Duration(seconds: 10),
                  stallAction: TurnProgressAction.cancel,
                )
                .then<void>(
                  (_) => fail('unknown chatter should not prevent a stall'),
                  onError: (Object value) => error = value,
                ),
          );

          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 9));
          fake.emitStdout(jsonEncode({'type': 'unknown.provider.event'}));
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 1));
          async.flushMicrotasks();

          expect(fake.killCalled, isTrue);
          expect(error, isA<WorkflowCliStallException>());
        });
      });
    }

    test('step timeout kills overlong one-shot process distinctly from stall', () {
      fakeAsync((async) {
        late FakeProcess fake;
        final runner = claudeRunner(
          processStarter: (exe, args, {workingDirectory, environment}) async {
            fake = FakeProcess(completeExitOnKill: true, killExitCode: -1);
            return fake;
          },
        );

        Object? error;
        unawaited(
          runner
              .executeTurn(
                provider: 'claude',
                prompt: 'slow',
                workingDirectory: Directory.systemTemp.path,
                profileId: 'workspace',
                stepName: 'Timeout step',
                stallTimeout: Duration.zero,
                stepTimeout: const Duration(seconds: 30),
              )
              .then<void>((_) => fail('overlong process should not complete'), onError: (Object e) => error = e),
        );

        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 30));
        async.flushMicrotasks();

        expect(fake.killCalled, isTrue);
        expect(error, isA<WorkflowCliTimeoutException>());
        expect(error.toString(), contains('Timeout step'));
      });
    });

    test('workflow CLI grace termination reaps its child without failing the parsed result', () {
      fakeAsync((async) {
        late FakeProcess fake;
        final runner = claudeRunner(
          processStarter: (exe, args, {workingDirectory, environment}) async {
            fake = FakeProcess(completeExitOnKill: true, killExitCode: -1);
            return fake;
          },
        );

        WorkflowCliTurnResult? result;
        Object? error;
        unawaited(
          runner
              .executeTurn(
                provider: 'claude',
                prompt: 'done but stuck',
                workingDirectory: Directory.systemTemp.path,
                profileId: 'workspace',
                stepName: 'Grace reap',
                stallTimeout: const Duration(seconds: 30),
                stallAction: TurnProgressAction.cancel,
                stepTimeout: const Duration(minutes: 10),
              )
              .then<void>((value) => result = value, onError: (Object e) => error = e),
        );

        async.flushMicrotasks();
        fake.emitStdout(jsonEncode({'type': 'system', 'subtype': 'init', 'session_id': 'sess'}));
        fake.emitStdout(jsonEncode({'type': 'result', 'session_id': 'sess', 'result': 'ok'}));
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 9));
        async.flushMicrotasks();
        expect(fake.killCalled, isFalse);

        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();

        int? exitCode;
        unawaited(fake.exitCode.then((value) => exitCode = value));
        async.flushMicrotasks();

        expect(fake.killCalled, isTrue);
        expect(exitCode, -1);
        expect(error, isNull);
        expect(result?.responseText, 'ok');
      });
    });

    test('terminal result disables stall cancellation during grace kill window', () {
      fakeAsync((async) {
        late FakeProcess fake;
        final runner = claudeRunner(
          processStarter: (exe, args, {workingDirectory, environment}) async {
            fake = FakeProcess(completeExitOnKill: true, killExitCode: -1);
            return fake;
          },
        );

        WorkflowCliTurnResult? result;
        Object? error;
        unawaited(
          runner
              .executeTurn(
                provider: 'claude',
                prompt: 'done then quiet',
                workingDirectory: Directory.systemTemp.path,
                profileId: 'workspace',
                stepName: 'Short stall grace',
                stallTimeout: const Duration(seconds: 2),
                stallAction: TurnProgressAction.cancel,
                stepTimeout: const Duration(minutes: 10),
              )
              .then<void>((value) => result = value, onError: (Object e) => error = e),
        );

        async.flushMicrotasks();
        fake.emitStdout(jsonEncode({'type': 'system', 'subtype': 'init', 'session_id': 'sess'}));
        fake.emitStdout(jsonEncode({'type': 'result', 'session_id': 'sess', 'result': 'ok'}));
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 3));
        async.flushMicrotasks();
        expect(fake.killCalled, isFalse);
        expect(error, isNull);

        async.elapse(const Duration(seconds: 7));
        async.flushMicrotasks();

        expect(fake.killCalled, isTrue);
        expect(error, isNull);
        expect(result?.responseText, 'ok');
      });
    });

    test('builds Codex one-shot args with explicit approval policy and sandbox override', () async {
      late List<String> arguments;
      final runner = codexRunner(
        options: const {'sandbox': 'workspace-write'},
        processStarter: codexStub(
          onArgs: (exe, args) => arguments = args,
          events: [
            {'type': 'thread.started', 'thread_id': 'codex-thread-arg-test'},
            {
              'type': 'item.completed',
              'item': {'type': 'agent_message', 'text': 'done'},
            },
            {
              'type': 'turn.completed',
              'usage': {'input_tokens': 1, 'output_tokens': 1},
            },
          ],
        ),
      );

      await runner.executeTurn(
        provider: 'codex',
        prompt: 'Review this',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
        sandboxOverride: 'read-only',
      );

      expect(arguments, containsAll(['exec', '--json', '--skip-git-repo-check']));
      expect(arguments, isNot(contains('--full-auto')));
      expect(arguments, containsAll(['-c', 'approval_policy="never"']));
      expect(arguments, containsAll(['--sandbox', 'read-only']));
    });

    test('Codex sandbox override resolves to the stricter configured value', () async {
      late List<String> arguments;
      final runner = codexRunner(
        options: const {'sandbox': 'read-only'},
        processStarter: codexStub(
          onArgs: (exe, args) => arguments = args,
          events: [
            {'type': 'thread.started', 'thread_id': 'codex-thread-strict-sandbox'},
            {
              'type': 'turn.completed',
              'usage': {'input_tokens': 1, 'output_tokens': 1},
            },
          ],
        ),
      );

      await runner.executeTurn(
        provider: 'codex',
        prompt: 'Review this',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
        sandboxOverride: 'workspace-write',
      );

      expect(arguments, isNot(contains('--full-auto')));
      expect(arguments, containsAll(['--sandbox', 'read-only']));
    });

    test('Codex read-only override tightens danger-full-access default', () async {
      late List<String> arguments;
      final runner = codexRunner(
        options: const {'sandbox': 'danger-full-access'},
        processStarter: codexStub(
          onArgs: (exe, args) => arguments = args,
          events: [
            {'type': 'thread.started', 'thread_id': 'codex-thread-tightened-sandbox'},
            {
              'type': 'turn.completed',
              'usage': {'input_tokens': 1, 'output_tokens': 1},
            },
          ],
        ),
      );

      await runner.executeTurn(
        provider: 'codex',
        prompt: 'Review this',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
        sandboxOverride: 'read-only',
      );

      expect(arguments, isNot(contains('--full-auto')));
      expect(arguments, containsAll(['--sandbox', 'read-only']));
    });

    test('builds Claude one-shot args with permissionMode and structured settings', () async {
      final arguments = await capturedClaudeArgs(
        options: const {
          'permissionMode': 'dontAsk',
          'sandbox': {'enabled': true, 'autoAllowBashIfSandboxed': true},
          'permissions': {
            'allow': ['Bash(git *)'],
          },
        },
      );

      expect(arguments, isNot(contains('--setting-sources')));
      expect(arguments, containsAll(['--permission-mode', 'dontAsk']));
      expect(arguments, isNot(contains('--dangerously-skip-permissions')));
      final decoded = decodedClaudeSettings(arguments);
      expect(decoded['sandbox'], {'enabled': true, 'autoAllowBashIfSandboxed': true});
      expect(decoded['permissions'], {
        'allow': ['Bash(git *)'],
      });
    });

    test('builds Claude one-shot task policy from read-only allowed tools', () async {
      final arguments = await capturedClaudeArgs(
        options: const {
          'permissions': {
            'allow': ['WebFetch(*)'],
            'deny': ['Read(./.env)'],
          },
        },
        allowedTools: const ['shell', 'file_read'],
        readOnly: true,
        prompt: 'Discover this',
      );

      expect(arguments, containsAll(['--permission-mode', 'dontAsk']));
      expect(arguments, isNot(contains('--dangerously-skip-permissions')));
      final decoded = decodedClaudeSettings(arguments);
      expect(decoded['sandbox'], {'enabled': true});
      expect(decoded['permissions'], {
        'allow': readOnlyShellAllow,
        'deny': ['Edit', 'NotebookEdit', 'Read(./.env)', 'Write'],
      });
    });

    test('read-only Claude task policy keeps file reads when requested tools include only shell', () async {
      final arguments = await capturedClaudeArgs(
        options: const {
          'permissions': {
            'allow': ['Bash'],
            'defaultMode': 'plan',
          },
        },
        allowedTools: const ['shell'],
        readOnly: true,
        prompt: 'Discover this',
      );

      final decoded = decodedClaudeSettings(arguments);
      expect(decoded['permissions'], {'allow': readOnlyShellAllow, 'deny': writeDeny});
      expect((decoded['permissions'] as Map<String, dynamic>).containsKey('defaultMode'), isFalse);
    });

    test('read-only Claude task policy does not add file reads for unrelated explicit tools', () async {
      final arguments = await capturedClaudeArgs(
        prompt: 'Fetch this',
        allowedTools: const ['web_fetch'],
        readOnly: true,
      );

      final decoded = decodedClaudeSettings(arguments);
      expect(decoded['permissions'], {
        'allow': ['WebFetch', 'WebSearch'],
        'deny': ['Edit', 'NotebookEdit', 'Write'],
      });
    });

    test('read-only Claude task policy scrubs permissions inherited from structured settings', () async {
      final arguments = await capturedClaudeArgs(
        options: const {
          'settings': {
            'permissions': {
              'allow': ['Bash'],
              'deny': ['Read(./secret)'],
              'defaultMode': 'plan',
            },
            'theme': 'dark',
          },
        },
        allowedTools: const ['shell'],
        readOnly: true,
        prompt: 'Discover this',
      );

      final decoded = decodedClaudeSettings(arguments);
      expect(decoded['theme'], 'dark');
      expect(decoded['permissions'], {
        'allow': readOnlyShellAllow,
        'deny': ['Edit', 'NotebookEdit', 'Read(./secret)', 'Write'],
      });
    });

    test('rejects malformed Claude settings JSON when task policy must be enforced', () async {
      final runner = claudeRunner(
        options: const {'settings': '{settings.json'},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          throw StateError('process should not start');
        },
      );

      await expectLater(
        runner.executeTurn(
          provider: 'claude',
          prompt: 'Discover this',
          workingDirectory: Directory.systemTemp.path,
          profileId: 'workspace',
          allowedTools: const ['file_read'],
          readOnly: true,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('cannot be enforced with malformed JSON settings'),
          ),
        ),
      );
    });

    test('rejects path-shaped Claude settings when task policy must be enforced', () async {
      final runner = claudeRunner(
        options: const {'settings': '/tmp/settings.json'},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          throw StateError('process should not start');
        },
      );

      await expectLater(
        runner.executeTurn(
          provider: 'claude',
          prompt: 'Discover this',
          workingDirectory: Directory.systemTemp.path,
          profileId: 'workspace',
          allowedTools: const ['file_read'],
          readOnly: true,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('cannot be enforced with path-based settings'),
          ),
        ),
      );
    });

    test('preserves path-based Claude settings when structured overlays are also configured', () async {
      final arguments = await capturedClaudeArgs(
        options: const {
          'settings': '/tmp/claude-settings.json',
          'sandbox': {'enabled': true},
        },
      );

      final settingsIndex = arguments.indexOf('--settings');
      expect(arguments[settingsIndex + 1], '/tmp/claude-settings.json');
    });

    test('merges base Claude settings with structured sandbox and permissions', () async {
      final arguments = await capturedClaudeArgs(
        options: const {
          'settings': {
            'permissions': {'defaultMode': 'plan'},
            'sandbox': {'failIfUnavailable': true},
          },
          'sandbox': {'enabled': true},
          'permissions': {
            'allow': ['Bash(git *)'],
          },
        },
      );

      final decoded = decodedClaudeSettings(arguments);
      expect(decoded['permissions'], {
        'defaultMode': 'plan',
        'allow': ['Bash(git *)'],
      });
      expect(decoded['sandbox'], {'failIfUnavailable': true, 'enabled': true});
    });

    test('merges raw JSON Claude settings string with structured sandbox and permissions', () async {
      final arguments = await capturedClaudeArgs(
        options: const {
          'settings': '{"permissions":{"defaultMode":"plan"},"sandbox":{"failIfUnavailable":true}}',
          'sandbox': {'enabled': true},
          'permissions': {
            'allow': ['Bash(git *)'],
          },
        },
      );

      final decoded = decodedClaudeSettings(arguments);
      expect(decoded['permissions'], {
        'defaultMode': 'plan',
        'allow': ['Bash(git *)'],
      });
      expect(decoded['sandbox'], {'failIfUnavailable': true, 'enabled': true});
    });

    for (final testCase in const [
      (name: 'interactive', value: 'plan', message: 'does not support interactive permissionMode "plan"'),
      (name: 'unsupported', value: 'dontask', message: 'Unsupported Claude permissionMode "dontask"'),
      (name: 'non-string', value: 7, message: 'Unsupported Claude permissionMode'),
    ]) {
      test('rejects ${testCase.name} Claude permissionMode values in one-shot mode', () async {
        final runner = claudeRunner(options: {'permissionMode': testCase.value});

        await expectLater(
          () => runner.executeTurn(
            provider: 'claude',
            prompt: 'Review this',
            workingDirectory: Directory.systemTemp.path,
            profileId: 'workspace',
          ),
          throwsA(isA<StateError>().having((e) => e.message, 'message', contains(testCase.message))),
        );
      });
    }

    test('does not force project setting sources for containerized Claude one-shot runs', () async {
      final workingDirectory = await Directory.systemTemp.createTemp('workflow-cli-runner-claude-container');
      addTearDown(() async {
        if (await workingDirectory.exists()) {
          await workingDirectory.delete(recursive: true);
        }
      });

      final container = FakeContainerExecutor(
        hostRoot: workingDirectory.path,
        containerRoot: '/workspace',
        stdout: jsonEncode({'session_id': 'claude-session-container', 'result': 'ok'}),
      );
      final runner = claudeRunner(containerManagers: {'workspace': container});

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
      final fixture = await claudeSettingsContainerFixture('workflow-cli-runner-claude-settings-container');
      final runner = claudeRunner(
        options: {
          'settings': fixture.settingsPath,
          'sandbox': {'enabled': true},
        },
        containerManagers: {'workspace': fixture.container},
      );

      await runner.executeTurn(
        provider: 'claude',
        prompt: 'Review this',
        workingDirectory: fixture.workingDirectory.path,
        profileId: 'workspace',
      );

      final settingsIndex = fixture.container.lastCommand.indexOf('--settings');
      expect(settingsIndex, isNonNegative);
      expect(fixture.container.lastCommand[settingsIndex + 1], '/workspace/claude-settings.json');
    });

    test('translates plain path-based Claude settings for containerized one-shot runs without overlays', () async {
      final fixture = await claudeSettingsContainerFixture('workflow-cli-runner-claude-settings-plain');
      final runner = claudeRunner(
        options: {'settings': fixture.settingsPath},
        containerManagers: {'workspace': fixture.container},
      );

      await runner.executeTurn(
        provider: 'claude',
        prompt: 'Review this',
        workingDirectory: fixture.workingDirectory.path,
        profileId: 'workspace',
      );

      final settingsIndex = fixture.container.lastCommand.indexOf('--settings');
      expect(settingsIndex, isNonNegative);
      expect(fixture.container.lastCommand[settingsIndex + 1], '/workspace/claude-settings.json');
    });

    test('translates relative path-based Claude settings for containerized one-shot runs', () async {
      final fixture = await claudeSettingsContainerFixture(
        'workflow-cli-runner-claude-settings-relative',
        relativeSettingsPath: p.join('.claude', 'settings.json'),
      );
      final runner = claudeRunner(
        options: const {'settings': '.claude/settings.json'},
        containerManagers: {'workspace': fixture.container},
      );

      await runner.executeTurn(
        provider: 'claude',
        prompt: 'Review this',
        workingDirectory: fixture.workingDirectory.path,
        profileId: 'workspace',
      );

      final settingsIndex = fixture.container.lastCommand.indexOf('--settings');
      expect(settingsIndex, isNonNegative);
      expect(fixture.container.lastCommand[settingsIndex + 1], '/workspace/.claude/settings.json');
    });

    test('builds Codex one-shot args and parses JSONL final message', () async {
      late String executable;
      late List<String> arguments;
      final runner = codexRunner(
        options: const {'sandbox': 'danger-full-access'},
        processStarter: codexStub(
          onArgs: (exe, args) {
            executable = exe;
            arguments = args;
          },
          events: [
            {'type': 'thread.started', 'thread_id': 'codex-thread-1'},
            {
              'type': 'item.completed',
              'item': {
                'type': 'agent_message',
                'text': jsonEncode({
                  'items': [
                    {'path': 'lib/main.dart'},
                  ],
                }),
              },
            },
            {
              'type': 'turn.completed',
              'usage': {'input_tokens': 20, 'output_tokens': 8, 'cached_input_tokens': 4},
            },
          ],
        ),
      );

      final result = await runner.executeTurn(
        provider: 'codex',
        prompt: 'List changed files',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
        providerSessionId: 'thread-prev',
        model: 'gpt-5-codex',
        jsonSchema: itemsSchema,
      );

      expect(executable, 'codex');
      expect(arguments, containsAll(['exec', '--json', '--skip-git-repo-check']));
      expect(arguments, isNot(contains('--full-auto')));
      expect(arguments, contains('resume'));
      expect(arguments, contains('thread-prev'));
      expect(arguments, contains('--output-schema'));
      expect(result.providerSessionId, 'codex-thread-1');
      expect(result.structuredOutput?['items'], isA<List<dynamic>>());
      expect(result.inputTokens, 20);
      expect(result.cacheReadTokens, 4);
      expect(result.newInputTokens, 16);
    });

    test('treats Codex reasoning_tokens as part of output_tokens', () async {
      final runner = codexRunner(
        processStarter: codexStub(
          events: [
            {'type': 'thread.started', 'thread_id': 'codex-thread-reasoning'},
            {
              'type': 'turn.completed',
              'usage': {
                'input_tokens': 30,
                'cached_input_tokens': 10,
                'output_tokens': 20,
                'output_tokens_details': {'reasoning_tokens': 7},
              },
            },
          ],
        ),
      );

      final result = await runner.executeTurn(
        provider: 'codex',
        prompt: 'Summarize',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
      );

      expect(result.outputTokens, 20);
      expect(result.newInputTokens, 20);
    });

    test('Codex turn.completed uses assignment semantics for cumulative usage', () async {
      final runner = codexRunner(
        processStarter: codexStub(
          events: [
            {'type': 'thread.started', 'thread_id': 'codex-thread-2'},
            {
              'type': 'turn.completed',
              'usage': {'input_tokens': 119659, 'output_tokens': 1900, 'cache_read_tokens': 115000},
            },
            {
              'type': 'turn.completed',
              'usage': {'input_tokens': 121000, 'output_tokens': 2000, 'cache_read_tokens': 116000},
            },
          ],
        ),
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

    test('emits WorkflowCliTurnProgressEvent and normalizes cached_input_tokens', () async {
      final eventBus = EventBus();
      addTearDown(eventBus.dispose);
      final progressEvents = <WorkflowCliTurnProgressEvent>[];
      final sub = eventBus.on<WorkflowCliTurnProgressEvent>().listen(progressEvents.add);
      addTearDown(sub.cancel);

      final runner = codexRunner(
        eventBus: eventBus,
        processStarter: codexStub(
          events: [
            {'type': 'thread.started', 'thread_id': 'codex-thread-progress'},
            {'type': 'turn.started'},
            {
              'type': 'item.completed',
              'item': {'type': 'agent_message', 'text': 'OK'},
            },
            {
              'type': 'turn.completed',
              'usage': {'input_tokens': 20, 'cached_input_tokens': 7, 'output_tokens': 4},
            },
          ],
        ),
      );

      final result = await runner.executeTurn(
        provider: 'codex',
        prompt: 'Reply with OK',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
        taskId: 'task-progress',
        sessionId: 'sess-progress',
      );

      expect(result.cacheReadTokens, 7);
      expect(result.newInputTokens, 13);
      expect(progressEvents, hasLength(1));
      expect(progressEvents.single.taskId, 'task-progress');
      expect(progressEvents.single.sessionId, 'sess-progress');
      expect(progressEvents.single.provider, 'codex');
      expect(progressEvents.single.turnIndex, 1);
      expect(progressEvents.single.cumulativeTokens, 24);
      expect(progressEvents.single.cacheReadTokens, 7);
    });

    test('emits progress events in order for multiple cumulative Codex turns', () async {
      final eventBus = EventBus();
      addTearDown(eventBus.dispose);
      final progressEvents = <WorkflowCliTurnProgressEvent>[];
      final sub = eventBus.on<WorkflowCliTurnProgressEvent>().listen(progressEvents.add);
      addTearDown(sub.cancel);

      final runner = codexRunner(
        eventBus: eventBus,
        processStarter: codexStub(
          events: [
            {'type': 'thread.started', 'thread_id': 'codex-thread-ordered'},
            {'type': 'turn.started'},
            {
              'type': 'turn.completed',
              'usage': {'input_tokens': 100, 'cached_input_tokens': 20, 'output_tokens': 10},
            },
            {'type': 'turn.started'},
            {
              'type': 'turn.completed',
              'usage': {'input_tokens': 140, 'cached_input_tokens': 30, 'output_tokens': 18},
            },
          ],
        ),
      );

      final result = await runner.executeTurn(
        provider: 'codex',
        prompt: 'List changed files',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
        taskId: 'task-ordered',
        sessionId: 'sess-ordered',
      );

      expect(progressEvents.map((event) => event.turnIndex), [1, 2]);
      expect(progressEvents.map((event) => event.cumulativeTokens), [110, 158]);
      expect(result.inputTokens, 140);
      expect(result.outputTokens, 18);
      expect(result.cacheReadTokens, 30);
      expect(result.newInputTokens, 110);
    });

    test('nonzero Codex exit still includes stdout excerpt after streaming parse', () async {
      final stdout = jsonEncode({'type': 'error', 'message': 'fatal workflow error'});
      final runner = codexRunner(
        processStarter: (exe, args, {workingDirectory, environment}) async {
          return Process.start('/bin/sh', ['-lc', "printf '%s' '${stdout.replaceAll("'", "'\\''")}'; exit 1"]);
        },
      );

      await expectLater(
        () => runner.executeTurn(
          provider: 'codex',
          prompt: 'List changed files',
          workingDirectory: Directory.systemTemp.path,
          profileId: 'workspace',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('stdout:'), contains('fatal workflow error')),
          ),
        ),
      );
    });

    test('forwards appendSystemPrompt to Codex via developer_instructions override', () async {
      late List<String> arguments;
      final runner = codexRunner(
        processStarter: codexStub(
          onArgs: (exe, args) => arguments = args,
          events: [
            {'type': 'thread.started', 'thread_id': 'codex-thread-append'},
            {'type': 'turn.completed'},
          ],
        ),
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

      final runner = codexRunner(
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
        jsonSchema: itemsSchema,
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

      final runner = codexRunner(
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
          jsonSchema: itemsSchema,
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

      final container = FakeContainerExecutor(hostRoot: workingDirectory.path, containerRoot: '/workspace');

      final runner = codexRunner(containerManagers: {'workspace': container});

      await runner.executeTurn(
        provider: 'codex',
        prompt: 'List changed files',
        workingDirectory: workingDirectory.path,
        profileId: 'workspace',
        jsonSchema: itemsSchema,
      );

      expect(container.lastWorkingDirectory, '/workspace');
      final schemaFlagIndex = container.lastCommand.indexOf('--output-schema');
      expect(schemaFlagIndex, isNonNegative);
      expect(container.lastCommand[schemaFlagIndex + 1], startsWith('/workspace/.dartclaw-codex-schema-'));
    });

    test('one-shot runner default starter does not leak parent env into child', () async {
      // Regression guard for S38/E2 that exercises the REAL default process
      // starter (no processStarter injection). The test configures a fake
      // provider binary – a shell script that dumps its env – and a minimal
      // provider env. If `_defaultProcessStarter` ever regresses to a policy
      // that re-inherits `Platform.environment` (e.g. `includeParentEnvironment:
      // true` or a sanitize fallback), the child would see parent-only keys
      // that are NOT in providerConfig.environment.
      final tempDir = Directory.systemTemp.createTempSync('workflow_cli_env_default_');
      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });
      final envDump = File(p.join(tempDir.path, 'env.txt'));
      final scriptPath = p.join(tempDir.path, 'fake-claude.sh');
      final stdoutPayload = jsonEncode({'session_id': 'default-starter', 'result': 'ok'});
      File(scriptPath).writeAsStringSync(
        '#!/bin/sh\n'
        'env > "${envDump.path}"\n'
        "printf '%s' '${stdoutPayload.replaceAll("'", r"'\''")}'\n",
      );
      await Process.run('chmod', ['+x', scriptPath]);

      final runner = WorkflowCliRunner(
        providers: {
          'claude': WorkflowCliProviderConfig(
            executable: scriptPath,
            environment: {'PROVIDER_OK': 'provider-value', 'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin'},
          ),
        },
        // No processStarter override – the production `_defaultProcessStarter`
        // must isolate the child env from Platform.environment.
      );

      await runner.executeTurn(
        provider: 'claude',
        prompt: 'test',
        workingDirectory: tempDir.path,
        profileId: 'workspace',
      );

      expect(envDump.existsSync(), isTrue, reason: 'fake claude did not run');
      final lines = envDump.readAsLinesSync();
      expect(lines, contains('PROVIDER_OK=provider-value'), reason: 'provider env must reach child');

      // Keys present in Platform.environment but NOT in providerConfig.environment
      // must NOT appear in the child dump. `HOME` and `USER` are reliably present
      // in Dart test harnesses on POSIX and absent from the provider env above.
      final parentHome = Platform.environment['HOME'];
      if (parentHome != null) {
        expect(
          lines,
          isNot(contains('HOME=$parentHome')),
          reason: 'parent HOME must not leak into child – default starter may have regressed to inherit parent env',
        );
      }
      final parentUser = Platform.environment['USER'];
      if (parentUser != null) {
        expect(lines, isNot(contains('USER=$parentUser')), reason: 'parent USER must not leak into child');
      }
    });

    group('provider routing', () {
      test('custom providerImpls: FakeCliProvider is routed for registered provider name', () async {
        var runCalled = false;
        final runner = WorkflowCliRunner(
          providers: const {'fake': WorkflowCliProviderConfig(executable: 'fake-exe')},
          providerImpls: {'fake': FakeCliProvider(() => runCalled = true)},
        );

        final result = await runner.executeTurn(
          provider: 'fake',
          prompt: 'hello',
          workingDirectory: Directory.systemTemp.path,
          profileId: 'workspace',
        );

        expect(runCalled, isTrue);
        expect(result.responseText, 'fake-response');
      });

      test('throws UnsupportedError for provider with config but no impl', () async {
        final runner = WorkflowCliRunner(
          providers: const {'custom': WorkflowCliProviderConfig(executable: 'custom-exe')},
          providerImpls: const {},
        );

        await expectLater(
          () => runner.executeTurn(
            provider: 'custom',
            prompt: 'hello',
            workingDirectory: Directory.systemTemp.path,
            profileId: 'workspace',
          ),
          throwsA(
            isA<UnsupportedError>().having(
              (e) => e.message,
              'message',
              contains('Workflow one-shot CLI is not implemented for provider "custom"'),
            ),
          ),
        );
      });
    });
  });
}
