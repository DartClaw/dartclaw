import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String sessionsDir;
  late String workspaceDir;
  late SessionService sessions;
  late MessageService messages;
  late _FakeWorker worker;
  late TurnRunner runner;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_turn_runner_test_');
    sessionsDir = p.join(tempDir.path, 'sessions');
    workspaceDir = p.join(tempDir.path, 'workspace');
    Directory(sessionsDir).createSync(recursive: true);
    Directory(workspaceDir).createSync(recursive: true);

    sessions = SessionService(baseDir: sessionsDir);
    messages = MessageService(baseDir: sessionsDir);
    worker = _FakeWorker();
    runner = TurnRunner(
      harness: worker,
      messages: messages,
      behavior: BehaviorFileService(workspaceDir: workspaceDir),
      sessions: sessions,
    );
  });

  tearDown(() async {
    await messages.dispose();
    await worker.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('reserves turn and returns turnId', () async {
    final session = await sessions.getOrCreateMain();
    final turnId = await runner.reserveTurn(session.id);

    expect(turnId, isNotEmpty);
    expect(runner.isActive(session.id), isTrue);
    expect(runner.activeTurnId(session.id), turnId);
    expect(runner.activeSessionIds, contains(session.id));

    // Execute the turn to complete it properly (releaseTurn fires an error on
    // the outcome completer which propagates as an unhandled async error).
    worker.responseText = 'ok';
    runner.executeTurn(session.id, turnId, [
      {'role': 'user', 'content': 'test'},
    ]);
    await runner.waitForOutcome(session.id, turnId);
  });

  test('executes turn and produces TurnOutcome.completed', () async {
    worker.responseText = 'Hello from runner!';
    final session = await sessions.getOrCreateMain();
    await messages.insertMessage(sessionId: session.id, role: 'user', content: 'Hi');

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'Hi'},
    ]);

    final outcome = await runner.waitForOutcome(session.id, turnId);

    expect(outcome.status, TurnStatus.completed);
    expect(outcome.responseText, 'Hello from runner!');
    expect(runner.isActive(session.id), isFalse);
  });

  test('handles agent failure and produces TurnOutcome.failed', () async {
    worker.shouldFail = true;
    final session = await sessions.getOrCreateMain();

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'Will fail'},
    ]);

    final outcome = await runner.waitForOutcome(session.id, turnId);

    expect(outcome.status, TurnStatus.failed);
    expect(runner.isActive(session.id), isFalse);
  });

  test('cancels active turn', () async {
    worker.delayMs = 500;
    worker.responseText = 'Slow response';
    final session = await sessions.getOrCreateMain();

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'Cancel me'},
    ]);

    // Give the turn a moment to start.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await runner.cancelTurn(session.id);

    final outcome = await runner.waitForOutcome(session.id, turnId);
    expect(outcome.status, TurnStatus.cancelled);
  });

  test('waitForOutcome returns completed outcome', () async {
    worker.responseText = 'Done';
    final session = await sessions.getOrCreateMain();

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'Test'},
    ]);

    final outcome = await runner.waitForOutcome(session.id, turnId);
    expect(outcome.status, TurnStatus.completed);
    expect(outcome.sessionId, session.id);
    expect(outcome.turnId, turnId);
  });

  test('harness getter returns the underlying harness', () {
    expect(runner.harness, same(worker));
  });
}

class _FakeWorker implements AgentHarness {
  final _eventsCtrl = StreamController<BridgeEvent>.broadcast();

  String responseText = '';
  bool shouldFail = false;
  int delayMs = 0;

  @override
  PromptStrategy get promptStrategy => PromptStrategy.replace;

  @override
  WorkerState get state => WorkerState.idle;

  @override
  Stream<BridgeEvent> get events => _eventsCtrl.stream;

  @override
  Future<void> start() async {}

  @override
  Future<Map<String, dynamic>> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    Map<String, dynamic>? mcpServers,
    bool resume = false,
    String? directory,
    String? model,
  }) async {
    if (delayMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: delayMs));
    }
    if (shouldFail) {
      throw StateError('simulated crash');
    }
    if (responseText.isNotEmpty) {
      _eventsCtrl.add(DeltaEvent(responseText));
    }
    return <String, dynamic>{'input_tokens': 0, 'output_tokens': 0};
  }

  @override
  Future<void> cancel() async {
    // Simulate cancellation by throwing.
    shouldFail = true;
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    if (!_eventsCtrl.isClosed) await _eventsCtrl.close();
  }
}
