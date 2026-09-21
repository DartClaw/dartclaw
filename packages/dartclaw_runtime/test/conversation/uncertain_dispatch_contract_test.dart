import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_runtime/src/concurrency/session_mutation_coordinator.dart';
import 'package:dartclaw_runtime/src/conversation/conversation_service.dart';
import 'package:dartclaw_runtime/src/turn_wait_status.dart' show TurnCancelException;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:test/test.dart';

import '../session_turn_manager_test_support.dart';

/// A claim whose dispatch outcome was never observed is `uncertain`, and
/// nothing ever resolves it: it is not retried, and the turn that would have
/// settled it died with the process that owned it. Gating admission or release
/// on that marker therefore parked the session for good, which is what these
/// cases pin. Live work is gated by `dispatching`/`running`/`stopping` and by
/// the turn manager, never by the marker.
void main() {
  late Directory temporaryDirectory;
  late SessionService sessions;
  late MessageService messages;
  late String sessionId;
  var clockTick = 0;

  ConversationService buildService(FakeTurnManager turns) => ConversationService(
    sessions: sessions,
    messages: messages,
    turns: turns,
    mutations: SessionMutationCoordinator(),
    clock: () => DateTime.utc(2026, 9, 21).add(Duration(milliseconds: clockTick++)),
  );

  /// Dispatches a turn that never settles, then abandons its service and turn
  /// manager, as a process that died mid-turn would.
  Future<void> strandADispatch({bool withQueuedItem = false}) async {
    final live = buildService(_turnManager(messages));
    await _submit(live, sessionId, 'stranded', 'The turn that did not survive');
    if (withQueuedItem) await _submit(live, sessionId, 'waiting', 'Queued behind it');
  }

  setUp(() async {
    temporaryDirectory = Directory.systemTemp.createTempSync('dartclaw_uncertain_dispatch_');
    sessions = SessionService(baseDir: temporaryDirectory.path);
    messages = MessageService(baseDir: temporaryDirectory.path);
    sessionId = (await sessions.createSession()).id;
  });

  tearDown(() {
    if (temporaryDirectory.existsSync()) temporaryDirectory.deleteSync(recursive: true);
  });

  test('a restarted server dispatches the next send past an uncertain claim', () async {
    await strandADispatch();
    final turns = _turnManager(messages);
    final restarted = buildService(turns);
    final recovered = await restarted.snapshot(sessionId);
    expect(
      recovered.findSubmission('stranded')?.workState,
      ConversationWorkState.uncertain,
      reason: 'the restart must still record that the dispatch was never confirmed',
    );

    final next = await _submit(restarted, sessionId, 'after-restart', 'Send again after the restart');

    expect(next.submission.workState, ConversationWorkState.running);
    expect(turns.executeCallCount, 1, reason: 'the send must reach the turn manager, not the queue');
    final settled = await restarted.snapshot(sessionId);
    expect(
      settled.findSubmission('stranded')?.workState,
      ConversationWorkState.failed,
      reason: 'acting on the session retires the restart-recovery notice',
    );
    expect(settled.findSubmission('stranded')?.detail, contains('never confirmed'));
  });

  test('a restarted server releases the queue item the restart held', () async {
    await strandADispatch(withQueuedItem: true);
    final turns = _turnManager(messages);
    final restarted = buildService(turns);
    final recovered = await restarted.snapshot(sessionId);
    expect(recovered.findSubmission('waiting')?.workState, ConversationWorkState.held);

    final released = await restarted.releaseNext(sessionId: sessionId, expectedRevision: recovered.revision);

    expect(released.submission.submissionId, 'waiting');
    expect(released.submission.workState, ConversationWorkState.running);
    expect(turns.executeCallCount, 1);
  });

  test('a live turn still queues the next send while its claim reads uncertain', () async {
    final turns = _turnManager(messages);
    final live = buildService(turns);
    await _submit(live, sessionId, 'running-now', 'A turn that is genuinely live');
    // An acknowledgement retry relabels the running claim as uncertain.
    final replayed = await _submit(live, sessionId, 'running-now', 'A turn that is genuinely live');
    expect(replayed.submission.workState, ConversationWorkState.uncertain);

    final next = await _submit(live, sessionId, 'behind-it', 'Must wait for the live turn');

    expect(
      next.submission.workState,
      ConversationWorkState.queued,
      reason: 'the turn manager, not the claim marker, is what gates live work',
    );
    expect(turns.executeCallCount, 1);
  });

  test('a claim persisted mid-stop does not park the session after a restart', () async {
    final live = buildService(_turnManager(messages));
    await _submit(live, sessionId, 'stranded', 'The turn that did not survive');
    var state = await sessions.getConversationState(sessionId);
    final stopping = state.findSubmission('stranded')!.copyWith(workState: ConversationWorkState.stopping);
    await sessions.updateConversationState(sessionId, state.put(stopping));
    final turns = _turnManager(messages);
    final restarted = buildService(turns);

    state = await restarted.snapshot(sessionId);
    expect(state.findSubmission('stranded')?.workState, ConversationWorkState.uncertain);
    final next = await _submit(restarted, sessionId, 'after-restart', 'Send again after the restart');
    expect(next.submission.workState, ConversationWorkState.running);
    expect(turns.executeCallCount, 1);
  });

  test('a relabelled live claim still settles from its own outcome', () async {
    final turns = _CompletingTurnManager(messages);
    final live = buildService(turns);
    final first = await _submit(live, sessionId, 'running-now', 'A turn that is genuinely live');
    final replayed = await _submit(live, sessionId, 'running-now', 'A turn that is genuinely live');
    expect(replayed.submission.workState, ConversationWorkState.uncertain);

    turns.complete(sessionId, first.submission.turnId!);
    await live.drain();

    final settled = await live.snapshot(sessionId);
    expect(
      settled.findSubmission('running-now')?.workState,
      ConversationWorkState.completed,
      reason: 'the marker is informational; an observed outcome wins over it',
    );
  });

  test('a stop the runner refuses leaves the claim at its prior state', () async {
    await strandADispatch();
    final restarted = buildService(_turnManager(messages));
    final recovered = await restarted.snapshot(sessionId);
    final strandedTurnId = recovered.findSubmission('stranded')!.turnId!;

    await expectLater(
      restarted.stop(sessionId: sessionId, turnId: strandedTurnId),
      throwsA(isA<TurnCancelException>().having((error) => error.code, 'code', 'TURN_NOT_FOUND')),
    );

    final afterRefusal = await restarted.snapshot(sessionId);
    expect(
      afterRefusal.findSubmission('stranded')?.workState,
      ConversationWorkState.uncertain,
      reason: 'a refused cancel touched no turn, so it must not strand the claim mid-stop',
    );
    final next = await _submit(restarted, sessionId, 'after-refusal', 'The session still accepts work');
    expect(next.submission.workState, ConversationWorkState.running);
  });
}

/// Holds each dispatched turn's outcome until the test settles it.
final class _CompletingTurnManager extends FakeTurnManager {
  new(MessageService messages) : super(messages, FakeAgentHarness(), turnIdFactory: () => 'fake-turn-0');

  final Map<String, Completer<TurnOutcome>> _outcomes = {};

  @override
  Future<TurnOutcome> waitForOutcome(String sessionId, String turnId) =>
      _outcomes.putIfAbsent(turnId, Completer<TurnOutcome>.new).future;

  void complete(String sessionId, String turnId) {
    final outcome = TurnOutcome(
      turnId: turnId,
      sessionId: sessionId,
      status: TurnStatus.completed,
      completedAt: DateTime.utc(2026, 9, 21, 12),
    );
    setRecentOutcome(turnId, outcome);
    releaseTurn(sessionId, turnId);
    _outcomes.putIfAbsent(turnId, Completer<TurnOutcome>.new).complete(outcome);
  }
}

FakeTurnManager _turnManager(MessageService messages) {
  var next = 0;
  return FakeTurnManager(messages, FakeAgentHarness(), turnIdFactory: () => 'fake-turn-${next++}');
}

Future<ConversationAdmission> _submit(
  ConversationService conversation,
  String sessionId,
  String identity,
  String message,
) => conversation.submit(
  sessionId: sessionId,
  submissionId: identity,
  revisionId: '$identity-revision',
  message: message,
  attachments: const [],
  references: const [],
);
