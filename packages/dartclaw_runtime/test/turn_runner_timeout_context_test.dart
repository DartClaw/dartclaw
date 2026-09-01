import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnRunner;
import 'package:dartclaw_runtime/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnRunner;
import 'package:fake_async/fake_async.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'turn_runner_test_support.dart';

class _ContextAwareHarness extends FakeAgentHarness implements HarnessTurnContextSink {
  final contexts = <HarnessTurnContext?>[];

  @override
  void setTurnContext(HarnessTurnContext? context) => contexts.add(context);
}

class _FakeTime {
  static final _initialTime = DateTime(2026);
  final _async = FakeAsync(initialTime: _initialTime);

  DateTime now() => _async.getClock(_initialTime).now();

  Timer create(Duration duration, void Function() callback) => _async.run((_) => Timer(duration, callback));

  Future<void> elapse(Duration duration) async {
    await pumpEventQueue();
    _async.elapse(duration);
    await pumpEventQueue();
  }
}

void main() {
  late Directory tempDir;
  late String workspaceDir;
  late SessionService sessions;
  late MessageService messages;
  late TurnStateStore turnState;
  late KvService kv;
  late _FakeTime time;
  late List<AgentHarness> workers;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('turn_runner_timeout_context_test_');
    final sessionsDir = p.join(tempDir.path, 'sessions');
    workspaceDir = p.join(tempDir.path, 'workspace');
    Directory(sessionsDir).createSync(recursive: true);
    Directory(workspaceDir).createSync(recursive: true);
    sessions = SessionService(baseDir: sessionsDir);
    messages = MessageService(baseDir: sessionsDir);
    turnState = TurnStateStore(sqlite3.openInMemory());
    kv = KvService(filePath: p.join(tempDir.path, 'kv.json'));
    time = _FakeTime();
    workers = [];
  });

  tearDown(() async {
    await messages.dispose();
    for (final worker in workers) {
      await worker.dispose();
    }
    await turnState.dispose();
    await kv.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  TurnRunner buildRunner(
    AgentHarness worker, {
    Duration stallTimeout = Duration.zero,
    TurnProgressAction stallAction = TurnProgressAction.warn,
    Duration turnTimeout = const Duration(minutes: 30),
  }) {
    workers.add(worker);
    return TurnRunner(
      turnLimits: TurnLimitsConfig(stallTimeout: stallTimeout, stallAction: stallAction, turnTimeout: turnTimeout),
      harness: worker,
      messages: messages,
      behavior: BehaviorFileService(workspaceDir: workspaceDir),
      sessions: sessions,
      turnState: turnState,
      kv: kv,
      turnMonitorTimerFactory: time.create,
      turnMonitorNow: time.now,
    );
  }

  test('effective provider backstop survives an override and its runner timer cannot win after return', () async {
    final worker = _ContextAwareHarness();
    final runner = buildRunner(worker);
    scheduleTurnCompletion(worker, responseText: 'journaled');
    final session = await sessions.getOrCreateMainSession();

    final turnId = await runner.startTurn(
      session.id,
      const [
        {'role': 'user', 'content': 'journal'},
      ],
      source: 'cron',
      agentName: 'cron:memory-journal',
      turnTimeout: const Duration(milliseconds: 200),
    );
    final outcome = await runner.waitForOutcome(session.id, turnId);
    await time.elapse(const Duration(milliseconds: 200));

    expect(worker.contexts, hasLength(2));
    expect(worker.contexts.first?.sessionId, session.id);
    expect(worker.contexts.first?.turnId, turnId);
    expect(worker.contexts.first?.source, 'cron');
    expect(worker.contexts.first?.agentName, 'cron:memory-journal');
    expect(worker.contexts.first?.turnTimeout, const Duration(seconds: 60, milliseconds: 200));
    expect(worker.contexts.last, isNull);
    expect(outcome.status, TurnStatus.completed);
    expect((await runner.waitForOutcome(session.id, turnId)).status, TurnStatus.completed);
  });

  test('turn timeout cancels once with wall-clock attribution', () async {
    final worker = FakeAgentHarness();
    final runner = buildRunner(worker, turnTimeout: const Duration(milliseconds: 200));
    final session = await sessions.getOrCreateMainSession();
    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'run past the wall-clock budget'},
    ]);
    await worker.turnInvoked;
    worker.emit(DeltaEvent('progress does not reset wall clock'));

    await time.elapse(const Duration(milliseconds: 200));
    final outcome = await runner.waitForOutcome(session.id, turnId).timeout(const Duration(seconds: 5));

    expect(outcome.status, TurnStatus.cancelled);
    expect(outcome.limitBreach, TurnLimitBreach.turnTimeout);
    expect(outcome.errorMessage, contains('wall-clock'));
    expect(runner.isActive(session.id), isFalse);
  });

  test('turn timeout wins when the effective wall and stall budgets are equal', () async {
    final worker = FakeAgentHarness();
    final runner = buildRunner(
      worker,
      stallTimeout: const Duration(milliseconds: 200),
      stallAction: TurnProgressAction.cancel,
      turnTimeout: const Duration(seconds: 1),
    );
    final stallEvents = <TurnStallProgressEvent>[];
    final subscription = runner.progressEvents.listen((event) {
      if (event is TurnStallProgressEvent) stallEvents.add(event);
    });
    addTearDown(subscription.cancel);
    final session = await sessions.getOrCreateMainSession();
    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'use deterministic attribution'},
    ], turnTimeout: const Duration(milliseconds: 200));
    await worker.turnInvoked;

    await time.elapse(const Duration(milliseconds: 200));
    final outcome = await runner.waitForOutcome(session.id, turnId);

    expect(outcome.limitBreach, TurnLimitBreach.turnTimeout);
    expect(stallEvents, isEmpty);
  });

  test('provider progress cannot suspend stall without an approval event', () async {
    final worker = FakeAgentHarness();
    final runner = buildRunner(
      worker,
      stallTimeout: const Duration(milliseconds: 200),
      stallAction: TurnProgressAction.cancel,
      turnTimeout: Duration.zero,
    );
    final session = await sessions.getOrCreateMainSession();
    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'do not trust provider progress as approval state'},
    ]);
    await worker.turnInvoked;
    worker.emit(ProviderProgressBridgeEvent(kind: 'approval_pending', text: 'provider-controlled progress'));

    await time.elapse(const Duration(milliseconds: 200));
    final outcome = await runner.waitForOutcome(session.id, turnId);

    expect(outcome.limitBreach, TurnLimitBreach.stall);
  });

  test('provider progress cannot resume stall while an approval remains unresolved', () async {
    final worker = FakeAgentHarness();
    final runner = buildRunner(
      worker,
      stallTimeout: const Duration(milliseconds: 200),
      stallAction: TurnProgressAction.cancel,
      turnTimeout: Duration.zero,
    );
    final session = await sessions.getOrCreateMainSession();
    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'wait for approval'},
    ]);
    await worker.turnInvoked;
    worker.emit(ToolApprovalWaitEvent(requestId: 'approval-with-progress', toolName: 'shell'));
    worker.emit(ProviderProgressBridgeEvent(kind: 'provider_turn', text: 'still waiting'));

    await time.elapse(const Duration(milliseconds: 400));
    expect(runner.isActiveTurn(session.id, turnId), isTrue);

    worker.emit(ToolApprovalResolvedEvent(requestId: 'approval-with-progress'));
    await time.elapse(const Duration(milliseconds: 200));
    final outcome = await runner.waitForOutcome(session.id, turnId);

    expect(outcome.limitBreach, TurnLimitBreach.stall);
  });
}
