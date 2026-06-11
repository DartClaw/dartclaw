import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart' hide TurnRunner;
import 'package:dartclaw_server/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnRunner;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String workspaceDir;
  late SessionService sessions;
  late MessageService messages;
  late FakeAgentHarness worker;
  late TurnRunner runner;
  late Database turnStateDb;
  late TurnStateStore turnState;
  late KvService kvService;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_turn_runner_acp_test_');
    final sessionsDir = p.join(tempDir.path, 'sessions');
    workspaceDir = p.join(tempDir.path, 'workspace');
    Directory(sessionsDir).createSync(recursive: true);
    Directory(workspaceDir).createSync(recursive: true);

    sessions = SessionService(baseDir: sessionsDir);
    messages = MessageService(baseDir: sessionsDir);
    worker = FakeAgentHarness(supportsCostReporting: false, supportsCachedTokens: true);
    turnStateDb = sqlite3.openInMemory();
    turnState = TurnStateStore(turnStateDb);
    kvService = KvService(filePath: p.join(tempDir.path, 'kv.json'));
    runner = TurnRunner(
      harness: worker,
      messages: messages,
      behavior: BehaviorFileService(workspaceDir: workspaceDir),
      sessions: sessions,
      turnState: turnState,
      kv: kvService,
      providerId: 'acp',
    );
  });

  tearDown(() async {
    await messages.dispose();
    await worker.dispose();
    await turnState.dispose();
    await kvService.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('ACP session title and usage data land on existing session and usage surfaces', () async {
    final session = await sessions.getOrCreateMainSession();

    unawaited(() async {
      await worker.turnInvoked;
      worker.emit(DeltaEvent('visible response'));
      worker.completeSuccess({
        'stop_reason': 'end_turn',
        'input_tokens': 13,
        'output_tokens': 17,
        'cache_read_tokens': 19,
        'cache_write_tokens': 23,
        'session_title': 'Plan cleanup',
      });
    }());

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'run acp'},
    ]);
    final outcome = await runner.waitForOutcome(session.id, turnId);
    final updatedSession = await sessions.getSession(session.id);
    final costData = jsonDecode((await kvService.get('session_cost:${session.id}'))!) as Map<String, dynamic>;

    expect(outcome.status, TurnStatus.completed);
    expect(outcome.inputTokens, 13);
    expect(outcome.outputTokens, 17);
    expect(outcome.cacheReadTokens, 19);
    expect(outcome.cacheWriteTokens, 23);
    expect(updatedSession!.title, 'Plan cleanup');
    expect(costData['provider'], 'acp');
    expect(costData['input_tokens'], 13);
    expect(costData['output_tokens'], 17);
  });

  test('ACP tool_call_update reaches shared provider progress telemetry without response pollution', () async {
    final session = await sessions.getOrCreateMainSession();
    final progressEvents = <TurnProgressEvent>[];
    final sub = runner.progressEvents.listen(progressEvents.add);
    addTearDown(sub.cancel);

    unawaited(() async {
      await worker.turnInvoked;
      worker.emit(ToolUseEvent(toolName: 'Read config', toolId: 'tool-1', input: const {'title': 'Read config'}));
      worker.emit(ProviderProgressBridgeEvent(kind: 'tool_call_update', text: 'Read config'));
      worker.emit(ToolResultEvent(toolId: 'tool-1', output: 'ok', isError: false));
      worker.completeSuccess({'stop_reason': 'end_turn', 'input_tokens': 1, 'output_tokens': 1});
    }());

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'run tool'},
    ]);
    final outcome = await runner.waitForOutcome(session.id, turnId);
    final persistedMessages = await messages.getMessages(session.id);

    expect(outcome.status, TurnStatus.completed);
    expect(outcome.toolCalls, hasLength(1));
    expect(progressEvents.whereType<ProviderProgressEvent>().single.text, 'Read config');
    expect(persistedMessages.where((message) => message.role == 'assistant').single.content, isEmpty);
  });

  test('ACP stop_reason cancelled resolves to TurnStatus.cancelled', () async {
    final session = await sessions.getOrCreateMainSession();

    unawaited(() async {
      await worker.turnInvoked;
      worker.completeSuccess({'stop_reason': 'cancelled', 'input_tokens': 1, 'output_tokens': 0});
    }());

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'cancel acp'},
    ]);
    final outcome = await runner.waitForOutcome(session.id, turnId);
    final persistedMessages = await messages.getMessages(session.id);

    expect(outcome.status, TurnStatus.cancelled);
    expect(persistedMessages.where((message) => message.role == 'assistant'), isEmpty);
  });
}
