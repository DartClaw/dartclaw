import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/src/harness/agent_harness.dart' show TurnResult;
import 'package:dartclaw_core/src/harness/claude_code_harness.dart';
import 'package:dartclaw_core/src/worker/worker_state.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show CapturingFakeProcess;
import 'package:test/test.dart';

import 'harness_test_support.dart';

const _resultPayload = {
  'type': 'result',
  'result': 'ok',
  'cost_usd': 0.001,
  'duration_ms': 10,
  'duration_api_ms': 5,
  'num_turns': 1,
  'is_error': false,
  'session_id': 'provider-session',
};

/// One Claude process holds one conversation, so a reset for a session it does
/// not carry must leave it alone — busy or idle — while a reset for the session
/// it does carry either refuses (busy) or drops the process (idle).
void main() {
  group('ClaudeCodeHarness.resetSessionContinuity', () {
    late List<CapturingFakeProcess> processes;
    late ClaudeCodeHarness harness;

    setUp(() {
      processes = [];
      harness = buildClaudeHarness(
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          final fake = makeCapturingClaudeProcess();
          processes.add(fake);
          scheduleMicrotask(() {
            fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
          });
          return fake;
        },
      );
      addTearDown(() => harness.dispose());
    });

    Future<TurnResult> beginTurn(String sessionId) => harness.turn(
      sessionId: sessionId,
      messages: [
        {'role': 'user', 'content': 'hello'},
      ],
      systemPrompt: '',
    );

    Future<void> pumpUntilBusy() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(harness.state, WorkerState.busy);
    }

    Future<void> finishTurn(Future<TurnResult> turnFuture) async {
      processes.last.emitStdout(jsonEncode(_resultPayload));
      await turnFuture;
    }

    Future<void> runTurn(String sessionId) async {
      final turnFuture = beginTurn(sessionId);
      await pumpUntilBusy();
      await finishTurn(turnFuture);
    }

    test('leaves the process alone for another session while a turn is in flight', () async {
      await harness.start();
      final turnFuture = beginTurn('A');
      await pumpUntilBusy();

      await harness.resetSessionContinuity('B');

      expect(harness.state, WorkerState.busy);
      expect(processes, hasLength(1));
      expect(processes.single.killCalled, isFalse);

      await finishTurn(turnFuture);
      expect(harness.state, WorkerState.idle);
    });

    test('refuses for the session whose turn is in flight', () async {
      await harness.start();
      final turnFuture = beginTurn('A');
      await pumpUntilBusy();

      await expectLater(harness.resetSessionContinuity('A'), throwsA(isA<StateError>()));

      expect(processes.single.killCalled, isFalse);
      await finishTurn(turnFuture);
    });

    test('leaves an idle process alone for a session it does not carry', () async {
      await harness.start();
      await runTurn('A');

      await harness.resetSessionContinuity('B');

      expect(harness.state, WorkerState.idle);
      expect(processes, hasLength(1));
      expect(processes.single.killCalled, isFalse);
    });

    test('stops an idle process carrying the session being reset', () async {
      await harness.start();
      await runTurn('A');

      await harness.resetSessionContinuity('A');

      expect(harness.state, WorkerState.stopped);
      expect(processes.single.killCalled, isTrue);

      // The binding is cleared along with the stop, so a repeat reset for the
      // same session finds nothing bound and is a no-op rather than a second
      // stop/kill on an already-stopped process.
      await harness.resetSessionContinuity('A');

      expect(processes, hasLength(1));
      expect(harness.state, WorkerState.stopped);
    });
  });
}
