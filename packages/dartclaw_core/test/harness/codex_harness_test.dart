import 'dart:async';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/src/bridge/bridge_events.dart';
import 'package:dartclaw_core/src/harness/agent_harness.dart';
import 'package:dartclaw_core/src/harness/codex_harness.dart';
import 'package:dartclaw_core/src/harness/harness_launch_options.dart';
import 'package:dartclaw_core/src/harness/process_types.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'harness_test_support.dart';

part 'codex_provider_session_resume_cases.dart';

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

class _FailingWriteCodexProcess extends FakeCodexProcess {
  new() : super(completeExitOnKill: true);

  bool failWrites = false;

  late final IOSink _failingStdin = SwitchableFailingSink(super.stdin, () => failWrites);

  @override
  IOSink get stdin => _failingStdin;
}

CodexHarness _buildHarness({
  FakeCodexProcess? process,
  ProcessFactory? processFactory,
  CommandProbe? commandProbe,
  DelayFactory? delayFactory,
  Map<String, String>? environment,
  HarnessLaunchOptions harnessConfig = const HarnessLaunchOptions(),
  Map<String, dynamic>? providerOptions,
  GuardChain? guardChain,
  PlatformCapabilities? platformCapabilities,
  Duration killGracePeriod = Duration.zero,
  Duration initializeTimeout = const Duration(seconds: 10),
  Duration turnTimeout = const Duration(seconds: 600),
  Future<String?> Function()? prepareSubscriptionHome,
}) {
  final fake = process ?? FakeCodexProcess(completeExitOnKill: true);
  return CodexHarness(
    cwd: '/tmp',
    executable: 'codex',
    prepareSubscriptionHome: prepareSubscriptionHome,
    processFactory:
        processFactory ?? (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async => fake,
    commandProbe: commandProbe ?? defaultCommandProbe,
    delayFactory: delayFactory ?? noOpDelay,
    environment: environment ?? const {'OPENAI_API_KEY': 'sk-test-key'},
    harnessConfig: harnessConfig,
    providerOptions: providerOptions,
    guardChain: guardChain,
    platformCapabilities: platformCapabilities,
    killGracePeriod: killGracePeriod,
    initializeTimeout: initializeTimeout,
    turnTimeout: turnTimeout,
  );
}

/// Builds a harness over a fresh fake process, starts it, and registers disposal.
Future<({CodexHarness harness, FakeCodexProcess fake})> _startedHarness({
  FakeCodexProcess? process,
  HarnessLaunchOptions harnessConfig = const HarnessLaunchOptions(),
  Map<String, dynamic>? providerOptions,
  GuardChain? guardChain,
  Duration turnTimeout = const Duration(seconds: 600),
}) async {
  final fake = process ?? FakeCodexProcess(completeExitOnKill: true);
  final harness = _buildHarness(
    process: fake,
    harnessConfig: harnessConfig,
    providerOptions: providerOptions,
    guardChain: guardChain,
    turnTimeout: turnTimeout,
  );
  addTearDown(() async => harness.dispose());
  await startHarness(harness, fake);
  return (harness: harness, fake: fake);
}

/// Records every bridge event the harness emits until the test tears down.
List<BridgeEvent> _collectEvents(CodexHarness harness) {
  final events = <BridgeEvent>[];
  addTearDown(harness.events.listen(events.add).cancel);
  return events;
}

Future<void> _pumpUntilSentMessageCount(FakeCodexProcess process, String method, int count) async {
  for (var i = 0; i < 20; i++) {
    if (process.sentMessages.where((message) => message['method'] == method).length >= count) {
      return;
    }
    await pumpEventLoop();
  }
  throw StateError('Expected $count outbound $method message(s)');
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
      test('probes the configured Codex binary directly', () async {
        final calls = <({String executable, List<String> arguments})>[];
        final fake = FakeCodexProcess(completeExitOnKill: true);
        final harness = _buildHarness(
          process: fake,
          platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
          commandProbe: (executable, arguments) async {
            calls.add((executable: executable, arguments: arguments));
            return ProcessResult(0, 0, 'C:\\Program Files\\Codex\\codex.exe\r\n', '');
          },
        );
        addTearDown(() async => harness.dispose());

        await startHarness(harness, fake);
        expect(calls.single.executable, 'codex');
        expect(calls.single.arguments, ['--version']);
      });

      test('converts a thrown Codex probe failure to a structured lookup error', () async {
        final harness = _buildHarness(
          commandProbe: (_, _) async => throw ProcessException('codex', ['--version'], 'probe failed'),
        );
        addTearDown(() async => harness.dispose());

        await expectLater(
          harness.start(),
          throwsA(isA<UnsupportedCapabilityError>().having((e) => e.attemptedContext, 'context', 'codex --version')),
        );
      });

      test('does not misreport unexpected Codex probe errors as missing executable', () async {
        final harness = _buildHarness(commandProbe: (_, _) async => throw StateError('probe bug'));
        addTearDown(() async => harness.dispose());

        await expectLater(
          harness.start(),
          throwsA(isA<StateError>().having((error) => error.message, 'message', 'probe bug')),
        );
      });

      test('rejects a successful Codex probe with blank output', () async {
        final harness = _buildHarness(commandProbe: (_, _) async => ProcessResult(0, 0, ' \r\n\t', ''));
        addTearDown(() async => harness.dispose());

        await expectLater(harness.start(), throwsA(isA<UnsupportedCapabilityError>()));
      });

      test('missing Codex binary names the attempted version probe', () async {
        final harness = _buildHarness(
          platformCapabilities: PlatformCapabilities(operatingSystem: 'linux'),
          commandProbe: (_, _) async => ProcessResult(0, 1, '', 'missing'),
        );
        addTearDown(() async => harness.dispose());

        await expectLater(
          harness.start(),
          throwsA(
            isA<UnsupportedCapabilityError>().having(
              (error) => error.attemptedContext,
              'attemptedContext',
              contains('codex --version'),
            ),
          ),
        );
      });

      test('threads injected platform home policy into the Codex environment', () async {
        final harness = _buildHarness(
          platformCapabilities: PlatformCapabilities(operatingSystem: 'windows', environment: const {}),
        );
        addTearDown(() async => harness.dispose());

        await expectLater(
          harness.start(),
          throwsA(isA<UnsupportedCapabilityError>().having((e) => e.capability, 'capability', 'home directory')),
        );
      });
      test('spawns codex app-server without --yolo', () async {
        final fake = FakeCodexProcess(completeExitOnKill: true);
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
        final fake = FakeCodexProcess(completeExitOnKill: true);
        final harness = _buildHarness(process: fake);
        addTearDown(() async => harness.dispose());

        await startHarness(harness, fake);

        expect(harness.state, WorkerState.idle);
        expect(fake.sentMessages, hasLength(2));
        expect(fake.sentMessages[0]['method'], 'initialize');
        expect(fake.sentMessages[1]['method'], 'initialized');
        expect(fake.sentMessages.where((message) => message['method'] == 'thread/start'), isEmpty);
      });

      test('initialize timeout reaps the child and releases the startup lock', () async {
        final fake = FakeCodexProcess();
        final harness = _buildHarness(
          process: fake,
          initializeTimeout: Duration.zero,
          platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
        );
        addTearDown(() async => harness.dispose());

        await expectLater(harness.start(), throwsStateError);

        expect(fake.killSignals, [ProcessSignal.sigterm]);
        await expectLater(harness.start(), throwsStateError);
      });

      test('turn timeout bounds an unanswered thread start', () async {
        final (:harness, :fake) = await _startedHarness(turnTimeout: const Duration(milliseconds: 20));

        final turn = harness.turn(
          sessionId: 'unanswered-thread',
          messages: const [
            {'role': 'user', 'content': 'hello'},
          ],
          systemPrompt: '',
        );
        await waitForSentMessage(fake, 'thread/start');

        await expectLater(turn, throwsA(isA<TimeoutException>()));
        await expectLater(harness.stop(), completes);
        expect(fake.killCalled, isTrue);
      });

      test('emits SystemInitEvent when initialize response reports a context window', () async {
        final fake = FakeCodexProcess(completeExitOnKill: true);
        final harness = _buildHarness(process: fake);
        addTearDown(() async => harness.dispose());

        final events = _collectEvents(harness);

        final startFuture = harness.start();
        await waitForSentMessage(fake, 'initialize');
        fake.emitInitializeResponse(id: latestRequestId(fake, 'initialize'), contextWindow: 16384);
        await startFuture;

        expect(events.any((event) => event is SystemInitEvent), isTrue);
      });

      test('emits SystemInitEvent from v0.118.0 ClientResponse-wrapped initialize response', () async {
        final fake = FakeCodexProcess(completeExitOnKill: true);
        final harness = _buildHarness(process: fake);
        addTearDown(() async => harness.dispose());

        final events = _collectEvents(harness);

        await startHarnessV118(harness, fake);

        final initEvent = events.whereType<SystemInitEvent>().firstOrNull;
        expect(initEvent, isNotNull);
        expect(initEvent!.contextWindow, 8192);
      });

      test('v0.118.0 ClientResponse thread/start response completes turn correctly', () async {
        final fake = FakeCodexProcess(completeExitOnKill: true);
        final harness = _buildHarness(process: fake);
        addTearDown(() async => harness.dispose());

        await startHarnessV118(harness, fake);

        final turnFuture = harness.turn(
          sessionId: 'sess-1',
          systemPrompt: '',
          messages: [
            {'role': 'user', 'content': 'test'},
          ],
        );

        await respondToLatestThreadStartV118(fake, threadId: 'thread-v118');

        final turnStartMessage = fake.sentMessages.singleWhere((message) => message['method'] == 'turn/start');
        expect((turnStartMessage['params'] as Map<String, dynamic>)['threadId'], 'thread-v118');

        fake.emitTurnStarted();
        fake.emitTurnCompleted(inputTokens: 5, outputTokens: 10);

        final result = await turnFuture;
        expect(result.stopReason, 'completed');
      });

      test('spawns with isolated CODEX_HOME env and cleans it up on stop', () async {
        final fake = FakeCodexProcess(completeExitOnKill: true);
        String? capturedWorkingDirectory;
        Map<String, String>? capturedEnvironment;
        final harness = _buildHarness(
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            capturedWorkingDirectory = workingDirectory;
            capturedEnvironment = environment == null ? null : Map<String, String>.from(environment);
            return fake;
          },
          harnessConfig: const HarnessLaunchOptions(
            appendSystemPrompt: 'follow the rules',
            mcpServerUrl: 'http://127.0.0.1:3333/mcp',
            mcpGatewayToken: 'test-token',
          ),
          providerOptions: const {'use_system_codex_home': false},
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
      registerCodexProviderSessionResumeTests();

      test(
        'lazily creates a thread on first turn, streams events, auto-approves requests, and returns usage',
        () async {
          final (:harness, :fake) = await _startedHarness();

          final events = _collectEvents(harness);

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
          fake.emitItemCompleted('reasoning', 'reason-1', {'summary': 'thinking'});
          fake.emitItemStarted('command_execution', 'tool-1', {'command': 'ls -la'});
          fake.emitItemCompleted('command_execution', 'tool-1', {'aggregated_output': 'done\n', 'exit_code': 0});
          fake.emitApprovalRequest(requestId: '3', toolUseId: 'tool-1');
          fake.emitTurnCompleted(inputTokens: 12, outputTokens: 34, cachedInputTokens: 7);

          final result = await turnFuture;

          expect(harness.state, WorkerState.idle);
          expect(result.stopReason, 'completed');
          expect(result.costUsd, isNull);
          // inputTokens is normalized to fresh-only (12 raw - 7 cached = 5).
          expect(result.inputTokens, 5);
          expect(result.outputTokens, 34);
          expect(result.cacheReadTokens, 7);
          expect(events.length, 6);
          expect(events[0], isA<DeltaEvent>());
          expect(
            events[1],
            isA<ProviderProgressBridgeEvent>()
                .having((event) => event.kind, 'kind', 'codex_reasoning')
                .having((event) => event.text, 'text', 'thinking'),
          );
          expect(events[2], isA<ToolUseEvent>());
          expect(events[3], isA<ToolResultEvent>());
          expect(
            events[4],
            isA<ToolApprovalWaitEvent>()
                .having((event) => event.requestId, 'requestId', '3')
                .having((event) => event.toolName, 'toolName', 'shell'),
          );
          expect(events[5], isA<ToolApprovalResolvedEvent>().having((event) => event.requestId, 'requestId', '3'));
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

      test('does not emit approval resolved when approval response write fails', () async {
        final fake = _FailingWriteCodexProcess();
        final harness = (await _startedHarness(process: fake)).harness;
        final events = _collectEvents(harness);

        final turnFuture = harness.turn(
          sessionId: 'sess-approval-write-fails',
          messages: [
            {'role': 'user', 'content': 'write a summary'},
          ],
          systemPrompt: 'be concise',
        );

        await pumpEventLoop();
        await respondToLatestThreadStart(fake);
        fake.failWrites = true;
        fake.emitApprovalRequest(requestId: 'approval-fails', toolUseId: 'tool-1');
        fake.emitTurnCompleted(inputTokens: 1, outputTokens: 1);

        await turnFuture;

        expect(
          events,
          contains(
            isA<ToolApprovalWaitEvent>()
                .having((event) => event.requestId, 'requestId', 'approval-fails')
                .having((event) => event.toolName, 'toolName', 'shell'),
          ),
        );
        expect(
          events.whereType<ToolApprovalResolvedEvent>().map((event) => event.requestId),
          isNot(contains('approval-fails')),
        );
      });

      test('reuses the same thread for repeated turns in the same session', () async {
        final (:harness, :fake) = await _startedHarness();

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

      test('scoped instructions create and replace only the session thread', () async {
        final (:harness, :fake) = await _startedHarness(
          harnessConfig: const HarnessLaunchOptions(appendSystemPrompt: 'DEFAULT'),
        );

        final logicalAgentTurn = harness.turn(
          sessionId: 'sess-persona',
          messages: const [
            {'role': 'user', 'content': 'search'},
          ],
          systemPrompt: 'SEARCH PERSONA',
          model: 'gpt-5.6-luna',
          effort: 'medium',
        );
        await pumpEventLoop();
        await respondToLatestThreadStart(fake, threadId: 'persona-thread');
        fake.emitTurnCompleted(inputTokens: 1, outputTokens: 2);
        await logicalAgentTurn;

        final restored = harness.turn(
          sessionId: 'sess-persona',
          messages: const [
            {'role': 'user', 'content': 'ordinary'},
          ],
          systemPrompt: '',
        );
        await _pumpUntilSentMessageCount(fake, 'thread/start', 2);
        fake.emitThreadStartResponse(id: latestRequestId(fake, 'thread/start'), threadId: 'default-thread');
        await pumpEventLoop();
        fake.emitTurnCompleted(inputTokens: 3, outputTokens: 4);
        await restored;

        final threadStarts = fake.sentMessages.where((message) => message['method'] == 'thread/start').toList();
        final turnStarts = fake.sentMessages.where((message) => message['method'] == 'turn/start').toList();
        expect((threadStarts[0]['params'] as Map<String, dynamic>)['developerInstructions'], 'SEARCH PERSONA');
        expect((threadStarts[1]['params'] as Map<String, dynamic>).containsKey('developerInstructions'), isFalse);
        expect((turnStarts[0]['params'] as Map<String, dynamic>)['model'], 'gpt-5.6-luna');
        expect((turnStarts[0]['params'] as Map<String, dynamic>)['effort'], 'medium');
        expect((turnStarts[1]['params'] as Map<String, dynamic>)['threadId'], 'default-thread');
      });

      test('primary memory revision replaces only its stale thread with full developer instructions', () async {
        final (:harness, :fake) = await _startedHarness(
          harnessConfig: const HarnessLaunchOptions(appendSystemPrompt: 'SAFE STATIC CONTENT'),
        );

        Future<void> completeTurn(String sessionId, String prompt, String threadId) async {
          final expectedThreadStarts =
              fake.sentMessages.where((message) => message['method'] == 'thread/start').length + 1;
          final turn = harness.turn(
            sessionId: sessionId,
            messages: const [
              {'role': 'user', 'content': 'hello'},
            ],
            systemPrompt: prompt,
          );
          await _pumpUntilSentMessageCount(fake, 'thread/start', expectedThreadStarts);
          fake.emitThreadStartResponse(id: latestRequestId(fake, 'thread/start'), threadId: threadId);
          await pumpEventLoop();
          fake.emitTurnCompleted(inputTokens: 1, outputTokens: 1);
          await turn;
        }

        await completeTurn('primary', 'SAFE STATIC CONTENT\n\nCollection revision: 41', 'primary-41');
        await completeTurn('other', 'OTHER STATIC CONTENT', 'other-thread');
        await completeTurn('primary', 'SAFE STATIC CONTENT\n\nCollection revision: 42', 'primary-42');

        final threadStarts = fake.sentMessages.where((message) => message['method'] == 'thread/start').toList();
        final turnStarts = fake.sentMessages.where((message) => message['method'] == 'turn/start').toList();
        expect(threadStarts, hasLength(3));
        expect(
          (threadStarts[2]['params'] as Map<String, dynamic>)['developerInstructions'],
          'SAFE STATIC CONTENT\n\nCollection revision: 42',
        );
        expect(
          (threadStarts[2]['params'] as Map<String, dynamic>)['developerInstructions'],
          isNot(contains('revision: 41')),
        );
        expect((turnStarts[2]['params'] as Map<String, dynamic>)['threadId'], 'primary-42');
        expect((turnStarts[2]['params'] as Map<String, dynamic>).containsKey('system_prompt'), isFalse);
      });

      test('explicit non-primary instructions displace configured primary memory', () async {
        final (:harness, :fake) = await _startedHarness(
          harnessConfig: const HarnessLaunchOptions(
            appendSystemPrompt: 'PRIVATE MEMORY SENTINEL\n\nCollection revision: 42',
          ),
        );

        final turn = harness.turn(
          sessionId: 'restricted',
          messages: const [
            {'role': 'user', 'content': 'background work'},
          ],
          systemPrompt: 'SAFE RESTRICTED CONTENT',
        );
        await pumpEventLoop();
        await respondToLatestThreadStart(fake, threadId: 'restricted-thread');
        fake.emitTurnCompleted(inputTokens: 1, outputTokens: 1);
        await turn;

        final threadStart = fake.sentMessages.singleWhere((message) => message['method'] == 'thread/start');
        final instructions = (threadStart['params'] as Map<String, dynamic>)['developerInstructions'] as String;
        expect(instructions, 'SAFE RESTRICTED CONTENT');
        expect(instructions, isNot(contains('PRIVATE MEMORY SENTINEL')));
        expect(instructions, isNot(contains('Collection revision: 42')));
      });

      test('resetSessionContinuity starts a fresh thread for the session', () async {
        final (:harness, :fake) = await _startedHarness();

        final firstTurn = harness.turn(
          sessionId: 'sess-reset',
          messages: [
            {'role': 'user', 'content': 'first question'},
          ],
          systemPrompt: 'test',
        );
        await pumpEventLoop();
        await respondToLatestThreadStart(fake, threadId: 'thread-before-reset');
        fake.emitTurnCompleted(inputTokens: 1, outputTokens: 2);
        await firstTurn;

        await harness.resetSessionContinuity('sess-reset');

        final secondTurn = harness.turn(
          sessionId: 'sess-reset',
          messages: [
            {'role': 'user', 'content': 'after reset'},
          ],
          systemPrompt: 'test',
        );
        await _pumpUntilSentMessageCount(fake, 'thread/start', 2);
        fake.emitThreadStartResponse(id: latestRequestId(fake, 'thread/start'), threadId: 'thread-after-reset');
        await pumpEventLoop();
        fake.emitTurnCompleted(inputTokens: 3, outputTokens: 4);
        await secondTurn;

        final threadStartMessages = fake.sentMessages.where((message) => message['method'] == 'thread/start').toList();
        final turnStartMessages = fake.sentMessages.where((message) => message['method'] == 'turn/start').toList();

        expect(threadStartMessages, hasLength(2));
        expect((turnStartMessages[0]['params'] as Map<String, dynamic>)['threadId'], 'thread-before-reset');
        expect((turnStartMessages[1]['params'] as Map<String, dynamic>)['threadId'], 'thread-after-reset');
      });

      test('creates separate threads for different sessions', () async {
        final (:harness, :fake) = await _startedHarness();

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
        final (:harness, :fake) = await _startedHarness(
          providerOptions: const {'sandbox': ' workspace-write ', 'approval': ' on-request '},
        );

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

        final threadStartMessage = fake.sentMessages.singleWhere((message) => message['method'] == 'thread/start');
        final threadParams = threadStartMessage['params'] as Map<String, dynamic>;
        final turnStartMessage = fake.sentMessages.singleWhere((message) => message['method'] == 'turn/start');
        final params = turnStartMessage['params'] as Map<String, dynamic>;

        expect(threadParams['sandbox'], 'workspace-write');
        expect(threadParams['approvalPolicy'], 'on-request');
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
        expect(params['sandboxPolicy'], {'type': 'workspaceWrite'});
        expect(params['approvalPolicy'], 'on-request');

        fake.emitTurnCompleted(inputTokens: 11, outputTokens: 22, cachedInputTokens: 7);
        await turnFuture;
      });

      test('falls back to harnessConfig.model when per-turn model is null', () async {
        final (:harness, :fake) = await _startedHarness(
          harnessConfig: const HarnessLaunchOptions(model: 'gpt-5-default'),
          providerOptions: const {'sandbox': 'workspace-write', 'approval': 'on-request'},
        );

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
        expect(params['sandboxPolicy'], {'type': 'workspaceWrite'});
        expect(params['approvalPolicy'], 'on-request');

        fake.emitTurnCompleted(inputTokens: 11, outputTokens: 22, cachedInputTokens: 7);
        await turnFuture;
      });

      test('includes duration_ms and error details for turn/failed without cost fields', () async {
        final (:harness, :fake) = await _startedHarness();

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

        expect(result.isError, isTrue);
        expect(result.error, 'boom');
        expect(result.costUsd, isNull);
        // Codex reports no usage with a failure, so the error arm carries zeroes.
        expect([
          result.inputTokens,
          result.outputTokens,
          result.cacheReadTokens,
          result.cacheWriteTokens,
        ], everyElement(0));
      });

      test('failed completed turn preserves detail and does not poison the next turn', () async {
        final (:harness, :fake) = await _startedHarness();

        final failedTurn = harness.turn(
          sessionId: 'sess-auth',
          messages: [
            {'role': 'user', 'content': 'first'},
          ],
          systemPrompt: 'test',
        );
        await respondToLatestThreadStart(fake);
        fake.emitLine({
          'method': 'turn/completed',
          'params': {
            'turn': {
              'status': 'failed',
              'error': {'message': 'authentication required'},
            },
          },
        });
        expect((await failedTurn).error, 'authentication required');
        expect(harness.state, WorkerState.idle);

        final incompatibleTurn = harness.turn(
          sessionId: 'sess-auth',
          messages: [
            {'role': 'user', 'content': 'second'},
          ],
          systemPrompt: 'test',
        );
        await pumpEventLoop();
        fake.emitTurnFailed('unsupported app-server protocol version');
        expect((await incompatibleTurn).error, 'unsupported app-server protocol version');

        final nextTurn = harness.turn(
          sessionId: 'sess-auth',
          messages: [
            {'role': 'user', 'content': 'third'},
          ],
          systemPrompt: 'test',
        );
        await pumpEventLoop();
        fake.emitTurnCompleted(inputTokens: 1, outputTokens: 1);
        expect((await nextTurn).stopReason, 'completed');
      });

      test('rejects a concurrent first turn while lazy thread creation is in progress', () async {
        final (:harness, :fake) = await _startedHarness();

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
        final firstProcess = FakeCodexProcess(completeExitOnKill: true);
        final secondProcess = FakeCodexProcess(completeExitOnKill: true);
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
        final guard = _PassGuard();
        final (:harness, :fake) = await _startedHarness(guardChain: GuardChain(guards: [guard]));

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
        final fake = FakeCodexProcess(completeExitOnKill: true);
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

      test('stop() follows injected Windows hard-termination semantics on a POSIX host', () async {
        final fake = FakeCodexProcess();
        final harness = _buildHarness(
          process: fake,
          killGracePeriod: Duration.zero,
          platformCapabilities: PlatformCapabilities(
            operatingSystem: 'windows',
            environment: const {'USERPROFILE': r'C:\Users\dev'},
          ),
        );
        await startHarness(harness, fake);

        await harness.stop();

        expect(fake.killSignals, [ProcessSignal.sigterm]);
        fake.exit(0);
      });
    });

    group('compaction events', () {
      test('emits CompactionStartingBridgeEvent on contextCompaction item/started', () async {
        final (:harness, :fake) = await _startedHarness();

        final events = _collectEvents(harness);

        await pumpEventLoop();
        fake.emitItemStarted('contextCompaction', 'compact-1');
        await pumpEventLoop();

        expect(events.any((e) => e is CompactionStartingBridgeEvent), isTrue);
        expect(events.any((e) => e is CompactionCompletedBridgeEvent), isFalse);
      });

      test('emits CompactionCompletedBridgeEvent on contextCompaction item/completed', () async {
        final (:harness, :fake) = await _startedHarness();

        final events = _collectEvents(harness);

        await pumpEventLoop();
        fake.emitItemCompleted('contextCompaction', 'compact-1');
        await pumpEventLoop();

        expect(events.any((e) => e is CompactionCompletedBridgeEvent), isTrue);
        expect(events.any((e) => e is CompactionStartingBridgeEvent), isFalse);
      });

      test('emits both compaction events for a full compaction cycle', () async {
        final (:harness, :fake) = await _startedHarness();

        final events = _collectEvents(harness);

        await pumpEventLoop();
        fake.emitItemStarted('contextCompaction', 'compact-2');
        fake.emitItemCompleted('contextCompaction', 'compact-2');
        await pumpEventLoop();

        final compactionEvents = events
            .where((e) => e is CompactionStartingBridgeEvent || e is CompactionCompletedBridgeEvent)
            .toList();
        expect(compactionEvents, hasLength(2));
        expect(compactionEvents[0], isA<CompactionStartingBridgeEvent>());
        expect(compactionEvents[1], isA<CompactionCompletedBridgeEvent>());
      });

      test('thread/compactedNotification produces no bridge event', () async {
        final (:harness, :fake) = await _startedHarness();

        final events = _collectEvents(harness);

        await pumpEventLoop();
        fake.emitLine({
          'method': 'thread/compactedNotification',
          'params': {'thread_id': 'thread-1'},
        });
        await pumpEventLoop();

        expect(events.any((e) => e is CompactionStartingBridgeEvent || e is CompactionCompletedBridgeEvent), isFalse);
      });

      test('surfaces the project-trust warning once and still completes the turn', () async {
        final (:harness, :fake) = await _startedHarness();
        final events = _collectEvents(harness);

        fake.emitLine({
          'method': 'configWarning',
          'params': {
            'summary': 'Project-local config, hooks, and exec policies are disabled until the project is trusted.',
          },
        });
        final turn = harness.turn(
          sessionId: 'sess-warning',
          messages: [
            {'role': 'user', 'content': 'continue'},
          ],
          systemPrompt: 'test',
        );
        await respondToLatestThreadStart(fake);
        fake.emitTurnCompleted(inputTokens: 1, outputTokens: 1);
        await turn;

        expect(
          events.whereType<ProviderProgressBridgeEvent>().single,
          isA<ProviderProgressBridgeEvent>()
              .having((event) => event.kind, 'kind', 'provider_setup_warning')
              .having((event) => event.text, 'text', contains('Project-local config')),
        );
      });

      test('logs failed MCP startup detail and ignores status noise', () async {
        final fake = FakeCodexProcess(completeExitOnKill: true);
        final harness = _buildHarness(process: fake);
        addTearDown(() async => harness.dispose());
        final records = <LogRecord>[];
        final oldLevel = Logger.root.level;
        Logger.root.level = Level.ALL;
        final sub = Logger.root.onRecord.listen(records.add);
        addTearDown(() async {
          Logger.root.level = oldLevel;
          await sub.cancel();
        });
        await startHarness(harness, fake);

        for (final status in ['starting', 'ready']) {
          fake.emitLine({
            'method': 'mcpServer/startupStatus/updated',
            'params': {'name': 'node_repl', 'status': status, 'error': null},
          });
        }
        fake.emitLine({
          'method': 'mcpServer/startupStatus/updated',
          'params': {'name': 'node_repl', 'status': 'failed', 'error': 'initialize response closed'},
        });
        await pumpEventLoop();

        final warnings = records.where(
          (record) => record.loggerName == 'CodexHarness' && record.level == Level.WARNING,
        );
        expect(warnings, hasLength(1));
        expect(warnings.single.message, contains('node_repl'));
        expect(warnings.single.message, contains('initialize response closed'));

        final turn = harness.turn(
          sessionId: 'sess-mcp-warning',
          messages: [
            {'role': 'user', 'content': 'continue'},
          ],
          systemPrompt: 'test',
        );
        await respondToLatestThreadStart(fake);
        fake.emitTurnCompleted(inputTokens: 1, outputTokens: 1);
        expect((await turn).stopReason, 'completed');
        expect(harness.state, WorkerState.idle);
      });
    });

    group('stderr logging (TD-061)', () {
      test('logs stderr lines at WARNING level', () async {
        final fake = FakeCodexProcess(completeExitOnKill: true);
        final harness = _buildHarness(process: fake);
        addTearDown(() async => harness.dispose());

        final records = <LogRecord>[];
        final oldLevel = Logger.root.level;
        Logger.root.level = Level.ALL;
        final sub = Logger.root.onRecord.listen(records.add);
        addTearDown(() async {
          Logger.root.level = oldLevel;
          await sub.cancel();
        });

        await startHarness(harness, fake);

        fake.emitStderr("Error: model 'invalid-model' not recognised");
        await pumpEventLoop();

        expect(
          records.any(
            (r) =>
                r.loggerName == 'CodexHarness' &&
                r.level == Level.WARNING &&
                r.message.contains("model 'invalid-model' not recognised"),
          ),
          isTrue,
        );
      });
    });

    group('dedicated subscription home', () {
      test('a subscription-resolved host spawn runs against the dedicated store, not the operator login', () async {
        final root = Directory.systemTemp.createTempSync('codex-harness-dedicated-');
        addTearDown(() {
          if (root.existsSync()) root.deleteSync(recursive: true);
        });
        // The operator's own login, which no code path in a subscription spawn
        // may read, copy, or write.
        Directory(p.join(root.path, '.codex')).createSync(recursive: true);
        final operatorLogin = File(p.join(root.path, '.codex', 'auth.json'))
          ..writeAsStringSync('{"token":"OPERATOR-LOGIN"}');
        final dedicatedHome = Directory(p.join(root.path, 'credentials', 'codex'))..createSync(recursive: true);
        File(p.join(dedicatedHome.path, 'auth.json')).writeAsStringSync('{"tokens":{"access_token":"DEDICATED"}}');

        final fake = FakeCodexProcess(completeExitOnKill: true);
        Map<String, String>? capturedEnvironment;
        var gateCalls = 0;
        final harness = _buildHarness(
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            capturedEnvironment = environment == null ? null : Map<String, String>.from(environment);
            return fake;
          },
          platformCapabilities: PlatformCapabilities(environment: {'HOME': root.path}),
          // Default provider option, so the dedicated store wins over the
          // system home rather than needing use_system_codex_home: false.
          prepareSubscriptionHome: () async {
            gateCalls++;
            return dedicatedHome.path;
          },
        );
        addTearDown(() async => harness.dispose());

        await startHarness(harness, fake);

        expect(gateCalls, 1, reason: 'the freshness gate runs before the spawn');
        expect(capturedEnvironment!['CODEX_HOME'], dedicatedHome.path);
        expect(
          File(p.join(dedicatedHome.path, 'auth.json')).readAsStringSync(),
          contains('DEDICATED'),
          reason: 'the stored credential is left exactly as the vendor persisted it',
        );
        expect(operatorLogin.readAsStringSync(), '{"token":"OPERATOR-LOGIN"}');
        expect(Directory(p.join(root.path, '.codex')).listSync().map((entry) => p.basename(entry.path)), [
          'auth.json',
        ], reason: 'nothing was written under the operator login either');
      });

      test('an api-key-resolved host spawn keeps the system home behavior', () async {
        final fake = FakeCodexProcess(completeExitOnKill: true);
        Map<String, String>? capturedEnvironment;
        final harness = _buildHarness(
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            capturedEnvironment = environment == null ? null : Map<String, String>.from(environment);
            return fake;
          },
          prepareSubscriptionHome: () async => null,
        );
        addTearDown(() async => harness.dispose());

        await startHarness(harness, fake);

        expect(capturedEnvironment!.containsKey('CODEX_HOME'), isFalse);
        expect(capturedEnvironment!['OPENAI_API_KEY'], 'sk-test-key');
      });
    });
  });
}
