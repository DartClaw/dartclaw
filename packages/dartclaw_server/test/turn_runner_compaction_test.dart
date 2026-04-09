import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _CompactionCapabilityHarness extends FakeAgentHarness {
  final bool _supportsPreCompactHook;

  _CompactionCapabilityHarness({required bool supportsPreCompactHook})
    : _supportsPreCompactHook = supportsPreCompactHook;

  @override
  bool get supportsPreCompactHook => _supportsPreCompactHook;
}

TurnRunner _buildRunner({
  required AgentHarness harness,
  required MessageService messages,
  required SessionService sessions,
  required String workspaceDir,
  ContextMonitor? contextMonitor,
  EventBus? eventBus,
  String providerId = 'claude',
}) {
  return TurnRunner(
    harness: harness,
    messages: messages,
    sessions: sessions,
    behavior: BehaviorFileService(workspaceDir: workspaceDir),
    contextMonitor: contextMonitor,
    eventBus: eventBus,
    providerId: providerId,
  );
}

Map<String, dynamic> _turnResult({int inputTokens = 0, int outputTokens = 0}) => <String, dynamic>{
  'input_tokens': inputTokens,
  'output_tokens': outputTokens,
};

void main() {
  late Directory tempDir;
  late String sessionsDir;
  late String workspaceDir;
  late SessionService sessions;
  late MessageService messages;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_turn_runner_compaction_test_');
    sessionsDir = p.join(tempDir.path, 'sessions');
    workspaceDir = p.join(tempDir.path, 'workspace');
    Directory(sessionsDir).createSync(recursive: true);
    Directory(workspaceDir).createSync(recursive: true);
    sessions = SessionService(baseDir: sessionsDir);
    messages = MessageService(baseDir: sessionsDir);
  });

  tearDown(() async {
    await messages.dispose();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('promotes Codex compaction bridge events onto the EventBus', () async {
    final worker = FakeAgentHarness();
    addTearDown(worker.dispose);
    final eventBus = EventBus();
    addTearDown(eventBus.dispose);
    final runner = _buildRunner(
      harness: worker,
      messages: messages,
      sessions: sessions,
      workspaceDir: workspaceDir,
      eventBus: eventBus,
      providerId: 'codex',
    );

    final startingEvents = <CompactionStartingEvent>[];
    final completedEvents = <CompactionCompletedEvent>[];
    final startingSub = eventBus.on<CompactionStartingEvent>().listen(startingEvents.add);
    final completedSub = eventBus.on<CompactionCompletedEvent>().listen(completedEvents.add);
    addTearDown(startingSub.cancel);
    addTearDown(completedSub.cancel);

    unawaited(() async {
      await worker.turnInvoked;
      worker.emit(CompactionStartingBridgeEvent());
      worker.emit(CompactionCompletedBridgeEvent());
      worker.completeSuccess(_turnResult());
    }());

    final session = await sessions.getOrCreateMain();
    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'compact me'},
    ]);
    await runner.waitForOutcome(session.id, turnId);

    expect(startingEvents, hasLength(1));
    expect(startingEvents.single.sessionId, equals(session.id));
    expect(startingEvents.single.trigger, equals('auto'));
    expect(completedEvents, hasLength(1));
    expect(completedEvents.single.sessionId, equals(session.id));
    expect(completedEvents.single.trigger, equals('auto'));
    expect(completedEvents.single.preTokens, isNull);
  });

  test('flush heuristic uses the current harness capability instead of shared monitor state', () async {
    final worker = _CompactionCapabilityHarness(supportsPreCompactHook: false);
    addTearDown(worker.dispose);
    final contextMonitor = ContextMonitor(reserveTokens: 20000)..compactionSignalAvailable = true;
    final runner = _buildRunner(
      harness: worker,
      messages: messages,
      sessions: sessions,
      workspaceDir: workspaceDir,
      contextMonitor: contextMonitor,
      providerId: 'codex',
    );

    unawaited(() async {
      await worker.turnInvoked;
      worker.emit(SystemInitEvent(contextWindow: 200000));
      worker.completeSuccess(_turnResult(inputTokens: 190001, outputTokens: 1));
      await worker.turnInvoked.timeout(const Duration(seconds: 5));
      worker.completeSuccess(_turnResult());
    }());

    final session = await sessions.getOrCreateMain();
    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'needs flush'},
    ]);
    await runner.waitForOutcome(session.id, turnId);

    expect(worker.turnCallCount, equals(2));
  });

  test('Claude runners suppress heuristic flush even when shared monitor default is false', () async {
    final worker = _CompactionCapabilityHarness(supportsPreCompactHook: true);
    addTearDown(worker.dispose);
    final contextMonitor = ContextMonitor(reserveTokens: 20000)..compactionSignalAvailable = false;
    final runner = _buildRunner(
      harness: worker,
      messages: messages,
      sessions: sessions,
      workspaceDir: workspaceDir,
      contextMonitor: contextMonitor,
    );

    unawaited(() async {
      await worker.turnInvoked;
      worker.emit(SystemInitEvent(contextWindow: 200000));
      worker.completeSuccess(_turnResult(inputTokens: 190001, outputTokens: 1));
    }());

    final session = await sessions.getOrCreateMain();
    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'claude compaction hook'},
    ]);
    await runner.waitForOutcome(session.id, turnId);

    expect(worker.turnCallCount, equals(1));
  });
}
