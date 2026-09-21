import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/concurrency/session_mutation_coordinator.dart';
import 'package:dartclaw_runtime/src/conversation/conversation_service.dart';
import 'package:dartclaw_runtime/src/execution_coordinator.dart';
import 'package:dartclaw_runtime/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:test/test.dart';

import '../session_turn_manager_test_support.dart';
import '../turn_runner_test_support.dart';

void main() {
  test('schema title runs once and cannot overwrite manual or newer title', () async {
    final root = Directory.systemTemp.createTempSync('session_title_generation_');
    addTearDown(() => root.deleteSync(recursive: true));
    final sessions = SessionService(baseDir: root.path);
    final messages = MessageService(baseDir: root.path);
    final responses = StreamController<Completer<String>>.broadcast();
    addTearDown(responses.close);
    var requests = 0;
    final agents = LogicalAgentSessionService(
      dispatch: ({required sessionId, required message, required agentId, required createSession}) async {
        requests++;
        expect(agentId, startsWith('session-title-'));
        final response = Completer<String>();
        responses.add(response);
        return response.future;
      },
    );
    final conversation = ConversationService(
      sessions: sessions,
      messages: messages,
      turns: FakeTurnManager(messages, FakeAgentHarness()),
      mutations: SessionMutationCoordinator(),
      titleAgents: agents,
    );

    final success = await _firstExchange(sessions, messages, 'A deliberately long first user message for fallback');
    final successRun = conversation.generateTitleAfterFirstExchange(success.id);
    final successReply = await responses.stream.first;
    successReply.complete('{"title":"Focused generated title"}');
    await successRun;
    final generated = await sessions.getSession(success.id);
    expect(generated?.title, 'Focused generated title');
    expect(generated?.titleProvenance, SessionTitleProvenance.automaticGenerated);
    expect(generated?.automaticTitleAttempted, isTrue);

    final manual = await _firstExchange(sessions, messages, 'Manual title race');
    final manualRun = conversation.generateTitleAfterFirstExchange(manual.id);
    final manualReply = await responses.stream.first;
    await sessions.updateTitleWithProvenance(manual.id, 'Operator title', provenance: SessionTitleProvenance.manual);
    manualReply.complete('{"title":"Late generated title"}');
    await manualRun;
    expect((await sessions.getSession(manual.id))?.title, 'Operator title');

    final failed = await _firstExchange(sessions, messages, 'Invalid schema title');
    final failedRun = conversation.generateTitleAfterFirstExchange(failed.id);
    final failedReply = await responses.stream.first;
    failedReply.complete('{"wrong":"shape"}');
    await failedRun;
    expect((await sessions.getSession(failed.id))?.title, 'Invalid schema title');
    await conversation.generateTitleAfterFirstExchange(failed.id);
    expect(requests, 3);
  });

  test('the title agent resolves on the lane that reserves its turn', () async {
    final root = Directory.systemTemp.createTempSync('session_title_resolution_');
    addTearDown(() => root.deleteSync(recursive: true));
    final sessions = SessionService(baseDir: root.path);
    final messages = MessageService(baseDir: root.path);

    // Production wiring: the turn lane resolves a pinned agent through the same
    // service that registers the one-shot, so an agent live only for this turn
    // is still resolvable when its session reserves one.
    late final LogicalAgentSessionService agents;
    final primary = FakeTurnRunner();
    final coordinator = ExecutionCoordinator(
      providerCapacities: const {'claude': 1},
      primary: primary,
      allowPrimaryBackgroundFallback: false,
      admitExecution: (request) => primary.admitTurn(request.sessionId, isHumanInput: request.isHumanInput),
      releaseAdmission: primary.releaseAdmission,
      createWorker: (_) async => FakeTurnRunner(),
    );
    final turns = TurnManager.fromCoordinator(
      coordinator: coordinator,
      sessions: sessions,
      turnLimits: const TurnLimitsConfig.defaults(),
      agentDefinitions: (agentId) => agents.agentDefinition(agentId),
    );
    addTearDown(coordinator.dispose);

    final reservedAgentIds = <String>[];
    agents = LogicalAgentSessionService(
      dispatch: ({required sessionId, required message, required agentId, required createSession}) async {
        final session = await sessions.getOrCreateByKey(sessionId, type: SessionType.logicalAgent, provider: 'claude');
        final turnId = await turns.reserveTurn(session.id, agentName: agentId);
        reservedAgentIds.add(agentId);
        final outcome = turns.waitForOutcome(session.id, turnId);
        turns.releaseTurn(session.id, turnId);
        await expectLater(outcome, throwsStateError);
        return '{"title":"Resolved through the live registry"}';
      },
    );

    final conversation = ConversationService(
      sessions: sessions,
      messages: messages,
      turns: FakeTurnManager(messages, FakeAgentHarness()),
      mutations: SessionMutationCoordinator(),
      titleAgents: agents,
    );

    final session = await _firstExchange(sessions, messages, 'Untitled first exchange');
    await conversation.generateTitleAfterFirstExchange(session.id);

    expect((await sessions.getSession(session.id))?.title, 'Resolved through the live registry');
    expect(reservedAgentIds.single, 'session-title-${session.id}');

    // Widening resolution to the live registry does not retire the guard: a
    // session pinned to an agent nobody holds still refuses to reserve a turn.
    final orphan = await sessions.getOrCreateByKey(
      SessionKey.logicalAgentSession(agentId: 'retired-agent', conversationId: 'orphan'),
      type: SessionType.logicalAgent,
      provider: 'claude',
    );
    await expectLater(
      turns.reserveTurn(orphan.id, agentName: 'retired-agent'),
      throwsA(isA<StateError>().having((error) => error.message, 'message', contains('unknown agent'))),
    );
  });
}

Future<Session> _firstExchange(SessionService sessions, MessageService messages, String userText) async {
  final session = await sessions.createSession();
  await sessions.setAutomaticTitleFallback(session.id, userText);
  await messages.insertMessage(sessionId: session.id, role: 'user', content: userText);
  await messages.insertMessage(sessionId: session.id, role: 'assistant', content: 'First answer');
  return session;
}
