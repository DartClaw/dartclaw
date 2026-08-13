import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' show PlatformCapabilities, UnsupportedCapabilityError;
import 'package:dartclaw_core/src/agents/tool_policy_cascade.dart';
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
      test('probes the configured Claude binary directly', () async {
        var probeCalled = false;
        String? probeExe;
        List<String>? probeArgs;

        final h = buildClaudeHarness(
          platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
          commandProbe: (exe, args) async {
            probeCalled = true;
            probeExe = exe;
            probeArgs = args;
            return processResult(exitCode: 0, stdout: 'C:\\Program Files\\Claude\\claude.exe\r\n');
          },
        );

        await h.start();
        addTeardownAsync(() => h.dispose());

        expect(probeCalled, isTrue);
        expect(probeExe, 'claude');
        expect(probeArgs, ['--version']);
      });

      test('throws structured lookup error when the Claude probe throws', () async {
        final h = buildClaudeHarness(
          commandProbe: (_, _) async => throw ProcessException('claude', ['--version'], 'probe failed'),
        );
        addTeardownAsync(() => h.dispose());

        await expectLater(
          h.start(),
          throwsA(isA<UnsupportedCapabilityError>().having((e) => e.attemptedContext, 'context', 'claude --version')),
        );
      });

      test('does not misreport unexpected Claude probe errors as missing executable', () async {
        final h = buildClaudeHarness(commandProbe: (_, _) async => throw StateError('probe bug'));
        addTeardownAsync(() => h.dispose());

        await expectLater(h.start(), throwsA(isA<StateError>().having((e) => e.message, 'message', 'probe bug')));
      });

      test('throws structured lookup error when the Claude probe returns only whitespace', () async {
        final h = buildClaudeHarness(commandProbe: (_, _) async => processResult(exitCode: 0, stdout: ' \r\n\t'));
        addTeardownAsync(() => h.dispose());

        await expectLater(h.start(), throwsA(isA<UnsupportedCapabilityError>()));
      });

      test('throws structured lookup error when the Claude binary is missing', () async {
        final h = buildClaudeHarness(
          platformCapabilities: PlatformCapabilities(operatingSystem: 'linux'),
          commandProbe: (exe, args) async => processResult(exitCode: 1),
        );
        addTeardownAsync(() => h.dispose());

        await expectLater(
          h.start(),
          throwsA(isA<UnsupportedCapabilityError>().having((e) => e.attemptedContext, 'context', 'claude --version')),
        );
      });

      test('initialize timeout releases a confirmed Windows root for retry', () async {
        final process = FakeProcess(completeExitOnKill: true);
        var spawnCount = 0;
        final h = buildClaudeHarness(
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            spawnCount++;
            return process;
          },
          initializeTimeout: Duration.zero,
          platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
        );
        addTeardownAsync(() => h.dispose());

        await expectLater(h.start(), throwsStateError);
        expect(process.killSignals, [ProcessSignal.sigterm]);

        await expectLater(h.start(), throwsStateError);
        expect(spawnCount, 2);
      });

      test('throws when ANTHROPIC_API_KEY missing and OAuth check fails', () async {
        var callCount = 0;
        final h = buildClaudeHarness(
          environment: {}, // no API key
          commandProbe: (exe, args) async {
            callCount++;
            if (args.contains('--version')) return processResult(exitCode: 0, stdout: '2.1.0');
            // auth status check fails
            return processResult(exitCode: 1);
          },
        );
        addTeardownAsync(() => h.dispose());

        await expectLater(
          h.start(),
          throwsA(isA<StateError>().having((e) => e.message, 'message', contains('No authentication configured'))),
        );
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
          systemPrompt: '',
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

      test('spawn failure deletes the credential-bearing MCP config', () async {
        late String configPath;
        final h = buildClaudeHarness(
          harnessConfig: const HarnessConfig(mcpServerUrl: 'http://127.0.0.1:3333/mcp', mcpGatewayToken: 'test-token'),
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            configPath = args[args.indexOf('--mcp-config') + 1];
            throw StateError('spawn failed');
          },
        );
        addTeardownAsync(() => h.dispose());

        await expectLater(h.start(), throwsStateError);

        expect(File(configPath).existsSync(), isFalse);
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

      test('suppresses provider-native web tools for a workspace container', () async {
        // The tools run at the provider, outside `network:none`, so the host
        // gateway 403s any request declaring one — in every profile, not just
        // restricted. Declaring them would fail the turn, not enable it.
        final hostRoot = await Directory.systemTemp.createTemp('claude-container-web-tools');
        addTearDown(() async {
          if (await hostRoot.exists()) {
            await hostRoot.delete(recursive: true);
          }
        });
        final container = FakeClaudeContainerExecutor(hostRoot: hostRoot.path, containerRoot: '/workspace');

        final h = ClaudeCodeHarness(
          cwd: hostRoot.path,
          processFactory: defaultClaudeProcessFactory,
          commandProbe: defaultClaudeCommandProbe,
          delayFactory: noOpClaudeDelay,
          environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
          harnessConfig: const HarnessConfig(disallowedTools: ['Computer']),
          containerManager: container,
        );
        addTeardownAsync(() => h.dispose());

        await h.start();

        final initialize = container.spawned!.capturedStdinJson.firstWhere(
          (message) => (message['request'] as Map?)?['subtype'] == 'initialize',
        );
        expect(
          ((initialize['request'] as Map)['disallowedTools'] as List).cast<String>(),
          containsAll(['Computer', 'WebSearch', 'WebFetch']),
        );
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
      test('authentication failure preserves detail and does not poison the next turn', () async {
        final fake = makeClaudeFakeProcess();
        final harness = buildClaudeHarness(processFactory: capturingInitFactory(process: fake));
        addTeardownAsync(() => harness.dispose());
        await harness.start();

        final failedTurn = harness.turn(
          sessionId: 'auth-session',
          messages: const [
            {'role': 'user', 'content': 'first'},
          ],
          systemPrompt: '',
        );
        await pumpEventQueue();
        fake.emitStdout(
          jsonEncode({
            'type': 'result',
            'is_error': true,
            'stop_reason': 'stop_sequence',
            'result': 'Failed to authenticate. API Error: 401 Invalid authentication credentials',
          }),
        );
        final failed = await failedTurn;
        expect(failed['stop_reason'], 'error');
        expect(failed['is_error'], isTrue);
        expect(failed['error'], contains('401 Invalid authentication credentials'));
        expect(harness.state, WorkerState.idle);

        final nextTurn = harness.turn(
          sessionId: 'auth-session',
          messages: const [
            {'role': 'user', 'content': 'second'},
          ],
          systemPrompt: '',
        );
        await pumpEventQueue();
        fake.emitStdout(jsonEncode({'type': 'result', 'is_error': false, 'stop_reason': 'end_turn', 'result': 'ok'}));
        final succeeded = await nextTurn;
        expect(succeeded['stop_reason'], 'end_turn');
        expect(succeeded['is_error'], isFalse);
        expect(harness.state, WorkerState.idle);
      });

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

      test('logical-agent persona and model restart once, then empty restores defaults once', () async {
        final spawns = <List<String>>[];
        final h = buildClaudeHarness(
          harnessConfig: const HarnessConfig(model: 'opus', appendSystemPrompt: 'DEFAULT'),
          processFactory: resultEmittingFactory(onSpawn: (spawn) => spawns.add(spawn.args)),
        );
        addTeardownAsync(() => h.dispose());

        await h.start();
        await h.turn(
          sessionId: 'logical-agent',
          messages: const [
            {'role': 'user', 'content': 'search'},
          ],
          systemPrompt: 'SEARCH PERSONA',
          model: 'sonnet',
        );
        await h.turn(
          sessionId: 'ordinary',
          messages: const [
            {'role': 'user', 'content': 'continue'},
          ],
          systemPrompt: '',
        );
        expect(spawns, hasLength(3));
        expect(spawns[1], containsAllInOrder(['--model', 'sonnet']));
        expect(spawns[1], containsAllInOrder(['--append-system-prompt', 'SEARCH PERSONA']));
        expect(spawns[2], containsAllInOrder(['--model', 'opus']));
        expect(spawns[2], containsAllInOrder(['--append-system-prompt', 'DEFAULT']));
      });

      test('logical-agent model and effort restart even when persona matches the configured prompt', () async {
        final spawns = <List<String>>[];
        final h = buildClaudeHarness(
          harnessConfig: const HarnessConfig(appendSystemPrompt: 'DEFAULT'),
          processFactory: resultEmittingFactory(onSpawn: (spawn) => spawns.add(spawn.args)),
        );
        addTeardownAsync(() => h.dispose());

        await h.start();
        await h.turn(
          sessionId: 'logical-agent',
          agentId: 'search',
          messages: const [
            {'role': 'user', 'content': 'search'},
          ],
          systemPrompt: 'DEFAULT',
          model: 'sonnet',
          effort: 'high',
        );

        expect(spawns, hasLength(2));
        expect(spawns[1], containsAllInOrder(['--model', 'sonnet']));
        expect(spawns[1], containsAllInOrder(['--effort', 'high']));
      });

      test('primary memory revision change restarts once with the full scoped append prompt', () async {
        final spawns = <List<String>>[];
        const revision41 = 'SAFE STATIC CONTENT\n\nCollection revision: 41';
        const revision42 = 'SAFE STATIC CONTENT\n\nCollection revision: 42';
        final h = buildClaudeHarness(
          harnessConfig: const HarnessConfig(appendSystemPrompt: revision41),
          processFactory: resultEmittingFactory(onSpawn: (spawn) => spawns.add(spawn.args)),
        );
        addTeardownAsync(() => h.dispose());

        await h.start();
        await h.turn(
          sessionId: 'primary',
          messages: const [
            {'role': 'user', 'content': 'first'},
          ],
          systemPrompt: revision41,
        );
        await h.turn(
          sessionId: 'primary',
          messages: const [
            {'role': 'user', 'content': 'second'},
          ],
          systemPrompt: revision42,
        );
        expect(spawns, hasLength(2));
        expect(spawns[1], containsAllInOrder(['--append-system-prompt', revision42]));
        expect(spawns[1], isNot(contains(revision41)));
      });

      test('explicit non-primary prompt displaces configured primary memory', () async {
        final spawns = <List<String>>[];
        const primaryPrompt = 'PRIVATE MEMORY SENTINEL\n\nCollection revision: 42';
        const restrictedPrompt = 'SAFE RESTRICTED CONTENT';
        final h = buildClaudeHarness(
          harnessConfig: const HarnessConfig(appendSystemPrompt: primaryPrompt),
          processFactory: resultEmittingFactory(onSpawn: (spawn) => spawns.add(spawn.args)),
        );
        addTeardownAsync(() => h.dispose());

        await h.start();
        await h.turn(
          sessionId: 'restricted',
          messages: const [
            {'role': 'user', 'content': 'background work'},
          ],
          systemPrompt: restrictedPrompt,
        );

        expect(spawns, hasLength(2));
        expect(spawns[1], containsAllInOrder(['--append-system-prompt', restrictedPrompt]));
        expect(spawns[1], isNot(contains('PRIVATE MEMORY SENTINEL')));
        expect(spawns[1], isNot(contains('Collection revision: 42')));
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

      test('PreToolUse blocks with the logical-agent identity and DartClaw session id', () async {
        final guard = RecordingGuard(verdict: GuardVerdict.block('blocked'));
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
        final turnFuture = h.turn(
          sessionId: 's-123',
          agentId: 'search',
          messages: const [
            {'role': 'user', 'content': 'search'},
          ],
          systemPrompt: '',
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
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
        expect(guard.lastContext!.sessionId, 's-123');
        expect(guard.lastContext!.agentId, 'search');
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
              containsPair('response', containsPair('hookSpecificOutput', containsPair('permissionDecision', 'deny'))),
            ),
          ),
        );
        fake.emitStdout(jsonEncode({'type': 'result', 'result': 'done', 'is_error': false}));
        await turnFuture;

        fake.emitStdout(
          jsonEncode({
            'type': 'control_request',
            'request_id': 'req-hook-after-turn',
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

        expect(guard.contexts, hasLength(2));
        expect(guard.contexts.last.sessionId, isNull);
        expect(guard.contexts.last.agentId, isNull);
      });

      test('PreToolUse blocks a closed-set logical agent from its ungranted own-MCP tool', () async {
        late CapturingFakeProcess fake;
        final guard = ToolPolicyGuard(
          cascade: ToolPolicyCascade(
            agentAllow: {
              'search': {'web_search', 'web_fetch'},
            },
          ),
        );
        final h = buildClaudeHarness(
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            fake = makeCapturingClaudeProcess();
            scheduleMicrotask(() {
              fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
            });
            return fake;
          },
          guardChain: GuardChain(guards: [guard]),
        );
        addTeardownAsync(() => h.dispose());

        await h.start();
        final turnFuture = h.turn(
          sessionId: 's-mcp',
          agentId: 'search',
          messages: const [
            {'role': 'user', 'content': 'continue agent session'},
          ],
          systemPrompt: '',
        );
        await pumpEventQueue();
        fake.emitStdout(
          jsonEncode({
            'type': 'control_request',
            'request_id': 'req-mcp-hook',
            'request': {
              'subtype': 'hook_callback',
              'input': {
                'hook_event_name': 'PreToolUse',
                'tool_name': 'mcp__dartclaw__sessions_send',
                'tool_input': {'agent': 'worker', 'message': 'do work'},
              },
            },
          }),
        );
        await pumpEventQueue();

        expect(
          fake.capturedStdinJson,
          contains(
            containsPair(
              'response',
              containsPair('response', containsPair('hookSpecificOutput', containsPair('permissionDecision', 'deny'))),
            ),
          ),
        );
        fake.exit(1);
        await turnFuture.catchError((_) => <String, dynamic>{});
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

      test('malformed hook callbacks deny exactly once and do not poison later valid callbacks', () async {
        final guard = RecordingGuard();
        late CapturingFakeProcess fake;
        final h = buildClaudeHarness(
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            fake = makeCapturingClaudeProcess();
            scheduleMicrotask(() {
              fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
            });
            return fake;
          },
          guardChain: GuardChain(guards: [guard]),
        );
        addTeardownAsync(() => h.dispose());
        await h.start();

        final malformedInputs = <Object?>[
          null,
          const [],
          const <String, dynamic>{},
          const {'hook_event_name': 'Unknown', 'tool_name': 'Bash', 'tool_input': <String, dynamic>{}},
          const {'hook_event_name': 'PreToolUse', 'tool_name': 42, 'tool_input': <String, dynamic>{}},
          const {'hook_event_name': 'PreToolUse', 'tool_name': '  ', 'tool_input': <String, dynamic>{}},
          const {'hook_event_name': 'PreToolUse', 'tool_name': 'Bash', 'tool_input': []},
          const {
            'hook_event_name': 'PreToolUse',
            'tool_name': 'Bash',
            'tool_input': <String, dynamic>{'env': []},
          },
          const {'hook_event_name': 'PreCompact', 'session_id': 42},
          const {'hook_event_name': 'PermissionDenied', 'tool_name': 'Bash', 'reason': 42},
          const {'hook_event_name': 'PostToolUse', 'tool_name': []},
        ];
        for (var index = 0; index < malformedInputs.length; index++) {
          fake.emitStdout(
            jsonEncode({
              'type': 'control_request',
              'request_id': 'malformed-$index',
              'request': {'subtype': 'hook_callback', 'input': malformedInputs[index]},
            }),
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));

        for (var index = 0; index < malformedInputs.length; index++) {
          final responses = fake.capturedStdinJson.where(
            (message) => (message['response'] as Map?)?['request_id'] == 'malformed-$index',
          );
          expect(responses, hasLength(1));
          expect(
            responses.single,
            containsPair(
              'response',
              containsPair('response', containsPair('hookSpecificOutput', containsPair('permissionDecision', 'deny'))),
            ),
          );
        }
        expect(guard.contexts, isEmpty);

        fake.emitStdout(
          jsonEncode({
            'type': 'control_request',
            'request_id': 'valid-after-malformed',
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

        expect(guard.contexts, hasLength(1));
        final validResponses = fake.capturedStdinJson.where(
          (message) => (message['response'] as Map?)?['request_id'] == 'valid-after-malformed',
        );
        expect(validResponses, hasLength(1));
        expect(
          validResponses.single,
          containsPair(
            'response',
            containsPair('response', containsPair('hookSpecificOutput', containsPair('permissionDecision', 'allow'))),
          ),
        );
      });

      test('throwing hook guard denies exactly once and the active turn can still complete', () async {
        late CapturingFakeProcess fake;
        final h = buildClaudeHarness(
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            fake = makeCapturingClaudeProcess();
            scheduleMicrotask(() {
              fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
            });
            return fake;
          },
          guardChain: GuardChain(guards: [_ThrowingGuard()]),
        );
        addTeardownAsync(() => h.dispose());
        await h.start();

        final turn = h.turn(
          sessionId: 'throwing-guard-session',
          agentId: 'search',
          messages: const [
            {'role': 'user', 'content': 'search'},
          ],
          systemPrompt: '',
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        fake.emitStdout(
          jsonEncode({
            'type': 'control_request',
            'request_id': 'throwing-guard-hook',
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

        final responses = fake.capturedStdinJson.where(
          (message) => (message['response'] as Map?)?['request_id'] == 'throwing-guard-hook',
        );
        expect(responses, hasLength(1));
        expect(
          responses.single,
          containsPair(
            'response',
            containsPair('response', containsPair('hookSpecificOutput', containsPair('permissionDecision', 'deny'))),
          ),
        );

        fake.emitStdout(jsonEncode({'type': 'result', 'result': 'done', 'is_error': false}));
        expect((await turn)['is_error'], isFalse);
        expect(h.state, WorkerState.idle);
      });
    });

    // ----- PreCompact hook + CompactBoundary ----------------------------------

    group('PreCompact hook callback', () {
      test('waits for asynchronous observation before acknowledging compaction', () async {
        final observerStarted = Completer<void>();
        final observerSettled = Completer<void>();
        final fake = makeCapturingClaudeProcess();
        final h = buildClaudeHarness(processFactory: capturingInitFactory(process: fake));
        h.onCompactionStarting = (_, _) async {
          observerStarted.complete();
          await observerSettled.future;
        };
        addTeardownAsync(() => h.dispose());

        await h.start();
        fake.emitStdout(
          jsonEncode({
            'type': 'control_request',
            'request_id': 'req-observe-before-ack',
            'request': {
              'subtype': 'hook_callback',
              'input': {'hook_event_name': 'PreCompact', 'session_id': 'provider-session', 'trigger': 'auto'},
            },
          }),
        );

        await observerStarted.future;
        expect(
          fake.capturedStdinJson.where(
            (message) => (message['response'] as Map?)?['request_id'] == 'req-observe-before-ack',
          ),
          isEmpty,
        );

        observerSettled.complete();
        await pumpEventQueue();
        expect(
          fake.capturedStdinJson.where(
            (message) => (message['response'] as Map?)?['request_id'] == 'req-observe-before-ack',
          ),
          hasLength(1),
        );
      });

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

      test('memory search SDK schema advertises the bounded integer limit', () async {
        late CapturingFakeProcess fake;
        Future<Map<String, dynamic>> memoryHandler(Map<String, dynamic> _) async => {};
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
          onMemoryApply: memoryHandler,
          onMemoryObserve: memoryHandler,
          onMemorySearch: memoryHandler,
          onMemoryRead: memoryHandler,
        );
        addTeardownAsync(() => h.dispose());

        await h.start();

        final initRequest = fake.capturedStdinJson.firstWhere(
          (message) => message['type'] == 'control_request' && (message['request'] as Map?)?['subtype'] == 'initialize',
        );
        final request = initRequest['request'] as Map<String, dynamic>;
        final servers = request['sdkMcpServers'] as Map<String, dynamic>;
        final server = servers['dartclaw'] as Map<String, dynamic>;
        final tools = server['tools'] as List<dynamic>;
        final search = tools.cast<Map<String, dynamic>>().singleWhere((tool) => tool['name'] == 'memory_search');
        final schema = search['input_schema'] as Map<String, dynamic>;
        final limit = (schema['properties'] as Map<String, dynamic>)['limit'] as Map<String, dynamic>;
        expect(limit, containsPair('type', 'integer'));
        expect(limit, containsPair('minimum', 1));
        expect(limit, containsPair('maximum', 50));
        expect(schema['additionalProperties'], isFalse);

        final observe = tools.cast<Map<String, dynamic>>().singleWhere((tool) => tool['name'] == 'memory_observe');
        final observeSchema = observe['input_schema'] as Map<String, dynamic>;
        expect(observeSchema['required'], ['text', 'role']);
        expect(observeSchema['additionalProperties'], isFalse);

        final read = tools.cast<Map<String, dynamic>>().singleWhere((tool) => tool['name'] == 'memory_read');
        final readSchema = read['input_schema'] as Map<String, dynamic>;
        expect(readSchema['oneOf'], hasLength(2));
        expect(readSchema['additionalProperties'], isFalse);

        final apply = tools.cast<Map<String, dynamic>>().singleWhere((tool) => tool['name'] == 'memory_apply');
        final applySchema = apply['input_schema'] as Map<String, dynamic>;
        expect(applySchema['additionalProperties'], isFalse);
        expect((applySchema['properties'] as Map<String, dynamic>)['operations'], containsPair('minItems', 1));
      });
    });

    // ----- SIGKILL escalation during stop --------------------------------

    group('SIGKILL escalation', () {
      test('stop() escalates to SIGKILL when process does not exit after SIGTERM', () async {
        final fake = makeKillTrackingClaudeProcess();

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
        final fake = makeKillTrackingClaudeProcess(completeExitOnKill: true);

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

      test('stop() follows injected Windows hard-termination semantics on a POSIX host', () async {
        final fake = makeKillTrackingClaudeProcess();
        final h = ClaudeCodeHarness(
          cwd: '/tmp',
          killGracePeriod: Duration.zero,
          processFactory: capturingInitFactory(process: fake),
          commandProbe: defaultClaudeCommandProbe,
          delayFactory: noOpClaudeDelay,
          environment: {'ANTHROPIC_API_KEY': 'sk-test-key'},
          platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
        );

        await h.start();
        await h.stop();

        expect(fake.killSignals, [ProcessSignal.sigterm]);
        fake.exit(0);
      });

      test('turn timeout completes promptly and drives bounded process teardown', () async {
        final fake = makeKillTrackingClaudeProcess(completeExitOnKill: true);
        final h = ClaudeCodeHarness(
          cwd: '/tmp',
          turnTimeout: Duration.zero,
          processFactory: capturingInitFactory(process: fake),
          commandProbe: defaultClaudeCommandProbe,
          delayFactory: noOpClaudeDelay,
          environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
        );
        addTeardownAsync(h.dispose);
        await h.start();

        await expectLater(
          h.turn(
            sessionId: 'timeout',
            messages: const [
              {'role': 'user', 'content': 'never completes'},
            ],
            systemPrompt: '',
          ),
          throwsA(isA<TimeoutException>()),
        );
        await pumpEventQueue();

        expect(fake.killCalled, isTrue);
        expect(h.state, WorkerState.stopped);
      });

      test('turn timeout finishes teardown before an immediate next turn restarts', () async {
        final timedOut = makeKillTrackingClaudeProcess(completeExitOnKill: true);
        final recovered = makeKillTrackingClaudeProcess(completeExitOnKill: true);
        final processes = [timedOut, recovered];
        var spawnIndex = 0;
        final h = ClaudeCodeHarness(
          cwd: '/tmp',
          turnTimeout: const Duration(milliseconds: 200),
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            final process = processes[spawnIndex++];
            scheduleMicrotask(() {
              process.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
            });
            if (identical(process, recovered)) {
              Future<void>.delayed(const Duration(milliseconds: 20), () {
                process.emitStdout(
                  jsonEncode({'type': 'result', 'result': 'ok', 'is_error': false, 'session_id': 'recovered'}),
                );
              });
            }
            return process;
          },
          commandProbe: defaultClaudeCommandProbe,
          delayFactory: noOpClaudeDelay,
          environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
        );
        addTeardownAsync(h.dispose);
        await h.start();

        await expectLater(
          h.turn(
            sessionId: 'timeout',
            messages: const [
              {'role': 'user', 'content': 'never completes'},
            ],
            systemPrompt: '',
          ),
          throwsA(isA<TimeoutException>()),
        );
        expect(h.state, WorkerState.stopped);

        final result = await h.turn(
          sessionId: 'recovered',
          messages: const [
            {'role': 'user', 'content': 'works'},
          ],
          systemPrompt: '',
        );
        expect(result['is_error'], isFalse);
        expect(h.state, WorkerState.idle);
        expect(spawnIndex, 2);
      });
    });

    // -------------------------------------------------------------------------
    // T11: Effort tolerance — null -> non-null does not restart harness
    // -------------------------------------------------------------------------

    group('T11: Effort tolerance', () {
      test('null processEffort adopts first-use non-null effort without restart', () async {
        var spawnCount = 0;

        // Harness spawned with no effort (null).
        final h = buildClaudeHarness(
          harnessConfig: const HarnessConfig(effort: null),
          processFactory: resultEmittingFactory(onSpawn: (_) => spawnCount++),
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

        final h = buildClaudeHarness(
          harnessConfig: const HarnessConfig(effort: 'low'),
          processFactory: resultEmittingFactory(onSpawn: (_) => spawnCount++),
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

      test('parameter-change restart retains an unconfirmed Windows child', () async {
        final process = makeKillTrackingClaudeProcess();
        var spawnCount = 0;
        final h = ClaudeCodeHarness(
          cwd: '/tmp',
          harnessConfig: const HarnessConfig(effort: 'low'),
          killGracePeriod: Duration.zero,
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            spawnCount++;
            scheduleMicrotask(() {
              process.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
            });
            return process;
          },
          commandProbe: defaultClaudeCommandProbe,
          delayFactory: noOpClaudeDelay,
          environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
          platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
        );
        addTeardownAsync(() async {
          process.exit(0);
          await h.dispose();
        });

        await h.start();

        await expectLater(
          h.turn(
            sessionId: 'test',
            messages: const [
              {'role': 'user', 'content': 'hello'},
            ],
            systemPrompt: '',
            effort: 'high',
          ),
          throwsA(isA<StateError>().having((error) => '$error', 'message', contains('previous process did not exit'))),
        );

        expect(spawnCount, 1);
        expect(process.killSignals, [ProcessSignal.sigterm]);
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

      test('switching logical sessions restarts and replays only the selected session', () async {
        var spawnCount = 0;
        final spawnedProcesses = <CapturingFakeProcess>[];

        Future<Process> makeProcess() async {
          spawnCount++;
          final fake = makeCapturingClaudeProcess();
          spawnedProcesses.add(fake);
          scheduleMicrotask(() {
            fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
          });
          Future.delayed(const Duration(milliseconds: 30), () {
            fake.emitStdout(
              jsonEncode({'type': 'result', 'result': 'done', 'is_error': false, 'session_id': 'provider-$spawnCount'}),
            );
          });
          return fake;
        }

        final harness = ClaudeCodeHarness(
          cwd: '/tmp',
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) =>
              makeProcess(),
          commandProbe: defaultClaudeCommandProbe,
          delayFactory: noOpClaudeDelay,
          environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
        );
        addTeardownAsync(harness.dispose);
        await harness.start();

        await harness.turn(
          sessionId: 'session-a',
          messages: const [
            {'role': 'user', 'content': 'A first'},
          ],
          systemPrompt: '',
        );
        await harness.turn(
          sessionId: 'session-b',
          messages: const [
            {'role': 'user', 'content': 'B first'},
          ],
          systemPrompt: '',
        );
        expect(spawnCount, 2, reason: 'A different logical session must not inherit the warm provider conversation');

        await harness.turn(
          sessionId: 'session-a',
          messages: const [
            {'role': 'user', 'content': 'A first'},
            {'role': 'assistant', 'content': 'A answer'},
            {'role': 'user', 'content': 'A follow-up'},
          ],
          systemPrompt: '',
        );
        expect(spawnCount, 3);

        final payload = spawnedProcesses.last.capturedStdinJson.lastWhere((entry) => entry['type'] == 'user');
        final content = payload['message']?['content'] as String? ?? '';
        expect(content, contains('[user]: A first'));
        expect(content, contains('[assistant]: A answer'));
        expect(content, contains('A follow-up'));
        expect(content, isNot(contains('B first')));
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

        final h = buildClaudeHarness(
          harnessConfig: const HarnessConfig(model: 'sonnet'),
          processFactory: resultEmittingFactory(result: const {'session_id': 's1'}),
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

final class _ThrowingGuard extends Guard {
  @override
  String get name => 'throwing-guard';

  @override
  String get category => 'test';

  @override
  Future<GuardVerdict> evaluate(GuardContext context) async {
    throw StateError('guard failed');
  }
}
