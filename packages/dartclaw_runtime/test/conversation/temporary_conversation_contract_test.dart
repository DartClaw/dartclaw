import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide FakeTurnManager, TurnManager, TurnRunner;
import 'package:test/test.dart';

import '../api/api_test_helpers.dart';
import '../session_turn_manager_test_support.dart';
import '../test_utils.dart';

void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(resetTemplates);

  test('temporary and ordinary conversations share authorities with distinct retention', () async {
    final root = Directory.systemTemp.createTempSync('temporary-authority-');
    addTearDown(() => root.deleteSync(recursive: true));
    final sessions = SessionService(baseDir: root.path);
    final messages = MessageService(baseDir: root.path, retentionForSession: sessions.retentionFor);
    final durable = await sessions.createSession();
    final temporary = await sessions.createSession(retention: ConversationRetention.process);
    await messages.insertMessage(sessionId: durable.id, role: 'user', content: 'durable');
    await messages.insertMessage(sessionId: temporary.id, role: 'user', content: 'process');
    expect(await sessions.retentionFor(durable.id), ConversationRetention.durable);
    expect(await sessions.retentionFor(temporary.id), ConversationRetention.process);
    expect(File('${root.path}/${durable.id}/messages.ndjson').existsSync(), isTrue);
    expect(Directory('${root.path}/${temporary.id}').existsSync(), isFalse);
  });

  test('temporary execution reuses only its session authority and explicit release stops it', () async {
    final root = Directory.systemTemp.createTempSync('temporary-worker-');
    addTearDown(() => root.deleteSync(recursive: true));
    final messages = MessageService(baseDir: root.path);
    final behavior = BehaviorFileService(workspaceDir: root.path);
    final harnesses = <FakeAgentHarness>[];
    final runners = <TurnRunner>[];
    final coordinator = ExecutionCoordinator(
      providerCapacities: const {'codex': 2},
      admitExecution: (_) async {},
      releaseAdmission: (_) {},
      createWorker: (_) async {
        final harness = FakeAgentHarness();
        harnesses.add(harness);
        final runner = TurnRunner(
          turnLimits: const TurnLimitsConfig.defaults(),
          harness: harness,
          messages: messages,
          behavior: behavior,
          providerId: 'codex',
          executionPolicy: ExecutionPolicy.container('workspace'),
        );
        runners.add(runner);
        return runner;
      },
    );
    addTearDown(coordinator.dispose);
    ExecutionRequest request(String id) => ExecutionRequest(
      surface: ExecutionSurface.temporary,
      providerId: 'codex',
      policy: ExecutionPolicy.container('workspace'),
      sessionId: id,
      retention: ConversationRetention.process,
    );
    final first = await coordinator.acquire(request('11111111-1111-4111-8111-111111111111'));
    expect(first, isNotNull);
    await first!.release();
    final second = await coordinator.acquire(request('11111111-1111-4111-8111-111111111111'));
    expect(second!.runner, same(runners.single));
    await second.release();
    final other = await coordinator.acquire(request('22222222-2222-4222-8222-222222222222'));
    expect(other!.runner, isNot(same(runners.first)));
    await other.release();
    await coordinator.releaseTemporarySession('11111111-1111-4111-8111-111111111111');
    expect(harnesses.first.state, WorkerState.stopped);
    expect(coordinator.snapshot.cachedWorkers, 1);
  });

  test('end waits for confirmed termination and cleanup before revoking the conversation', () async {
    final root = Directory.systemTemp.createTempSync('temporary-end-');
    addTearDown(() => root.deleteSync(recursive: true));
    final sessions = SessionService(baseDir: root.path);
    final messages = MessageService(baseDir: root.path, retentionForSession: sessions.retentionFor);
    final worker = FakeAgentHarness();
    final allowCompletion = Completer<void>();
    final waitStarted = Completer<void>();
    final turns = _PausingCompletionTurnManager(messages, worker, waitStarted, allowCompletion);
    final handler = localAdminMiddleware()(
      sessionRoutes(sessions, messages, turns, worker, ownerWorkspaceDir: sessions.baseDir).call,
    );
    final session = await sessions.createSession(retention: ConversationRetention.process);
    await messages.insertMessage(sessionId: session.id, role: 'user', content: 'held');
    final response = handler(apiRequest('POST', '/api/sessions/${session.id}/end-temporary'));
    await waitStarted.future;
    expect(sessions.temporaryEndState(session.id), 'ending');
    expect(await sessions.getSession(session.id), isNotNull);
    expect((await messages.getMessages(session.id)).single.content, 'held');
    allowCompletion.complete();
    expect((await response).statusCode, 204);
    expect(await sessions.getSession(session.id), isNull);
  });
}

final class _PausingCompletionTurnManager extends FakeTurnManager {
  new(super.messages, super.worker, this.started, this.resume);

  final Completer<void> started;
  final Completer<void> resume;

  @override
  Future<void> waitForCompletion(String sessionId, {Duration timeout = const Duration(seconds: 10)}) async {
    started.complete();
    await resume.future;
  }
}
