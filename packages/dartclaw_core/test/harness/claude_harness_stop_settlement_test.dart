import 'dart:async';

import 'package:dartclaw_core/src/harness/claude_code_harness.dart';
import 'package:dartclaw_core/src/worker/worker_state.dart';
import 'package:test/test.dart';

import 'harness_test_support.dart';

/// `stop()` is the only thing that ends a turn the provider will not end
/// itself, and an operator cancel restarts the worker through it. A turn left
/// awaiting a completer nothing settles holds the caller's session lock and
/// worker lease for the life of the process, so the session accepts no further
/// work; that is the wedge these cases pin.
void main() {
  ClaudeCodeHarness buildUnboundedHarness() => ClaudeCodeHarness(
    cwd: '/tmp',
    turnTimeout: Duration.zero,
    processFactory: capturingInitFactory(),
    commandProbe: defaultClaudeCommandProbe,
    delayFactory: noOpClaudeDelay,
    killGracePeriod: Duration.zero,
    environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
  );

  Future<bool Function()> startUnboundedTurn(ClaudeCodeHarness harness) async {
    var settled = false;
    unawaited(
      harness
          .turn(
            sessionId: 'wedged',
            messages: const [
              {'role': 'user', 'content': 'run a slow shell command'},
            ],
            systemPrompt: '',
          )
          .then((_) => settled = true, onError: (Object _) => settled = true),
    );
    await pumpEventQueue();
    expect(harness.state, WorkerState.busy);
    return () => settled;
  }

  test('stop() settles an unbounded turn the provider never finished', () async {
    final harness = buildUnboundedHarness();
    addTearDown(harness.dispose);
    await harness.start();
    final settled = await startUnboundedTurn(harness);

    await harness.stop();
    await pumpEventQueue();

    expect(settled(), isTrue, reason: 'stop() left the in-flight turn awaiting a completer nothing settles');
  });

  test('operator cancel restart frees the worker for the next turn', () async {
    final harness = buildUnboundedHarness();
    addTearDown(harness.dispose);
    await harness.start();
    final settled = await startUnboundedTurn(harness);

    // The accepted-cancel recovery sequence TurnRunner drives.
    await harness.cancel();
    await harness.stop();
    await harness.start();
    await pumpEventQueue();

    expect(settled(), isTrue, reason: 'the cancelled turn never settled, so its worker lease is never released');
    expect(harness.state, WorkerState.idle);
  });
}
