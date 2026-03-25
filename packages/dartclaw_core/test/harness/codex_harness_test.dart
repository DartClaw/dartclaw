import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/src/bridge/bridge_events.dart';
import 'package:dartclaw_core/src/harness/codex_harness.dart';
import 'package:dartclaw_core/src/harness/harness_config.dart';
import 'package:dartclaw_core/src/harness/process_types.dart';
import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _PassGuard extends Guard {
  GuardContext? lastContext;

  @override
  String get name => 'pass-guard';

  @override
  String get category => 'test';

  @override
  Future<GuardVerdict> evaluate(GuardContext context) async {
    lastContext = context;
    return GuardVerdict.pass();
  }
}

CodexHarness _buildHarness({
  FakeCodexProcess? process,
  ProcessFactory? processFactory,
  CommandProbe? commandProbe,
  DelayFactory? delayFactory,
  Map<String, String>? environment,
  HarnessConfig harnessConfig = const HarnessConfig(),
  Map<String, dynamic>? providerOptions,
  GuardChain? guardChain,
  Duration killGracePeriod = Duration.zero,
}) {
  final fake = process ?? FakeCodexProcess();
  return CodexHarness(
    cwd: '/tmp',
    executable: 'codex',
    processFactory:
        processFactory ?? (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async => fake,
    commandProbe: commandProbe ?? defaultCommandProbe,
    delayFactory: delayFactory ?? noOpDelay,
    environment: environment ?? const {'OPENAI_API_KEY': 'sk-test-key'},
    harnessConfig: harnessConfig,
    providerOptions: providerOptions,
    guardChain: guardChain,
    killGracePeriod: killGracePeriod,
  );
}

void main() {
  group('CodexHarness', () {
    group('constructor defaults', () {
      test('starts in stopped state and uses append prompt strategy', () {
        final harness = CodexHarness(cwd: '/tmp');
        expect(harness.state, WorkerState.stopped);
        expect(harness.promptStrategy, PromptStrategy.append);
      });
    });

    group('start()', () {
      test('spawns codex app-server without --yolo', () async {
        final fake = FakeCodexProcess();
        late List<String> spawnedArgs;
        final harness = _buildHarness(
          process: fake,
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            spawnedArgs = List<String>.from(args);
            return fake;
          },
        );
        addTearDown(() async => harness.dispose());

        await startHarness(harness, fake);

        expect(spawnedArgs, contains('app-server'));
        expect(spawnedArgs, isNot(contains('--yolo')));
      });

      test('completes initialize handshake and does not eagerly start a thread', () async {
        final fake = FakeCodexProcess();
        final harness = _buildHarness(process: fake);
        addTearDown(() async => harness.dispose());

        await startHarness(harness, fake);

        expect(harness.state, WorkerState.idle);
        expect(fake.sentMessages, hasLength(2));
        expect(fake.sentMessages[0]['method'], 'initialize');
        expect(fake.sentMessages[1]['method'], 'initialized');
        expect(fake.sentMessages.where((message) => message['method'] == 'thread/start'), isEmpty);
      });

      test('emits SystemInitEvent when initialize response reports a context window', () async {
        final fake = FakeCodexProcess();
        final harness = _buildHarness(process: fake);
        addTearDown(() async => harness.dispose());

        final events = <BridgeEvent>[];
        final sub = harness.events.listen(events.add);
        addTearDown(() async => sub.cancel());

        final startFuture = harness.start();
        await waitForSentMessage(fake, 'initialize');
        fake.emitInitializeResponse(id: latestRequestId(fake, 'initialize'), contextWindow: 16384);
        await startFuture;

        expect(events.any((event) => event is SystemInitEvent), isTrue);
      });

      test('spawns with isolated CODEX_HOME env and cleans it up on stop', () async {
        final fake = FakeCodexProcess();
        String? capturedWorkingDirectory;
        Map<String, String>? capturedEnvironment;
        final harness = _buildHarness(
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            capturedWorkingDirectory = workingDirectory;
            capturedEnvironment = environment == null ? null : Map<String, String>.from(environment);
            return fake;
          },
          harnessConfig: const HarnessConfig(
            appendSystemPrompt: 'follow the rules',
            mcpServerUrl: 'http://127.0.0.1:3333/mcp',
            mcpGatewayToken: 'test-token',
          ),
        );
        addTearDown(() async => harness.dispose());

        await startHarness(harness, fake);

        expect(capturedWorkingDirectory, '/tmp');
        expect(capturedEnvironment, isNotNull);
        expect(capturedEnvironment!['OPENAI_API_KEY'], 'sk-test-key');
        expect(capturedEnvironment!['DARTCLAW_MCP_TOKEN'], 'test-token');

        final codexHome = capturedEnvironment!['CODEX_HOME'];
        expect(codexHome, isNotNull);
        final configFile = File(p.join(codexHome!, 'config.toml'));
        expect(configFile.existsSync(), isTrue);
        expect(configFile.readAsStringSync(), contains('follow the rules'));
        expect(configFile.readAsStringSync(), contains('[mcp_servers.dartclaw]'));

        await harness.stop();

        expect(Directory(codexHome).existsSync(), isFalse);
      });
    });

    group('turn()', () {
      test(
        'lazily creates a thread on first turn, streams events, auto-approves requests, and returns usage',
        () async {
          final fake = FakeCodexProcess();
          final harness = _buildHarness(process: fake);
          addTearDown(() async => harness.dispose());
          await startHarness(harness, fake);

          final events = <BridgeEvent>[];
          final sub = harness.events.listen(events.add);
          addTearDown(() async => sub.cancel());

          final turnFuture = harness.turn(
            sessionId: 'sess-1',
            messages: [
              {'role': 'user', 'content': 'write a summary'},
            ],
            systemPrompt: 'be concise',
          );

          await pumpEventLoop();
          expect(fake.sentMessages.where((message) => message['method'] == 'thread/start'), hasLength(1));
          expect(fake.sentMessages.where((message) => message['method'] == 'turn/start'), isEmpty);

          await respondToLatestThreadStart(fake);

          final turnStartMessage = fake.sentMessages.singleWhere((message) => message['method'] == 'turn/start');
          expect(turnStartMessage['params'], isA<Map<String, dynamic>>());
          expect((turnStartMessage['params'] as Map<String, dynamic>)['threadId'], 'thread-123');
          expect((turnStartMessage['params'] as Map<String, dynamic>).containsKey('system_prompt'), isFalse);

          fake.emitTurnStarted();
          fake.emitDelta('Hello ');
          fake.emitItemStarted('command_execution', 'tool-1', {'command': 'ls -la'});
          fake.emitItemCompleted('command_execution', 'tool-1', {'aggregated_output': 'done\n', 'exit_code': 0});
          fake.emitApprovalRequest(requestId: '3', toolUseId: 'tool-1');
          fake.emitTurnCompleted(inputTokens: 12, outputTokens: 34, cachedInputTokens: 7);

          final result = await turnFuture;

          expect(harness.state, WorkerState.idle);
          expect(result['stop_reason'], 'completed');
          expect(result.containsKey('total_cost_usd'), isFalse);
          expect(result['input_tokens'], 12);
          expect(result['output_tokens'], 34);
          expect(result['cache_read_tokens'], 7);
          expect(result['duration_ms'], isA<int>());
          expect(events.length, 3);
          expect(events[0], isA<DeltaEvent>());
          expect(events[1], isA<ToolUseEvent>());
          expect(events[2], isA<ToolResultEvent>());
          expect(
            fake.sentMessages.any(
              (message) =>
                  message['jsonrpc'] == '2.0' &&
                  message['id'] == '3' &&
                  (message['result'] as Map<String, dynamic>)['approved'] == true,
            ),
            isTrue,
          );
        },
      );

      test('reuses the same thread for repeated turns in the same session', () async {
        final fake = FakeCodexProcess();
        final harness = _buildHarness(process: fake);
        addTearDown(() async => harness.dispose());
        await startHarness(harness, fake);

        final firstTurn = harness.turn(
          sessionId: 'sess-thread',
          messages: [
            {'role': 'user', 'content': 'first question'},
          ],
          systemPrompt: 'test',
        );

        await pumpEventLoop();
        await respondToLatestThreadStart(fake);
        fake.emitTurnCompleted(inputTokens: 1, outputTokens: 2);
        await firstTurn;

        final secondTurn = harness.turn(
          sessionId: 'sess-thread',
          messages: [
            {'role': 'user', 'content': 'second question'},
          ],
          systemPrompt: 'test',
        );

        await pumpEventLoop();
        fake.emitTurnCompleted(inputTokens: 3, outputTokens: 4);
        await secondTurn;

        final threadStartMessages = fake.sentMessages.where((message) => message['method'] == 'thread/start').toList();
        final turnStartMessages = fake.sentMessages.where((message) => message['method'] == 'turn/start').toList();

        expect(threadStartMessages, hasLength(1));
        expect(turnStartMessages, hasLength(2));
        expect((turnStartMessages[0]['params'] as Map<String, dynamic>)['threadId'], 'thread-123');
        expect((turnStartMessages[1]['params'] as Map<String, dynamic>)['threadId'], 'thread-123');
      });

      test('creates separate threads for different sessions', () async {
        final fake = FakeCodexProcess();
        final harness = _buildHarness(process: fake);
        addTearDown(() async => harness.dispose());
        await startHarness(harness, fake);

        final firstTurn = harness.turn(
          sessionId: 'sess-a',
          messages: [
            {'role': 'user', 'content': 'first question'},
          ],
          systemPrompt: 'test',
        );
        await pumpEventLoop();
        await respondToLatestThreadStart(fake, threadId: 'thread-a');
        fake.emitTurnCompleted(inputTokens: 1, outputTokens: 2);
        await firstTurn;

        final secondTurn = harness.turn(
          sessionId: 'sess-b',
          messages: [
            {'role': 'user', 'content': 'second question'},
          ],
          systemPrompt: 'test',
        );
        await pumpEventLoop();
        await respondToLatestThreadStart(fake, threadId: 'thread-b');
        fake.emitTurnCompleted(inputTokens: 3, outputTokens: 4);
        await secondTurn;

        final threadStartMessages = fake.sentMessages.where((message) => message['method'] == 'thread/start').toList();
        final turnStartMessages = fake.sentMessages.where((message) => message['method'] == 'turn/start').toList();

        expect(threadStartMessages, hasLength(2));
        expect((turnStartMessages[0]['params'] as Map<String, dynamic>)['threadId'], 'thread-a');
        expect((turnStartMessages[1]['params'] as Map<String, dynamic>)['threadId'], 'thread-b');
      });

      test('derives previous_response_items from prior messages and uses provider settings', () async {
        final fake = FakeCodexProcess();
        final harness = _buildHarness(
          process: fake,
          providerOptions: const {'sandbox': 'workspace-write', 'approval': 'on-request'},
        );
        addTearDown(() async => harness.dispose());
        await startHarness(harness, fake);

        final turnFuture = harness.turn(
          sessionId: 'sess-history',
          messages: [
            {'role': 'human', 'content': 'first ask'},
            {'role': 'assistant', 'content': 'first answer'},
            {'role': 'user', 'content': 'current ask'},
          ],
          systemPrompt: 'test',
          model: 'gpt-5',
          directory: '/tmp/workspace',
        );

        await pumpEventLoop();
        await respondToLatestThreadStart(fake);

        final turnStartMessage = fake.sentMessages.singleWhere((message) => message['method'] == 'turn/start');
        final params = turnStartMessage['params'] as Map<String, dynamic>;

        expect(params['input'], [
          {'type': 'text', 'text': 'current ask'},
        ]);
        expect(params['previousResponseItems'], [
          {
            'type': 'message',
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': 'first ask'},
            ],
          },
          {
            'type': 'message',
            'role': 'assistant',
            'content': [
              {'type': 'output_text', 'text': 'first answer'},
            ],
          },
        ]);
        expect(params['model'], 'gpt-5');
        expect(params['cwd'], '/tmp/workspace');
        expect(params['sandbox'], 'workspaceWrite');
        expect(params['approvalPolicy'], 'on-request');

        fake.emitTurnCompleted(inputTokens: 11, outputTokens: 22, cachedInputTokens: 7);
        await turnFuture;
      });

      test('falls back to harnessConfig.model when per-turn model is null', () async {
        final fake = FakeCodexProcess();
        final harness = _buildHarness(
          process: fake,
          harnessConfig: const HarnessConfig(model: 'gpt-5-default'),
          providerOptions: const {'sandbox': 'workspace-write', 'approval': 'on-request'},
        );
        addTearDown(() async => harness.dispose());
        await startHarness(harness, fake);

        final turnFuture = harness.turn(
          sessionId: 'sess-default-model',
          messages: [
            {'role': 'user', 'content': 'current ask'},
          ],
          systemPrompt: 'test',
          directory: '/tmp/workspace',
        );

        await pumpEventLoop();
        await respondToLatestThreadStart(fake);

        final turnStartMessage = fake.sentMessages.singleWhere((message) => message['method'] == 'turn/start');
        final params = turnStartMessage['params'] as Map<String, dynamic>;

        expect(params['model'], 'gpt-5-default');
        expect(params['cwd'], '/tmp/workspace');
        expect(params['sandbox'], 'workspaceWrite');
        expect(params['approvalPolicy'], 'on-request');

        fake.emitTurnCompleted(inputTokens: 11, outputTokens: 22, cachedInputTokens: 7);
        await turnFuture;
      });

      test('includes duration_ms and error details for turn/failed without cost fields', () async {
        final fake = FakeCodexProcess();
        final harness = _buildHarness(process: fake);
        addTearDown(() async => harness.dispose());
        await startHarness(harness, fake);

        final resultFuture = harness.turn(
          sessionId: 'sess-failed',
          messages: [
            {'role': 'user', 'content': 'do risky thing'},
          ],
          systemPrompt: 'test',
        );

        await pumpEventLoop();
        await respondToLatestThreadStart(fake);
        fake.emitTurnFailed('boom');

        final result = await resultFuture;

        expect(result['stop_reason'], 'error');
        expect(result['error'], 'boom');
        expect(result['duration_ms'], isA<int>());
        expect(result['duration_ms'], greaterThanOrEqualTo(0));
        expect(result.containsKey('total_cost_usd'), isFalse);
      });

      test('rejects a concurrent first turn while lazy thread creation is in progress', () async {
        final fake = FakeCodexProcess();
        final harness = _buildHarness(process: fake);
        addTearDown(() async => harness.dispose());
        await startHarness(harness, fake);

        final firstTurn = harness.turn(
          sessionId: 'sess-3',
          messages: [
            {'role': 'user', 'content': 'status'},
          ],
          systemPrompt: 'test',
        );

        expect(harness.state, WorkerState.busy);
        await pumpEventLoop();
        expect(fake.sentMessages.where((message) => message['method'] == 'thread/start'), hasLength(1));
        expect(
          harness.turn(
            sessionId: 'sess-3',
            messages: [
              {'role': 'user', 'content': 'overlap'},
            ],
            systemPrompt: 'test',
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('CodexHarness is not idle (state: WorkerState.busy)'),
            ),
          ),
        );

        await respondToLatestThreadStart(fake);
        expect(harness.state, WorkerState.busy);

        fake.emitTurnCompleted(inputTokens: 1, outputTokens: 2);
        await firstTurn;
        expect(harness.state, WorkerState.idle);
      });

      test('stop clears the session thread registry before the next start', () async {
        final firstProcess = FakeCodexProcess();
        final secondProcess = FakeCodexProcess();
        final processes = <FakeCodexProcess>[firstProcess, secondProcess];
        var spawnIndex = 0;
        final harness = _buildHarness(
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            return processes[spawnIndex++];
          },
        );
        addTearDown(() async => harness.dispose());

        await startHarness(harness, firstProcess);
        final firstTurn = harness.turn(
          sessionId: 'sess-reset',
          messages: [
            {'role': 'user', 'content': 'first question'},
          ],
          systemPrompt: 'test',
        );
        await pumpEventLoop();
        await respondToLatestThreadStart(firstProcess, threadId: 'thread-first');
        firstProcess.emitTurnCompleted(inputTokens: 1, outputTokens: 2);
        await firstTurn;

        await harness.stop();

        await startHarness(harness, secondProcess);
        final secondTurn = harness.turn(
          sessionId: 'sess-reset',
          messages: [
            {'role': 'user', 'content': 'second question'},
          ],
          systemPrompt: 'test',
        );
        await pumpEventLoop();
        await respondToLatestThreadStart(secondProcess, threadId: 'thread-second');
        secondProcess.emitTurnCompleted(inputTokens: 3, outputTokens: 4);
        await secondTurn;

        expect(firstProcess.sentMessages.where((message) => message['method'] == 'thread/start'), hasLength(1));
        expect(secondProcess.sentMessages.where((message) => message['method'] == 'thread/start'), hasLength(1));

        final secondTurnStart = secondProcess.sentMessages.singleWhere((message) => message['method'] == 'turn/start');
        expect((secondTurnStart['params'] as Map<String, dynamic>)['threadId'], 'thread-second');
      });

      test('passes the turn sessionId into approval guard evaluation', () async {
        final fake = FakeCodexProcess();
        final guard = _PassGuard();
        final harness = _buildHarness(
          process: fake,
          guardChain: GuardChain(guards: [guard]),
        );
        addTearDown(() async => harness.dispose());
        await startHarness(harness, fake);

        final turnFuture = harness.turn(
          sessionId: 'sess-guard',
          messages: [
            {'role': 'user', 'content': 'list files'},
          ],
          systemPrompt: 'test',
        );

        await pumpEventLoop();
        await respondToLatestThreadStart(fake);
        fake.emitApprovalRequest(
          requestId: '4',
          toolUseId: 'tool-guard',
          toolName: 'command_execution',
          extraParams: {
            'tool_input': {'command': 'ls'},
          },
        );
        fake.emitTurnCompleted(inputTokens: 1, outputTokens: 1);
        await turnFuture;
        await Future<void>.delayed(Duration.zero);

        expect(guard.lastContext, isNotNull);
        expect(guard.lastContext!.sessionId, 'sess-guard');
        expect(guard.lastContext!.toolName, 'shell');
        expect(guard.lastContext!.rawProviderToolName, 'command_execution');
      });
    });

    group('stop/cancel/dispose', () {
      test('cancel closes stdin and sends SIGTERM', () async {
        final fake = FakeCodexProcess();
        final harness = _buildHarness(process: fake);
        addTearDown(() async => harness.dispose());
        await startHarness(harness, fake);

        await harness.cancel();
        expect(fake.stdinClosed, isTrue);
        expect(fake.lastSignal, ProcessSignal.sigterm);
      });

      test('stop transitions to stopped and kills the process', () async {
        final fake = FakeCodexProcess();
        final harness = _buildHarness(process: fake);
        addTearDown(() async => harness.dispose());
        await startHarness(harness, fake);

        await harness.stop();
        expect(harness.state, WorkerState.stopped);
        expect(fake.lastSignal, isNotNull);
      });

      test('dispose closes the events stream', () async {
        final fake = FakeCodexProcess();
        final harness = _buildHarness(process: fake);

        await startHarness(harness, fake);

        await harness.dispose();
        expect(harness.state, WorkerState.stopped);
      });
    });

    group('SIGKILL escalation', () {
      test('stop() escalates to SIGKILL when process does not exit after SIGTERM', () async {
        final fake = FakeCodexProcess();
        final harness = _buildHarness(process: fake, killGracePeriod: const Duration(milliseconds: 50));
        await startHarness(harness, fake);

        // Schedule process exit after SIGKILL would be sent.
        Timer(const Duration(milliseconds: 100), () => fake.exit(137));

        await harness.stop();

        expect(harness.state, WorkerState.stopped);
        if (!Platform.isWindows) {
          expect(fake.lastKillSignal, ProcessSignal.sigkill);
        }
      });

      test('stop() does not escalate to SIGKILL when process exits promptly on SIGTERM', () async {
        final fake = FakeCodexProcess(completeExitOnKill: true);
        final harness = _buildHarness(process: fake, killGracePeriod: const Duration(seconds: 5));
        await startHarness(harness, fake);

        await harness.stop();

        expect(harness.state, WorkerState.stopped);
        expect(fake.lastKillSignal, ProcessSignal.sigterm);
      });
    });
  });
}
