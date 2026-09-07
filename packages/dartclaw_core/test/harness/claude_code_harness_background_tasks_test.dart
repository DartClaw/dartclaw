import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/src/bridge/bridge_events.dart';
import 'package:dartclaw_core/src/harness/agent_harness.dart';
import 'package:dartclaw_core/src/harness/claude_code_harness.dart';
import 'package:dartclaw_core/src/harness/process_types.dart';
import 'package:dartclaw_core/src/worker/worker_state.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeProcess;
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'harness_test_support.dart';

// Claude Code 2.1.263 ends the model's turn with a `result` while a
// backgrounded subagent is still running, then runs a notification turn of its
// own that ends in a second `result`. A turn completed at the first one lets
// the caller's next turn restart the process, which kills the subagent.

Map<String, dynamic> _tasksChanged(List<({String id, String type})> tasks) => {
  'type': 'system',
  'subtype': 'background_tasks_changed',
  'tasks': [
    for (final task in tasks) {'task_id': task.id, 'task_type': task.type, 'description': task.id},
  ],
};

Map<String, dynamic> _result(
  String text, {
  int input = 0,
  int output = 0,
  int cacheRead = 0,
  int cacheWrite = 0,
  bool isError = false,
}) => {
  'type': 'result',
  'subtype': isError ? 'error' : 'success',
  'is_error': isError,
  'stop_reason': 'end_turn',
  'result': text,
  'total_cost_usd': 0.01,
  'usage': {
    'input_tokens': input,
    'output_tokens': output,
    'cache_read_input_tokens': cacheRead,
    'cache_creation_input_tokens': cacheWrite,
  },
  'session_id': 'sess',
};

void main() {
  late List<FakeProcess> spawned;
  late List<BridgeEvent> events;
  late List<LogRecord> logs;

  ProcessFactory spawningFactory({bool completeExitOnKill = false}) =>
      (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
        final fake = makeKillTrackingClaudeProcess(completeExitOnKill: completeExitOnKill);
        spawned.add(fake);
        scheduleMicrotask(() => fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}})));
        return fake;
      };

  ClaudeCodeHarness harnessWith({Duration? turnTimeout}) {
    final h = turnTimeout == null
        ? buildClaudeHarness(processFactory: spawningFactory())
        : ClaudeCodeHarness(
            cwd: '/tmp',
            turnTimeout: turnTimeout,
            processFactory: spawningFactory(completeExitOnKill: true),
            commandProbe: defaultClaudeCommandProbe,
            delayFactory: noOpClaudeDelay,
            environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
          );
    addTearDown(h.dispose);
    final sub = h.events.listen(events.add);
    addTearDown(sub.cancel);
    return h;
  }

  Future<TurnResult> startTurn(ClaudeCodeHarness h, {String sessionId = 's'}) => h.turn(
    sessionId: sessionId,
    messages: const [
      {'role': 'user', 'content': 'go'},
    ],
    systemPrompt: '',
  );

  void emit(Map<String, dynamic> line, {int process = 0}) => spawned[process].emitStdout(jsonEncode(line));

  Iterable<String> heldLogs() => logs.map((r) => r.message).where((m) => m.startsWith('Turn boundary held'));

  setUp(() {
    spawned = [];
    events = [];
    logs = [];
    final sub = Logger('ClaudeCodeHarness').onRecord.listen(logs.add);
    addTearDown(sub.cancel);
  });

  test(
    'holds the turn while background agents are listed and completes on the result that follows their end',
    () async {
      final h = harnessWith();
      await h.start();
      final turn = startTurn(h);
      var settled = false;
      unawaited(turn.whenComplete(() => settled = true));
      await pumpEventQueue();

      emit(_tasksChanged([(id: 'agent-a', type: 'local_agent'), (id: 'agent-b', type: 'local_agent')]));
      emit(_result('LAUNCHED', input: 10, output: 20, cacheRead: 30, cacheWrite: 40));
      await pumpEventQueue();
      expect(settled, isFalse);
      expect(h.state, WorkerState.busy);
      expect(
        events.whereType<ProviderProgressBridgeEvent>().map((e) => e.kind),
        contains('background_tasks'),
        reason: 'the hold is reported as provider progress so the runner sees activity, not a stall',
      );

      // The first agent reports; the CLI's notification turn ends while the
      // second is still running, so the boundary is held again.
      emit(_tasksChanged([(id: 'agent-b', type: 'local_agent')]));
      emit(_result('agent-a done', input: 100, output: 200, cacheRead: 300, cacheWrite: 400));
      await pumpEventQueue();
      expect(settled, isFalse);
      expect(heldLogs(), hasLength(2));
      expect(heldLogs().first, contains('2 background task(s) still running (agent-a, agent-b)'));

      emit(_tasksChanged(const []));
      emit(_result('all done', input: 1, output: 2, cacheRead: 3, cacheWrite: 4));
      final result = await turn;
      expect(result.finalText, 'all done');
      expect(result.isError, isFalse);
      expect(result.inputTokens, 111, reason: 'held results are charged to the turn that finally completes');
      expect(result.outputTokens, 222);
      expect(result.cacheReadTokens, 333);
      expect(result.cacheWriteTokens, 444);
      expect(h.state, WorkerState.idle);
      expect(logs.map((r) => r.message), contains(contains('after 2 held result(s)')));
    },
  );

  test('a backgrounded shell command does not hold the turn', () async {
    final h = harnessWith();
    await h.start();
    final turn = startTurn(h);
    await pumpEventQueue();

    emit(_tasksChanged([(id: 'bash-1', type: 'local_bash')]));
    emit(_result('LAUNCHED', input: 10, output: 20));
    final result = await turn;
    expect(result.finalText, 'LAUNCHED');
    expect(result.inputTokens, 10);
    expect(heldLogs(), isEmpty);
  });

  test('an error result ends the turn even with background agents listed', () async {
    final h = harnessWith();
    await h.start();
    final turn = startTurn(h);
    await pumpEventQueue();

    emit(_tasksChanged([(id: 'agent-a', type: 'local_agent')]));
    emit(_result('rate limited', isError: true));
    final result = await turn;
    expect(result.isError, isTrue);
    expect(heldLogs(), isEmpty);
  });

  test('the hold is bounded by the turn timeout, which tears the process down', () async {
    final h = harnessWith(turnTimeout: const Duration(milliseconds: 100));
    await h.start();
    final turn = startTurn(h);
    await pumpEventQueue();

    emit(_tasksChanged([(id: 'agent-a', type: 'local_agent')]));
    emit(_result('LAUNCHED'));
    await expectLater(turn, throwsA(isA<TimeoutException>()));
    await pumpEventQueue();
    expect(heldLogs(), hasLength(1));
    expect(spawned.single.killCalled, isTrue);
    expect(h.state, WorkerState.stopped);
  });

  test('a new process starts with no background tasks, so a held inventory never outlives its process', () async {
    final h = harnessWith();
    await h.start();
    final crashed = startTurn(h);
    await pumpEventQueue();
    emit(_tasksChanged([(id: 'agent-a', type: 'local_agent')]));
    spawned[0].exit(1);
    await expectLater(crashed, throwsA(isA<StateError>()));
    expect(h.state, WorkerState.crashed);

    final recovered = startTurn(h);
    await pumpEventQueue();
    expect(spawned, hasLength(2));
    emit(_result('fresh'), process: 1);
    final result = await recovered;
    expect(result.finalText, 'fresh');
    expect(heldLogs(), isEmpty);
  });
}
