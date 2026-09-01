import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' show HarnessTurnContext, TurnResult;
import 'package:dartclaw_core/src/harness/claude_code_harness.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

import 'harness_test_support.dart';

void main() {
  test('zero turn timeout is unbounded', () async {
    final fake = makeKillTrackingClaudeProcess(completeExitOnKill: true);
    final harness = ClaudeCodeHarness(
      cwd: '/tmp',
      turnTimeout: Duration.zero,
      processFactory: capturingInitFactory(process: fake),
      commandProbe: defaultClaudeCommandProbe,
      delayFactory: noOpClaudeDelay,
      environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
    );
    addTearDown(harness.dispose);
    await harness.start();

    final turn = harness.turn(
      sessionId: 'unbounded',
      messages: const [
        {'role': 'user', 'content': 'completes later'},
      ],
      systemPrompt: '',
    );
    await pumpEventQueue();
    fake.emitStdout(jsonEncode({'type': 'result', 'result': 'done', 'is_error': false}));

    expect((await turn).isError, isFalse);
    expect(fake.killCalled, isFalse);
  });

  test('trusted turn context overrides the static provider backstop', () {
    fakeAsync((async) {
      final fake = makeKillTrackingClaudeProcess(completeExitOnKill: true);
      final harness = ClaudeCodeHarness(
        cwd: '/tmp',
        turnTimeout: const Duration(milliseconds: 10),
        processFactory: capturingInitFactory(process: fake),
        commandProbe: defaultClaudeCommandProbe,
        delayFactory: noOpClaudeDelay,
        environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
      );
      var started = false;
      harness.start().then((_) => started = true);
      async.flushMicrotasks();
      expect(started, isTrue);

      harness.setTurnContext(
        const HarnessTurnContext(
          sessionId: 'override',
          turnId: 'turn-1',
          source: 'workflow',
          agentName: 'main',
          turnTimeout: Duration(seconds: 1),
        ),
      );

      TurnResult? result;
      Object? error;
      harness
          .turn(
            sessionId: 'override',
            messages: const [
              {'role': 'user', 'content': 'honour the effective budget'},
            ],
            systemPrompt: '',
          )
          .then(
            (value) => result = value,
            onError: (Object value) {
              error = value;
            },
          );
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 30));
      expect(error, isNull);

      fake.emitStdout(jsonEncode({'type': 'result', 'result': 'done', 'is_error': false}));
      async.flushMicrotasks();

      expect(result?.isError, isFalse);
      expect(fake.killCalled, isFalse);

      unawaited(harness.dispose());
      async.flushMicrotasks();
    });
  });
}
