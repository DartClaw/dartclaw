import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/src/harness/agent_harness.dart';
import 'package:dartclaw_core/src/bridge/bridge_events.dart';
import 'package:dartclaw_core/src/harness/claude_code_harness.dart';
import 'package:dartclaw_core/src/harness/harness_config.dart';
import 'package:dartclaw_core/src/harness/tool_policy.dart';
import 'package:dartclaw_core/src/worker/worker_state.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show CapturingFakeProcess, FakeProcess;
import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'harness_test_support.dart';

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('ClaudeCodeHarness', () {
    // ----- Constructor defaults & configuration --------------------------

    group('constructor defaults', () {
      test('uses sensible defaults for optional parameters', () {
        final h = ClaudeCodeHarness(cwd: '/tmp');
        expect(h.claudeExecutable, 'claude');
        expect(h.cwd, '/tmp');
        expect(h.turnTimeout, const Duration(seconds: 600));
        expect(h.maxRetries, 5);
        expect(h.baseBackoff, const Duration(seconds: 5));
        expect(h.toolPolicy, ToolApprovalPolicy.allowAll);
      });

      test('initial state is stopped', () {
        final h = ClaudeCodeHarness(cwd: '/tmp');
        expect(h.state, WorkerState.stopped);
      });

      test('sessionId is null before start', () {
        final h = ClaudeCodeHarness(cwd: '/tmp');
        expect(h.sessionId, isNull);
      });

      test('accepts custom configuration', () {
        final h = ClaudeCodeHarness(
          claudeExecutable: '/usr/local/bin/claude',
          cwd: '/home/user',
          turnTimeout: const Duration(seconds: 120),
          maxRetries: 3,
          baseBackoff: const Duration(seconds: 2),
        );
        expect(h.claudeExecutable, '/usr/local/bin/claude');
        expect(h.cwd, '/home/user');
        expect(h.turnTimeout, const Duration(seconds: 120));
        expect(h.maxRetries, 3);
        expect(h.baseBackoff, const Duration(seconds: 2));
      });
    });

    // ----- start() -------------------------------------------------------

    group('start()', () {
      test('calls commandProbe to verify claude binary exists', () async {
        var probeCalled = false;
        String? probeExe;
        List<String>? probeArgs;

        final h = buildClaudeHarness(
          commandProbe: (exe, args) async {
            probeCalled = true;
            probeExe = exe;
            probeArgs = args;
            return processResult(exitCode: 0, stdout: '1.0.0');
          },
        );

        await h.start();
        addTeardownAsync(() => h.dispose());

        expect(probeCalled, isTrue);
        expect(probeExe, 'claude');
        expect(probeArgs, ['--version']);
      });

      test('throws StateError when commandProbe reports binary missing', () async {
        final h = buildClaudeHarness(commandProbe: (exe, args) async => processResult(exitCode: 1));
        addTeardownAsync(() => h.dispose());

        await expectLater(h.start(), throwsA(isA<StateError>()));
      });

      test('throws when ANTHROPIC_API_KEY missing and OAuth check fails', () async {
        var callCount = 0;
        final h = buildClaudeHarness(
          environment: {}, // no API key
          commandProbe: (exe, args) async {
            callCount++;
            if (args.contains('--version')) return processResult(exitCode: 0);
            // auth status check fails
            return processResult(exitCode: 1);
          },
        );
        addTeardownAsync(() => h.dispose());

        await expectLater(
          h.start(),
          throwsA(isA<StateError>().having((e) => e.message, 'message', contains('No authentication configured'))),
        );
        // Two probe calls: --version + auth status
        expect(callCount, 2);
      });

      test('transitions state from stopped to idle on success', () async {
        final h = buildClaudeHarness();
        addTeardownAsync(() => h.dispose());

        expect(h.state, WorkerState.stopped);
        await h.start();
        expect(h.state, WorkerState.idle);
      });

      test('is idempotent when already idle', () async {
        final h = buildClaudeHarness();
        addTeardownAsync(() => h.dispose());

        await h.start();
        expect(h.state, WorkerState.idle);

        // Second start() should be a no-op.
        await h.start();
        expect(h.state, WorkerState.idle);
      });

      test('throws when called while busy', () async {
        final fakeProcess = makeClaudeFakeProcess();

        final h = buildClaudeHarness(processFactory: capturingInitFactory(process: fakeProcess));
        addTeardownAsync(() => h.dispose());

        await h.start();

        // Initiate a turn that will never complete (no TurnResult emitted).
        final turnFuture = h.turn(
          sessionId: 'test',
          messages: [
            {'role': 'user', 'content': 'hello'},
          ],
          systemPrompt: 'test',
        );

        // Allow microtasks to run so turn() acquires lock and sets busy.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(h.state, WorkerState.busy);

        await expectLater(h.start(), throwsA(isA<StateError>()));

        // Clean up: kill process so the pending turn completes with error.
        fakeProcess.exit(1);
        await turnFuture.catchError((_) => <String, dynamic>{});
      });

      test('spawns process with correct arguments and cleaned env', () async {
        String? capturedExe;
        List<String>? capturedArgs;
        Map<String, String>? capturedEnv;

        final h = buildClaudeHarness(
          environment: {'ANTHROPIC_API_KEY': 'sk-test', 'CLAUDECODE': 'nested', 'HOME': '/home/user'},
          processFactory: capturingInitFactory(
            onSpawn: (spawn) {
              capturedExe = spawn.exe;
              capturedArgs = spawn.args;
              capturedEnv = spawn.environment;
            },
          ),
        );
        addTeardownAsync(() => h.dispose());

        await h.start();

        expect(capturedExe, 'claude');
        expect(capturedArgs, contains('--print'));
        expect(capturedArgs, contains('--output-format'));
        expect(capturedArgs, contains('stream-json'));
        expect(capturedArgs, isNot(contains('--setting-sources')));
        expect(capturedArgs, contains('--dangerously-skip-permissions'));
        expect(capturedArgs, isNot(contains('--permission-prompt-tool')));
        // Nesting-detection env vars should be stripped.
        expect(capturedEnv, isNot(contains('CLAUDECODE')));
        expect(capturedEnv, isNot(contains('CLAUDE_CODE_ENTRYPOINT')));
        // Regular env vars should remain.
        expect(capturedEnv?['HOME'], '/home/user');
        expect(capturedEnv?['ANTHROPIC_API_KEY'], 'sk-test');
      });

      test('writes MCP config with owner-only permissions', () async {
        List<String>? capturedArgs;

        final h = buildClaudeHarness(
          harnessConfig: const HarnessConfig(mcpServerUrl: 'http://127.0.0.1:3333/mcp', mcpGatewayToken: 'test-token'),
          processFactory: capturingInitFactory(
            onSpawn: (spawn) {
              capturedArgs = spawn.args;
            },
          ),
        );
        addTeardownAsync(() => h.dispose());

        await h.start();

        final configPath = capturedArgs![capturedArgs!.indexOf('--mcp-config') + 1];
        final configFile = File(configPath);
        expect(configFile.readAsStringSync(), contains('Bearer test-token'));
        if (!Platform.isWindows) {
          expect((configFile.statSync().mode & 0x1ff).toRadixString(8), '600');
        }
      });

      test('uses native --permission-mode when configured via provider options', () async {
        final capturedArgs = await startHarnessAndCaptureArgs(providerOptions: const {'permissionMode': 'dontAsk'});

        expect(capturedArgs, containsAll(['--permission-mode', 'dontAsk']));
        expect(capturedArgs, isNot(contains('--dangerously-skip-permissions')));
        expect(capturedArgs, isNot(contains('--permission-prompt-tool')));
      });

      test('uses stdio permission bridge for interactive native permission modes', () async {
        final capturedArgs = await startHarnessAndCaptureArgs(providerOptions: const {'permissionMode': 'plan'});

        expect(capturedArgs, containsAll(['--permission-mode', 'plan']));
        expect(capturedArgs, containsAll(['--permission-prompt-tool', 'stdio']));
        expect(capturedArgs, isNot(contains('--dangerously-skip-permissions')));
      });

      for (final testCase in const [(name: 'unsupported', value: 'dontask'), (name: 'non-string', value: 7)]) {
        test('throws for ${testCase.name} Claude permissionMode values', () async {
          final h = buildClaudeHarness(providerOptions: {'permissionMode': testCase.value});
          addTeardownAsync(() => h.dispose());

          await expectLater(
            h.start(),
            throwsA(
              isA<StateError>().having((e) => e.message, 'message', contains('Unsupported Claude permissionMode')),
            ),
          );
        });
      }

      test('passes structured Claude settings via --settings JSON when configured', () async {
        final capturedArgs = await startHarnessAndCaptureArgs(
          providerOptions: const {
            'sandbox': {'enabled': true, 'autoAllowBashIfSandboxed': true, 'failIfUnavailable': true},
            'permissions': {
              'allow': ['Bash(git *)'],
              'deny': ['Read(./.env)'],
            },
          },
        );

        final decoded = decodedSettings(capturedArgs);
        expect(decoded['sandbox'], {'enabled': true, 'autoAllowBashIfSandboxed': true, 'failIfUnavailable': true});
        expect(decoded['permissions'], {
          'allow': ['Bash(git *)'],
          'deny': ['Read(./.env)'],
        });
      });

      test('deep-merges base Claude settings with structured sandbox and permissions', () async {
        final capturedArgs = await startHarnessAndCaptureArgs(
          providerOptions: const {
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

        final decoded = decodedSettings(capturedArgs);
        expect(decoded['permissions'], {
          'defaultMode': 'plan',
          'allow': ['Bash(git *)'],
        });
        expect(decoded['sandbox'], {'failIfUnavailable': true, 'enabled': true});
      });

      test('merges raw JSON settings string with structured sandbox and permissions', () async {
        final capturedArgs = await startHarnessAndCaptureArgs(
          providerOptions: const {
            'settings': '{"permissions":{"defaultMode":"plan"},"sandbox":{"failIfUnavailable":true}}',
            'sandbox': {'enabled': true},
            'permissions': {
              'allow': ['Bash(git *)'],
            },
          },
        );

        final decoded = decodedSettings(capturedArgs);
        expect(decoded['permissions'], {
          'defaultMode': 'plan',
          'allow': ['Bash(git *)'],
        });
        expect(decoded['sandbox'], {'failIfUnavailable': true, 'enabled': true});
      });

      test('preserves path-based settings when structured overlays are also configured', () async {
        final capturedArgs = await startHarnessAndCaptureArgs(
          providerOptions: const {
            'settings': '/tmp/claude-settings.json',
            'sandbox': {'enabled': true},
          },
        );

        final settingsIndex = capturedArgs.indexOf('--settings');
        expect(capturedArgs[settingsIndex + 1], '/tmp/claude-settings.json');
      });

      test('translates path-based settings for containerized execution', () async {
        final hostRoot = await Directory.systemTemp.createTemp('claude-settings-container');
        addTearDown(() async {
          if (await hostRoot.exists()) {
            await hostRoot.delete(recursive: true);
          }
        });
        final container = FakeClaudeContainerExecutor(hostRoot: hostRoot.path, containerRoot: '/workspace');
        final settingsPath = p.join(hostRoot.path, 'claude-settings.json');
        File(settingsPath).writeAsStringSync('{}');

        final h = ClaudeCodeHarness(
          cwd: hostRoot.path,
          processFactory: defaultClaudeProcessFactory,
          commandProbe: defaultClaudeCommandProbe,
          delayFactory: noOpClaudeDelay,
          environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
          providerOptions: {
            'settings': settingsPath,
            'sandbox': {'enabled': true},
          },
          containerManager: container,
        );
        addTeardownAsync(() => h.dispose());

        await h.start();

        expect(container.lastCommand, containsAll(['--settings', '/workspace/claude-settings.json']));
      });

      test('translates plain path-based settings for containerized execution without overlays', () async {
        final hostRoot = await Directory.systemTemp.createTemp('claude-settings-container-plain');
        addTearDown(() async {
          if (await hostRoot.exists()) {
            await hostRoot.delete(recursive: true);
          }
        });
        final container = FakeClaudeContainerExecutor(hostRoot: hostRoot.path, containerRoot: '/workspace');
        final settingsPath = p.join(hostRoot.path, 'claude-settings.json');
        File(settingsPath).writeAsStringSync('{}');

        final h = ClaudeCodeHarness(
          cwd: hostRoot.path,
          processFactory: defaultClaudeProcessFactory,
          commandProbe: defaultClaudeCommandProbe,
          delayFactory: noOpClaudeDelay,
          environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
          providerOptions: {'settings': settingsPath},
          containerManager: container,
        );
        addTeardownAsync(() => h.dispose());

        await h.start();

        expect(container.lastCommand, containsAll(['--settings', '/workspace/claude-settings.json']));
      });

      test('translates relative path-based settings after containerized restart for a task directory', () async {
        final hostRoot = await Directory.systemTemp.createTemp('claude-settings-container-restart');
        addTearDown(() async {
          if (await hostRoot.exists()) {
            await hostRoot.delete(recursive: true);
          }
        });
        final taskDir = Directory(p.join(hostRoot.path, 'task-worktree'))..createSync(recursive: true);
        final settingsPath = p.join(taskDir.path, '.claude', 'settings.json');
        Directory(p.dirname(settingsPath)).createSync(recursive: true);
        File(settingsPath).writeAsStringSync('{}');
        final container = FakeClaudeContainerExecutor(hostRoot: hostRoot.path, containerRoot: '/workspace');

        final h = ClaudeCodeHarness(
          cwd: hostRoot.path,
          processFactory: defaultClaudeProcessFactory,
          commandProbe: defaultClaudeCommandProbe,
          delayFactory: noOpClaudeDelay,
          environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
          providerOptions: const {'settings': '.claude/settings.json'},
          containerManager: container,
        );
        addTeardownAsync(() => h.dispose());

        await h.start();
        await h
            .turn(
              sessionId: 'task-session',
              messages: const [
                {'role': 'user', 'content': 'hello'},
              ],
              systemPrompt: 'system',
              directory: taskDir.path,
            )
            .catchError((_) => <String, dynamic>{});

        expect(container.lastCommand, containsAll(['--settings', '/workspace/task-worktree/.claude/settings.json']));
      });

      test('restarts in the requested working directory before a task turn', () async {
        final workingDirectories = <String?>[];

        final h = buildClaudeHarness(
          processFactory: resultEmittingFactory(
            result: const {'result': 'test response', 'cost_usd': 0.01, 'duration_ms': 100, 'duration_api_ms': 50},
            onSpawn: (spawn) => workingDirectories.add(spawn.workingDirectory),
          ),
        );
        addTeardownAsync(() => h.dispose());

        await h.start();
        await h.turn(
          sessionId: 'task-session',
          messages: const [
            {'role': 'user', 'content': 'edit code'},
          ],
          systemPrompt: 'system',
          directory: '/tmp/worktree/task-1',
        );

        expect(workingDirectories, containsAllInOrder(['/tmp', '/tmp/worktree/task-1']));
      });
    });

    // ----- state transitions ---------------------------------------------

    group('state transitions', () {
      test('crashed state on unexpected process exit', () async {
        final fakeProcess = makeClaudeFakeProcess();

        final h = buildClaudeHarness(processFactory: capturingInitFactory(process: fakeProcess));
        addTeardownAsync(() => h.dispose());

        await h.start();
        expect(h.state, WorkerState.idle);

        // Simulate unexpected exit.
        fakeProcess.exit(1);
        // Allow the exitCode future handler to fire.
        await Future<void>.delayed(Duration.zero);

        expect(h.state, WorkerState.crashed);
      });

      test('stop() transitions from idle to stopped', () async {
        final h = buildClaudeHarness();
        addTeardownAsync(() => h.dispose());

        await h.start();
        expect(h.state, WorkerState.idle);

        await h.stop();
        expect(h.state, WorkerState.stopped);
      });

      test('stop() from stopped is safe', () async {
        final h = buildClaudeHarness();
        expect(h.state, WorkerState.stopped);
        await h.stop();
        expect(h.state, WorkerState.stopped);
      });

      test('resetSessionContinuity stops the warm provider process', () async {
        final processes = <FakeProcess>[];
        final h = buildClaudeHarness(
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            final fake = FakeProcess(stdoutController: StreamController<List<int>>(), completeExitOnKill: true);
            processes.add(fake);
            scheduleMicrotask(() {
              fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
            });
            return fake;
          },
        );
        addTeardownAsync(() => h.dispose());

        await h.start();
        expect(h.state, WorkerState.idle);

        await h.resetSessionContinuity('sess-reset');

        expect(h.state, WorkerState.stopped);
        expect(processes.single.killCalled, isTrue);

        await h.start();
        expect(processes, hasLength(2));
        expect(h.state, WorkerState.idle);
      });
    });

    // ----- dispose() -----------------------------------------------------

    group('dispose()', () {
      test('transitions to stopped and closes event stream', () async {
        final h = buildClaudeHarness();
        await h.start();
        expect(h.state, WorkerState.idle);

        await h.dispose();
        expect(h.state, WorkerState.stopped);

        // Event stream should be closed — adding a listener should get done.
        final events = <dynamic>[];
        h.events.listen(events.add);
        await Future<void>.delayed(Duration.zero);
        expect(events, isEmpty);
      });

      test('is idempotent', () async {
        final h = buildClaudeHarness();
        await h.start();

        await h.dispose();
        await h.dispose(); // should not throw
        expect(h.state, WorkerState.stopped);
      });

      test('kills the spawned process', () async {
        final fakeProcess = makeClaudeFakeProcess();

        final h = buildClaudeHarness(processFactory: capturingInitFactory(process: fakeProcess));

        await h.start();

        // Wrap kill to detect it. FakeProcess.kill always returns true,
        // but we verify dispose invokes stop() which calls kill.
        // We can verify state is stopped as a proxy.
        await h.dispose();
        expect(h.state, WorkerState.stopped);
      });
    });

    // ----- events stream -------------------------------------------------

    group('events stream', () {
      test('is a broadcast stream', () {
        final h = ClaudeCodeHarness(cwd: '/tmp');
        // Broadcast streams allow multiple listeners.
        h.events.listen((_) {});
        h.events.listen((_) {});
        addTeardownAsync(() => h.dispose());
      });
    });

    // ----- prompt strategy / append protocol ------------------------------

    group('prompt strategy', () {
      test('promptStrategy is append', () {
        final h = ClaudeCodeHarness(cwd: '/tmp');
        expect(h.promptStrategy, PromptStrategy.append);
      });

      test('spawn args include --append-system-prompt when configured', () async {
        List<String>? capturedArgs;

        final h = buildClaudeHarness(
          harnessConfig: const HarnessConfig(appendSystemPrompt: 'test behavior prompt'),
          processFactory: capturingInitFactory(
            onSpawn: (spawn) {
              capturedArgs = spawn.args;
            },
          ),
        );
        addTeardownAsync(() => h.dispose());

        await h.start();

        expect(capturedArgs, isNotNull);
        final idx = capturedArgs!.indexOf('--append-system-prompt');
        expect(idx, greaterThanOrEqualTo(0), reason: '--append-system-prompt flag should be present');
        expect(capturedArgs![idx + 1], 'test behavior prompt');
      });

      test('spawn args omit --append-system-prompt when not configured', () async {
        List<String>? capturedArgs;

        final h = buildClaudeHarness(
          processFactory: capturingInitFactory(
            onSpawn: (spawn) {
              capturedArgs = spawn.args;
            },
          ),
        );
        addTeardownAsync(() => h.dispose());

        await h.start();

        expect(capturedArgs, isNotNull);
        expect(capturedArgs, isNot(contains('--append-system-prompt')));
      });

      test('JSONL payload omits system_prompt for append-strategy harness', () async {
        late CapturingFakeProcess fake;

        final h = buildClaudeHarness(
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            fake = makeCapturingClaudeProcess();
            scheduleMicrotask(() {
              fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
            });
            // Emit turn result so the turn completes
            Future.delayed(const Duration(milliseconds: 20), () {
              fake.emitStdout(
                jsonEncode({
                  'type': 'result',
                  'result': 'test response',
                  'cost_usd': 0.01,
                  'duration_ms': 100,
                  'duration_api_ms': 50,
                  'num_turns': 1,
                  'is_error': false,
                  'session_id': 'test-session',
                }),
              );
            });
            return fake;
          },
        );
        addTeardownAsync(() => h.dispose());

        await h.start();
        expect(h.promptStrategy, PromptStrategy.append);

        await h.turn(
          sessionId: 'test',
          messages: [
            {'role': 'user', 'content': 'hello'},
          ],
          systemPrompt: 'this should NOT appear in payload',
        );

        // Find the user-type payload (the turn message)
        final userPayloads = fake.capturedStdinJson.where((p) => p['type'] == 'user').toList();
        expect(userPayloads, isNotEmpty, reason: 'Should have sent a user message');
        for (final p in userPayloads) {
          expect(
            p.containsKey('system_prompt'),
            isFalse,
            reason: 'Append-strategy harness should not send system_prompt in JSONL',
          );
        }
      });
    });

    group('hook callbacks', () {
      test('can_use_tool denies when dontAsk mode unexpectedly emits a native permission request', () async {
        late CapturingFakeProcess fake;

        final h = buildClaudeHarness(
          providerOptions: const {'permissionMode': 'dontAsk'},
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            fake = makeCapturingClaudeProcess();
            scheduleMicrotask(() {
              fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
            });
            return fake;
          },
        );
        addTeardownAsync(() => h.dispose());

        await h.start();
        fake.emitStdout(
          jsonEncode({
            'type': 'control_request',
            'request_id': 'req-permission',
            'request': {'subtype': 'can_use_tool', 'tool_use_id': 'tool-1'},
          }),
        );

        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(
          fake.capturedStdinJson,
          contains(containsPair('response', containsPair('response', containsPair('behavior', 'deny')))),
        );
      });

      test('PreToolUse maps Claude tool names before guard evaluation and preserves raw provider name', () async {
        final guard = RecordingGuard();
        late CapturingFakeProcess fake;
        List<String>? capturedArgs;

        final h = ClaudeCodeHarness(
          cwd: '/tmp',
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            capturedArgs = args;
            fake = makeCapturingClaudeProcess();
            scheduleMicrotask(() {
              fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
            });
            return fake;
          },
          commandProbe: defaultClaudeCommandProbe,
          delayFactory: noOpClaudeDelay,
          environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
          guardChain: GuardChain(guards: [guard]),
        );
        addTeardownAsync(() => h.dispose());
        final events = <BridgeEvent>[];
        final sub = h.events.listen(events.add);
        addTeardownAsync(() => sub.cancel());

        await h.start();
        expect(capturedArgs, isNot(contains('--setting-sources')));
        fake.emitStdout(
          jsonEncode({
            'type': 'control_request',
            'request_id': 'req-hook',
            'request': {
              'subtype': 'hook_callback',
              'input': {
                'hook_event_name': 'PreToolUse',
                'tool_name': 'Bash',
                'tool_input': {'command': 'git status'},
              },
            },
          }),
        );

        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(guard.lastContext, isNotNull);
        expect(guard.lastContext!.toolName, 'shell');
        expect(guard.lastContext!.rawProviderToolName, 'Bash');
        expect(guard.lastContext!.toolInput, {'command': 'git status'});
        expect(
          events,
          contains(
            isA<ToolApprovalWaitEvent>()
                .having((event) => event.requestId, 'requestId', 'req-hook')
                .having((event) => event.toolName, 'toolName', 'Bash'),
          ),
        );
        expect(
          events,
          contains(isA<ToolApprovalResolvedEvent>().having((event) => event.requestId, 'requestId', 'req-hook')),
        );
        expect(
          fake.capturedStdinJson,
          contains(
            containsPair(
              'response',
              containsPair('response', containsPair('hookSpecificOutput', containsPair('hookEventName', 'PreToolUse'))),
            ),
          ),
        );
      });

      test('PreToolUse does not emit approval resolved when hook response write fails', () async {
        final guard = RecordingGuard();
        final fake = FailingWriteClaudeProcess();
        List<String>? capturedArgs;

        final h = ClaudeCodeHarness(
          cwd: '/tmp',
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            capturedArgs = args;
            scheduleMicrotask(() {
              fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
            });
            return fake;
          },
          commandProbe: defaultClaudeCommandProbe,
          delayFactory: noOpClaudeDelay,
          environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
          guardChain: GuardChain(guards: [guard]),
        );
        addTeardownAsync(() => h.dispose());
        final events = <BridgeEvent>[];
        final sub = h.events.listen(events.add);
        addTeardownAsync(() => sub.cancel());

        await h.start();
        expect(capturedArgs, isNot(contains('--setting-sources')));
        fake.failWrites = true;
        fake.emitStdout(
          jsonEncode({
            'type': 'control_request',
            'request_id': 'req-hook-fails',
            'request': {
              'subtype': 'hook_callback',
              'input': {
                'hook_event_name': 'PreToolUse',
                'tool_name': 'Bash',
                'tool_input': {'command': 'git status'},
              },
            },
          }),
        );

        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(
          events,
          contains(
            isA<ToolApprovalWaitEvent>()
                .having((event) => event.requestId, 'requestId', 'req-hook-fails')
                .having((event) => event.toolName, 'toolName', 'Bash'),
          ),
        );
        expect(
          events.whereType<ToolApprovalResolvedEvent>().map((event) => event.requestId),
          isNot(contains('req-hook-fails')),
        );
      });

      test('PreToolUse evaluates unmapped Claude tools under claude: prefix and logs warning', () async {
        final guard = RecordingGuard();
        final records = <LogRecord>[];
        final oldLevel = Logger.root.level;
        late CapturingFakeProcess fake;
        Logger.root.level = Level.ALL;
        final sub = Logger.root.onRecord.listen(records.add);
        addTearDown(() async {
          Logger.root.level = oldLevel;
          await sub.cancel();
        });

        final h = ClaudeCodeHarness(
          cwd: '/tmp',
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            fake = makeCapturingClaudeProcess();
            scheduleMicrotask(() {
              fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
            });
            return fake;
          },
          commandProbe: defaultClaudeCommandProbe,
          delayFactory: noOpClaudeDelay,
          environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
          guardChain: GuardChain(guards: [guard]),
        );
        addTeardownAsync(() => h.dispose());

        await h.start();
        fake.emitStdout(
          jsonEncode({
            'type': 'control_request',
            'request_id': 'req-hook-unmapped',
            'request': {
              'subtype': 'hook_callback',
              'input': {
                'hook_event_name': 'PreToolUse',
                'tool_name': 'TodoWrite',
                'tool_input': {'todos': []},
              },
            },
          }),
        );

        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(guard.lastContext, isNotNull);
        expect(guard.lastContext!.toolName, 'claude:TodoWrite');
        expect(guard.lastContext!.rawProviderToolName, 'TodoWrite');
        expect(
          records.any(
            (record) =>
                record.loggerName == 'ClaudeCodeHarness' &&
                record.level == Level.WARNING &&
                record.message.contains('Falling back to unmapped Claude tool name: TodoWrite -> claude:TodoWrite'),
          ),
          isTrue,
        );
        expect(fake.capturedStdinJson, isNotEmpty);
      });
    });

    // ----- PreCompact hook + CompactBoundary ----------------------------------

    group('PreCompact hook callback', () {
      test('PreCompact hook callback invokes onCompactionStarting with sessionId and trigger', () async {
        String? capturedSessionId;
        String? capturedTrigger;
        late CapturingFakeProcess fake;

        final h = ClaudeCodeHarness(
          cwd: '/tmp',
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            fake = makeCapturingClaudeProcess();
            scheduleMicrotask(() {
              fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
            });
            return fake;
          },
          commandProbe: defaultClaudeCommandProbe,
          delayFactory: noOpClaudeDelay,
          environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
        );
        h.onCompactionStarting = (sid, trigger) {
          capturedSessionId = sid;
          capturedTrigger = trigger;
        };
        addTeardownAsync(() => h.dispose());

        await h.start();

        fake.emitStdout(
          jsonEncode({
            'type': 'control_request',
            'request_id': 'req-compact',
            'request': {
              'subtype': 'hook_callback',
              'input': {'hook_event_name': 'PreCompact', 'session_id': 'sess-abc', 'trigger': 'auto'},
            },
          }),
        );

        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(capturedSessionId, 'sess-abc');
        expect(capturedTrigger, 'auto');
        // Response must be allow: true
        expect(
          fake.capturedStdinJson,
          contains(containsPair('response', containsPair('response', allOf(containsPair('continue', true))))),
        );
      });

      test('compact_boundary stdout message invokes onCompactionCompleted with trigger and preTokens', () async {
        String? capturedTrigger;
        int? capturedPreTokens;
        final fake = makeClaudeFakeProcess();

        final h = buildClaudeHarness(processFactory: capturingInitFactory(process: fake));
        h.onCompactionCompleted = (trigger, preTokens) {
          capturedTrigger = trigger;
          capturedPreTokens = preTokens;
        };
        addTeardownAsync(() => h.dispose());

        await h.start();
        fake.emitStdout(
          jsonEncode({'type': 'system', 'subtype': 'compact_boundary', 'trigger': 'manual', 'pre_tokens': 99000}),
        );

        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(capturedTrigger, 'manual');
        expect(capturedPreTokens, 99000);
      });

      test('compact_boundary with null pre_tokens calls onCompactionCompleted with null', () async {
        int? callCount = 0;
        int? capturedPreTokens = -1; // sentinel
        final fake = makeClaudeFakeProcess();

        final h = buildClaudeHarness(processFactory: capturingInitFactory(process: fake));
        h.onCompactionCompleted = (trigger, preTokens) {
          callCount = (callCount ?? 0) + 1;
          capturedPreTokens = preTokens;
        };
        addTeardownAsync(() => h.dispose());

        await h.start();
        fake.emitStdout(jsonEncode({'type': 'system', 'subtype': 'compact_boundary', 'trigger': 'auto'}));

        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(callCount, 1);
        expect(capturedPreTokens, isNull);
      });

      test('supportsPreCompactHook returns true', () {
        final h = ClaudeCodeHarness(cwd: '/tmp');
        expect(h.supportsPreCompactHook, isTrue);
      });

      test('initialize request includes PreCompact hook', () async {
        late CapturingFakeProcess fake;

        final h = ClaudeCodeHarness(
          cwd: '/tmp',
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            fake = makeCapturingClaudeProcess();
            scheduleMicrotask(() {
              fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
            });
            return fake;
          },
          commandProbe: defaultClaudeCommandProbe,
          delayFactory: noOpClaudeDelay,
          environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
        );
        addTeardownAsync(() => h.dispose());

        await h.start();

        final initReq = fake.capturedStdinJson.firstWhere(
          (m) => m['type'] == 'control_request' && (m['request'] as Map?)?.containsKey('hooks') == true,
          orElse: () => throw StateError('No initialize control_request found'),
        );
        final hooks = (initReq['request'] as Map<String, dynamic>)['hooks'] as Map<String, dynamic>;
        expect(hooks.containsKey('PreCompact'), isTrue);
        final preCompactEntry = (hooks['PreCompact'] as List).first as Map<String, dynamic>;
        expect(preCompactEntry['hookCallbackIds'], contains('hook_pre_compact'));
      });
    });

    // ----- SIGKILL escalation during stop --------------------------------

    group('SIGKILL escalation', () {
      test('stop() escalates to SIGKILL when process does not exit after SIGTERM', () async {
        final fake = KillTrackingFakeProcess();

        final h = ClaudeCodeHarness(
          cwd: '/tmp',
          killGracePeriod: const Duration(milliseconds: 50),
          processFactory: capturingInitFactory(process: fake),
          commandProbe: defaultClaudeCommandProbe,
          delayFactory: noOpClaudeDelay,
          environment: {'ANTHROPIC_API_KEY': 'sk-test-key'},
        );

        await h.start();
        expect(h.state, WorkerState.idle);

        // Schedule process exit after SIGKILL would be sent.
        Timer(const Duration(milliseconds: 100), () => fake.exit(137));

        await h.stop();

        expect(h.state, WorkerState.stopped);
        // First signal is SIGTERM from stop(), second is SIGKILL from escalation.
        expect(fake.killSignals, hasLength(greaterThanOrEqualTo(2)));
        expect(fake.killSignals.first, ProcessSignal.sigterm);
        if (!Platform.isWindows) {
          expect(fake.killSignals.last, ProcessSignal.sigkill);
        }
      });

      test('stop() does not escalate to SIGKILL when process exits promptly on SIGTERM', () async {
        final fake = KillTrackingFakeProcess(completeExitOnKill: true);

        final h = ClaudeCodeHarness(
          cwd: '/tmp',
          killGracePeriod: const Duration(seconds: 5),
          processFactory: capturingInitFactory(process: fake),
          commandProbe: defaultClaudeCommandProbe,
          delayFactory: noOpClaudeDelay,
          environment: {'ANTHROPIC_API_KEY': 'sk-test-key'},
        );

        await h.start();
        await h.stop();

        expect(h.state, WorkerState.stopped);
        // Only SIGTERM — no escalation needed.
        expect(fake.killSignals, [ProcessSignal.sigterm]);
      });
    });

    // -------------------------------------------------------------------------
    // T11: Effort tolerance — null -> non-null does not restart harness
    // -------------------------------------------------------------------------

    group('T11: Effort tolerance', () {
      test('null processEffort adopts first-use non-null effort without restart', () async {
        var spawnCount = 0;

        Future<Process> makeProcess() async {
          spawnCount++;
          final fake = makeCapturingClaudeProcess();
          scheduleMicrotask(() {
            fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
          });
          Future.delayed(const Duration(milliseconds: 20), () {
            fake.emitStdout(
              jsonEncode({
                'type': 'result',
                'result': 'ok',
                'cost_usd': 0.001,
                'duration_ms': 10,
                'duration_api_ms': 5,
                'num_turns': 1,
                'is_error': false,
                'session_id': 'test-session',
              }),
            );
          });
          return fake;
        }

        // Harness spawned with no effort (null).
        final h = ClaudeCodeHarness(
          cwd: '/tmp',
          harnessConfig: const HarnessConfig(effort: null),
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) =>
              makeProcess(),
          commandProbe: defaultClaudeCommandProbe,
          delayFactory: noOpClaudeDelay,
          environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
        );
        addTeardownAsync(() => h.dispose());

        await h.start();
        expect(spawnCount, 1, reason: 'Should spawn exactly once on start');

        // Call turn() with effort: 'medium' — should be adopted without restart.
        await h.turn(
          sessionId: 'test',
          messages: const [
            {'role': 'user', 'content': 'hello'},
          ],
          systemPrompt: '',
          effort: 'medium',
        );

        // Only one spawn — no restart triggered for null -> 'medium' adoption.
        expect(spawnCount, 1, reason: 'First-use adoption must not trigger a restart');
        expect(h.state, WorkerState.idle);
      });

      test('non-null -> different non-null effort triggers restart', () async {
        var spawnCount = 0;

        Future<Process> makeProcess() async {
          spawnCount++;
          final fake = makeClaudeFakeProcess();
          scheduleMicrotask(() {
            fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
          });
          Future.delayed(const Duration(milliseconds: 20), () {
            fake.emitStdout(
              jsonEncode({
                'type': 'result',
                'result': 'ok',
                'cost_usd': 0.001,
                'duration_ms': 10,
                'duration_api_ms': 5,
                'num_turns': 1,
                'is_error': false,
                'session_id': 'test-session',
              }),
            );
          });
          return fake;
        }

        final h = ClaudeCodeHarness(
          cwd: '/tmp',
          harnessConfig: const HarnessConfig(effort: 'low'),
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) =>
              makeProcess(),
          commandProbe: defaultClaudeCommandProbe,
          delayFactory: noOpClaudeDelay,
          environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
        );
        addTeardownAsync(() => h.dispose());

        await h.start();
        expect(spawnCount, 1);

        // Turn with different effort — should trigger restart.
        await h.turn(
          sessionId: 'test',
          messages: const [
            {'role': 'user', 'content': 'hello'},
          ],
          systemPrompt: '',
          effort: 'high',
        );

        expect(spawnCount, 2, reason: 'Different non-null effort must trigger restart');
      });
    });

    // -------------------------------------------------------------------------
    // T12: Restart mid-session produces <conversation_history> in JSONL
    // -------------------------------------------------------------------------

    group('T12: Restart mid-session produces conversation_history', () {
      test('second spawn receives <conversation_history> when messages > 1', () async {
        var spawnCount = 0;
        late CapturingFakeProcess lastFake;

        Future<Process> makeProcess() async {
          spawnCount++;
          final fake = makeCapturingClaudeProcess();
          lastFake = fake;
          scheduleMicrotask(() {
            fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
          });
          // Schedule a turn result so the turn call completes.
          Future.delayed(const Duration(milliseconds: 30), () {
            fake.emitStdout(
              jsonEncode({
                'type': 'result',
                'result': 'done',
                'cost_usd': 0.001,
                'duration_ms': 10,
                'duration_api_ms': 5,
                'num_turns': 1,
                'is_error': false,
                'session_id': 's1',
              }),
            );
          });
          return fake;
        }

        final h = ClaudeCodeHarness(
          cwd: '/tmp',
          harnessConfig: const HarnessConfig(model: 'sonnet'),
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) =>
              makeProcess(),
          commandProbe: defaultClaudeCommandProbe,
          delayFactory: noOpClaudeDelay,
          environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
        );
        addTeardownAsync(() => h.dispose());

        await h.start();

        // First turn (warm — no history injection).
        await h.turn(
          sessionId: 'test',
          messages: const [
            {'role': 'user', 'content': 'first message'},
          ],
          systemPrompt: '',
        );
        expect(spawnCount, 1);

        // Second turn with model change — triggers restart (cold process).
        // Pass 3 messages: prior user+assistant pair + the current user message.
        // The history block requires at least one complete user+assistant exchange.
        await h.turn(
          sessionId: 'test',
          messages: const [
            {'role': 'user', 'content': 'first message'},
            {'role': 'assistant', 'content': 'first response'},
            {'role': 'user', 'content': 'second message'},
          ],
          systemPrompt: '',
          model: 'opus',
        );
        expect(spawnCount, 2, reason: 'Model change should trigger restart');

        // The payload sent to the second process should contain conversation_history.
        final userPayloads = lastFake.capturedStdinJson.where((p) => p['type'] == 'user').toList();
        final secondTurnPayload = userPayloads.last;
        final messageContent = secondTurnPayload['message']?['content'] as String? ?? '';
        expect(
          messageContent,
          contains('<conversation_history>'),
          reason: 'Cold process turn with prior messages must inject conversation history',
        );
      });
    });

    // -------------------------------------------------------------------------
    // T13: Parameter-change restart emits warning log
    // -------------------------------------------------------------------------

    group('T13: Parameter-change restart emits warning log', () {
      test('model change restart emits Restarting harness warning', () async {
        final logRecords = <LogRecord>[];
        final sub = Logger('ClaudeCodeHarness').onRecord.listen(logRecords.add);
        addTearDown(sub.cancel);

        Future<Process> makeProcess() async {
          final fake = makeClaudeFakeProcess();
          scheduleMicrotask(() {
            fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
          });
          Future.delayed(const Duration(milliseconds: 20), () {
            fake.emitStdout(
              jsonEncode({
                'type': 'result',
                'result': 'ok',
                'cost_usd': 0.001,
                'duration_ms': 10,
                'duration_api_ms': 5,
                'num_turns': 1,
                'is_error': false,
                'session_id': 's1',
              }),
            );
          });
          return fake;
        }

        final h = ClaudeCodeHarness(
          cwd: '/tmp',
          harnessConfig: const HarnessConfig(model: 'sonnet'),
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) =>
              makeProcess(),
          commandProbe: defaultClaudeCommandProbe,
          delayFactory: noOpClaudeDelay,
          environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
        );
        addTeardownAsync(() => h.dispose());

        await h.start();

        // Trigger a model-change restart.
        await h.turn(
          sessionId: 'test',
          messages: const [
            {'role': 'user', 'content': 'hello'},
          ],
          systemPrompt: '',
          model: 'opus',
        );

        final warnings = logRecords
            .where((r) => r.level == Level.WARNING && r.message.contains('Restarting harness due to parameter change'))
            .toList();
        expect(warnings, isNotEmpty, reason: 'Should emit warning on parameter-change restart');
        expect(warnings.first.message, contains('model:'));
      });
    });
  });
}

/// Registers async teardown — shorthand for [addTearDown] with async closures.
void addTeardownAsync(Future<void> Function() fn) => addTearDown(fn);
