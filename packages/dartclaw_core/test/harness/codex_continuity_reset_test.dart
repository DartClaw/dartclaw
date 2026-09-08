import 'package:dartclaw_core/src/harness/codex_harness.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

/// One Codex process keeps a thread per session it has served, so a reset must
/// drop exactly that session's thread — including while another session's turn
/// is running, which is the only moment the runner cannot do it later.
void main() {
  group('CodexHarness.resetSessionContinuity', () {
    late FakeCodexProcess fake;
    late CodexHarness harness;

    setUp(() async {
      fake = FakeCodexProcess(completeExitOnKill: true);
      harness = CodexHarness(
        cwd: '/tmp',
        executable: 'codex',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async => fake,
        commandProbe: defaultCommandProbe,
        delayFactory: noOpDelay,
        environment: const {'OPENAI_API_KEY': 'sk-test-key'},
        killGracePeriod: Duration.zero,
      );
      addTearDown(() async => harness.dispose());
      await startHarness(harness, fake);
    });

    Future<void> Function() beginTurn(String sessionId) {
      final turn = harness.turn(
        sessionId: sessionId,
        messages: const [
          {'role': 'user', 'content': 'hello'},
        ],
        systemPrompt: 'test',
      );
      return () async {
        fake.emitTurnCompleted(inputTokens: 1, outputTokens: 1);
        await turn;
      };
    }

    Future<void> completeTurn(String sessionId, {String? newThreadId}) async {
      final finish = beginTurn(sessionId);
      if (newThreadId != null) await respondToLatestThreadStart(fake, threadId: newThreadId);
      await pumpEventLoop();
      await finish();
    }

    List<String> threadIdsPerTurn() => fake.sentMessages
        .where((message) => message['method'] == 'turn/start')
        .map((message) => (message['params'] as Map<String, dynamic>)['threadId'] as String)
        .toList();

    test('drops only the reset session thread while another session runs', () async {
      await completeTurn('A', newThreadId: 'thread-a');
      await completeTurn('B', newThreadId: 'thread-b');

      final finishA = beginTurn('A');
      await pumpEventLoop();

      await harness.resetSessionContinuity('B');
      await finishA();

      // B must negotiate a fresh thread; A keeps the one it has been resuming.
      await completeTurn('B', newThreadId: 'thread-b-after-reset');
      await completeTurn('A');

      expect(fake.sentMessages.where((message) => message['method'] == 'thread/start'), hasLength(3));
      expect(threadIdsPerTurn(), ['thread-a', 'thread-b', 'thread-a', 'thread-b-after-reset', 'thread-a']);
    });
  });
}
