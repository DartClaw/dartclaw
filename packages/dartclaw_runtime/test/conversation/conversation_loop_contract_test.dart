import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_runtime/src/concurrency/session_mutation_coordinator.dart';
import 'package:dartclaw_runtime/src/conversation/conversation_service.dart';
import 'package:dartclaw_runtime/src/runtime_tool_history.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:test/test.dart';

import '../session_turn_manager_test_support.dart';

void main() {
  late Directory temporaryDirectory;
  late SessionService sessions;
  late MessageService messages;
  late _CompletingTurnManager turns;
  late ConversationService conversation;
  late String sessionId;
  var clockTick = 0;

  setUp(() async {
    temporaryDirectory = Directory.systemTemp.createTempSync('dartclaw_conversation_loop_');
    sessions = SessionService(baseDir: temporaryDirectory.path);
    messages = MessageService(baseDir: temporaryDirectory.path);
    turns = _CompletingTurnManager(messages, FakeAgentHarness());
    conversation = ConversationService(
      sessions: sessions,
      messages: messages,
      turns: turns,
      mutations: SessionMutationCoordinator(),
      clock: () => DateTime.utc(2026, 9, 14).add(Duration(milliseconds: clockTick++)),
    );
    sessionId = (await sessions.createSession()).id;
  });

  tearDown(() {
    if (temporaryDirectory.existsSync()) temporaryDirectory.deleteSync(recursive: true);
  });

  test('shutdown refuses an unrecovered session before reading or writing its state', () async {
    final observed = _PausingApprovalSessionService(baseDir: temporaryDirectory.path);
    final stopping = ConversationService(
      sessions: observed,
      messages: messages,
      turns: turns,
      mutations: SessionMutationCoordinator(),
    );
    await stopping.beginShutdown();
    await expectLater(
      _submit(stopping, sessionId, 'late-unseen', 'Arrived after shutdown'),
      throwsA(isA<ConversationMutationException>().having((error) => error.code, 'code', 'SERVER_STOPPING')),
    );
    expect(observed.reads, 0, reason: 'late admission must not start recovery');
    expect(observed.writes, 0, reason: 'late admission must not rewrite state');
  });

  for (final closing in [false, true]) {
    test('shutdown retains the complete approval ${closing ? 'close' : 'request'} callback', () async {
      final observed = _PausingApprovalSessionService(baseDir: temporaryDirectory.path);
      final stopping = ConversationService(
        sessions: observed,
        messages: messages,
        turns: turns,
        mutations: SessionMutationCoordinator(),
      );
      final admission = await _submit(stopping, sessionId, 'approval-owner', 'An approval-owned attempt');
      turns.complete(sessionId, admission.submission.turnId!);
      await stopping.drain();
      final request = RuntimeToolApprovalRequest(
        sessionId: sessionId,
        turnId: admission.submission.turnId!,
        requestId: 'shutdown-approval',
        action: 'Run command',
        target: const {'command': 'pwd'},
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
      );
      if (closing) await stopping.retainRuntimeApproval(request);
      await stopping.beginShutdown();
      observed.pauseState = closing ? ConversationRecordState.approved : ConversationRecordState.pending;
      final operation = closing
          ? stopping.closeRuntimeApproval(sessionId, request.turnId, request.requestId, true, false)
          : stopping.retainRuntimeApproval(request);
      await observed.writeStarted.future;
      var drained = false;
      final drain = stopping.drain().then((_) => drained = true);
      await pumpEventQueue();
      final returnedBeforeWrite = drained;
      observed.releaseWrite.complete();
      await operation;
      await drain;
      expect(returnedBeforeWrite, isFalse, reason: 'the entire approval callback belongs to the shutdown drain');
      expect(
        (await observed.getConversationState(sessionId)).findRecord(request.requestId)?.state,
        observed.pauseState,
      );
    });
  }

  test('shutdown drains terminal persistence and holds queued work without dispatching it', () async {
    final writingTerminal = Completer<void>();
    final releaseWrite = Completer<void>();
    final stopping = ConversationService(
      sessions: sessions,
      messages: messages,
      turns: turns,
      mutations: SessionMutationCoordinator(),
      failpoint: (boundary, _) async {
        if (boundary == 'turn_settled') {
          writingTerminal.complete();
          await releaseWrite.future;
        }
      },
    );
    final active = await _submit(stopping, sessionId, 'active', 'Finish before shutdown');
    await _submit(stopping, sessionId, 'queued', 'Hold for explicit recovery');
    await stopping.beginShutdown();
    turns.complete(sessionId, active.submission.turnId!);
    await writingTerminal.future;
    var drained = false;
    final drain = stopping.drain().then((_) => drained = true);
    await pumpEventQueue();
    expect(drained, isFalse, reason: 'shutdown must wait for terminal persistence');
    releaseWrite.complete();
    await drain;
    final state = await stopping.snapshot(sessionId);
    expect(state.findSubmission('active')?.workState, ConversationWorkState.completed);
    expect(state.findSubmission('queued')?.workState, ConversationWorkState.held);
    expect(turns.executeCount, 1, reason: 'shutdown must not dispatch queued work');
    await expectLater(
      _submit(stopping, sessionId, 'late', 'Arrived during shutdown'),
      throwsA(isA<ConversationMutationException>().having((error) => error.code, 'code', 'SERVER_STOPPING')),
    );
  });

  test('queue edit remove release and dispatch races converge without stale execution', () async {
    final active = await _submit(conversation, sessionId, 'active', 'Run the first turn');
    final firstQueued = await _submit(conversation, sessionId, 'queued-1', 'First queued message');
    final secondQueued = await _submit(conversation, sessionId, 'queued-2', 'Second queued message');
    expect(turns.executeCount, 1);
    expect(firstQueued.submission.workState, ConversationWorkState.queued);
    expect(secondQueued.submission.workState, ConversationWorkState.queued);

    final edited = await conversation.editQueueItem(
      sessionId: sessionId,
      queueId: firstQueued.submission.queueId!,
      expectedRevision: secondQueued.snapshot.revision,
      revisionId: 'queued-1-edit',
      message: 'Edited first queued message',
      attachments: const [],
      references: const [],
    );
    final removed = await conversation.removeQueueItem(
      sessionId: sessionId,
      queueId: firstQueued.submission.queueId!,
      expectedRevision: edited.snapshot.revision,
    );
    final repeated = await conversation.removeQueueItem(
      sessionId: sessionId,
      queueId: firstQueued.submission.queueId!,
      expectedRevision: removed.snapshot.revision,
    );
    expect(repeated.replayed, isTrue);
    expect(repeated.submission.workState, ConversationWorkState.removed);

    await expectLater(
      conversation.releaseNext(sessionId: sessionId, expectedRevision: removed.snapshot.revision),
      throwsA(isA<ConversationMutationException>().having((error) => error.code, 'code', 'DISPATCH_UNCERTAIN')),
    );

    turns.complete(sessionId, active.submission.turnId!);
    await turns.secondDispatch;
    final settled = await conversation.snapshot(sessionId);
    expect(turns.executeCount, 2);
    expect(turns.executedMessages.last.last['content'], 'Second queued message');
    expect(
      turns.executedMessages.last.where((message) => message['role'] == 'user').map((message) => message['content']),
      ['Run the first turn', 'Second queued message'],
    );
    expect(settled.findSubmission('queued-1')?.workState, ConversationWorkState.removed);
    expect(settled.findSubmission('queued-2')?.workState, ConversationWorkState.running);
    await expectLater(
      conversation.removeQueueItem(
        sessionId: sessionId,
        queueId: secondQueued.submission.queueId!,
        expectedRevision: settled.revision,
      ),
      throwsA(isA<ConversationMutationException>().having((error) => error.code, 'code', 'QUEUE_ITEM_ALREADY_SENT')),
    );
    final passiveSnapshot = await conversation.snapshot(sessionId);
    expect(passiveSnapshot.revision, settled.revision);
    expect(passiveSnapshot.queue.map((item) => item.submissionId), settled.queue.map((item) => item.submissionId));
  });

  test('queue edit recovers through the same preparing to committed sequence', () async {
    var crashEdits = false;
    final interrupted = ConversationService(
      sessions: sessions,
      messages: messages,
      turns: turns,
      mutations: SessionMutationCoordinator(),
      clock: () => DateTime.utc(2026, 9, 14, 13),
      failpoint: (boundary, _) {
        if (crashEdits && boundary == 'queue_edit_preparing') throw StateError('simulated edit crash');
      },
    );
    await _submit(interrupted, sessionId, 'active-edit-recovery', 'Active turn');
    final queued = await _submit(interrupted, sessionId, 'queued-edit-recovery', 'Original queued text');
    crashEdits = true;

    await expectLater(
      interrupted.editQueueItem(
        sessionId: sessionId,
        queueId: queued.submission.queueId!,
        expectedRevision: queued.snapshot.revision,
        revisionId: 'edited-revision',
        message: 'Recovered queued text',
        attachments: const [],
        references: const [],
      ),
      throwsStateError,
    );
    final preparing = await sessions.getConversationState(sessionId);
    expect(preparing.findSubmission('queued-edit-recovery')?.commitState, SubmissionCommitState.preparing);
    expect((await messages.getMessages(sessionId)).last.content, 'Original queued text');

    final recovered = ConversationService(
      sessions: sessions,
      messages: messages,
      turns: turns,
      mutations: SessionMutationCoordinator(),
      clock: () => DateTime.utc(2026, 9, 14, 13, 1),
    );
    final snapshot = await recovered.snapshot(sessionId);
    expect(snapshot.findSubmission('queued-edit-recovery')?.commitState, SubmissionCommitState.committed);
    expect((await messages.getMessages(sessionId)).last.content, 'Recovered queued text');
    expect(turns.executeCount, 1);
  });

  test('competing queue mutations admit only one expected revision', () async {
    await _submit(conversation, sessionId, 'active-queue-race', 'Active turn');
    final queued = await _submit(conversation, sessionId, 'queued-race', 'Queued turn');

    final results = await Future.wait<Object>([
      conversation
          .editQueueItem(
            sessionId: sessionId,
            queueId: queued.submission.queueId!,
            expectedRevision: queued.snapshot.revision,
            revisionId: 'queued-race-edited',
            message: 'Edited by race',
            attachments: const [],
            references: const [],
          )
          .then<Object>((value) => value)
          .catchError((Object error) => error),
      conversation
          .removeQueueItem(
            sessionId: sessionId,
            queueId: queued.submission.queueId!,
            expectedRevision: queued.snapshot.revision,
          )
          .then<Object>((value) => value)
          .catchError((Object error) => error),
    ]);

    expect(results.whereType<ConversationAdmission>(), hasLength(1));
    expect(results.whereType<ConversationMutationException>().single.code, 'STALE_CONVERSATION_REVISION');
    expect(turns.executeCount, 1);
  });

  test('provider control matrix keeps stop and steer truthful through completion races', () async {
    for (final provider in const ['claude', 'codex', 'acp']) {
      final providerSession = (await sessions.createSession(provider: provider)).id;
      final active = await _submit(conversation, providerSession, '$provider-active', 'Work for $provider');
      await _submit(conversation, providerSession, '$provider-queued', 'Follow up for $provider');
      final partial = await messages.insertMessage(
        sessionId: providerSession,
        role: 'assistant',
        content: 'Partial $provider output',
      );
      expect(turns.turnStatus(providerSession).canCancel, isTrue, reason: provider);

      final stopped = await conversation.stop(sessionId: providerSession, turnId: active.submission.turnId!);
      expect(stopped.findSubmission('$provider-active')?.workState, ConversationWorkState.cancelled, reason: provider);
      expect(stopped.findSubmission('$provider-queued')?.workState, ConversationWorkState.held, reason: provider);
      expect((await messages.getMessages(providerSession)).any((message) => message.id == partial.id), isTrue);
      final repeat = await conversation.stop(sessionId: providerSession, turnId: active.submission.turnId!);
      expect(repeat.revision, stopped.revision, reason: '$provider repeated stop changed state');

      final released = await conversation.releaseNext(sessionId: providerSession, expectedRevision: stopped.revision);
      expect(released.submission.submissionId, '$provider-queued');
      expect(released.submission.workState, ConversationWorkState.running);

      final steerSession = (await sessions.createSession(provider: provider)).id;
      final steerActive = await _submit(conversation, steerSession, '$provider-steer-active', 'Steer from this');
      final steerStopped = await conversation.stop(sessionId: steerSession, turnId: steerActive.submission.turnId!);
      final steered = await _submit(conversation, steerSession, '$provider-steer', 'Steered follow-up for $provider');
      expect(steerStopped.findSubmission('$provider-steer-active')?.workState, ConversationWorkState.cancelled);
      expect(steered.submission.workState, ConversationWorkState.running);
    }

    final completed = await _submit(conversation, sessionId, 'completion-race', 'Finishes at stop time');
    turns.complete(sessionId, completed.submission.turnId!);
    await _waitForWorkState(conversation, sessionId, 'completion-race', ConversationWorkState.completed);
    final beforeRepeat = await conversation.snapshot(sessionId);
    final repeat = await conversation.stop(sessionId: sessionId, turnId: completed.submission.turnId!);
    expect(repeat.revision, beforeRepeat.revision);
    expect(repeat.findSubmission('completion-race')?.workState, ConversationWorkState.completed);
  });

  test('conversation mutations reject no-match and stale input without side effects', () async {
    await expectLater(
      conversation.submit(
        sessionId: sessionId,
        submissionId: 'unknown-attachment',
        revisionId: 'unknown-attachment-r1',
        message: 'Invalid attachment',
        attachments: const [
          {'id': '00000000-0000-4000-8000-000000000000'},
        ],
        references: const [],
      ),
      throwsA(isA<ConversationMutationException>().having((error) => error.code, 'code', 'UNKNOWN_ATTACHMENT')),
    );
    expect((await sessions.getConversationState(sessionId)).revision, 0);
    expect(await messages.getMessages(sessionId), isEmpty);

    final accepted = await _submit(conversation, sessionId, 'plain', 'Plain message');
    final queued = await _submit(conversation, sessionId, 'queued', 'Queued message');
    final before = await sessions.getConversationState(sessionId);
    await expectLater(
      conversation.editQueueItem(
        sessionId: sessionId,
        queueId: queued.submission.queueId!,
        expectedRevision: queued.snapshot.revision - 1,
        revisionId: 'stale-edit',
        message: 'Must not persist',
        attachments: const [],
        references: const [],
      ),
      throwsA(
        isA<ConversationMutationException>().having((error) => error.code, 'code', 'STALE_CONVERSATION_REVISION'),
      ),
    );
    await expectLater(
      conversation.removeQueueItem(
        sessionId: sessionId,
        queueId: 'missing',
        expectedRevision: queued.snapshot.revision,
      ),
      throwsA(isA<ConversationMutationException>().having((error) => error.code, 'code', 'QUEUE_ITEM_NOT_FOUND')),
    );
    await expectLater(
      conversation.submit(
        sessionId: sessionId,
        submissionId: accepted.submission.submissionId,
        revisionId: 'changed-revision',
        message: 'Changed payload under the same identity',
        attachments: const [],
        references: const [],
      ),
      throwsA(isA<ConversationMutationException>().having((error) => error.code, 'code', 'SUBMISSION_CONFLICT')),
    );
    await expectLater(
      conversation.stop(sessionId: sessionId, turnId: 'missing-turn'),
      throwsA(isA<ConversationMutationException>().having((error) => error.code, 'code', 'TURN_NOT_FOUND')),
    );

    final after = await sessions.getConversationState(sessionId);
    expect(after.revision, before.revision);
    expect((await messages.getMessages(sessionId)).map((message) => message.content), [
      'Plain message',
      'Queued message',
    ]);
    expect(turns.executeCount, 1);
  });

  test('pre-execution reserve rejection returns dispatch-marked work to a durable queue', () async {
    turns.setBusy();

    final admission = await _submit(conversation, sessionId, 'capacity', 'Wait for capacity');

    expect(admission.submission.workState, ConversationWorkState.queued);
    expect(admission.submission.attemptId, isNull);
    expect(admission.submission.queueId, isNotNull);
    expect(turns.executeCount, 0);
    expect(await conversation.visibleMessages(sessionId), isEmpty);
    final attempts = Directory('${temporaryDirectory.path}/$sessionId/conversation/attempts');
    expect(attempts.existsSync() ? attempts.listSync() : const [], isEmpty);

    turns.clearBusy();
    final released = await conversation.releaseNext(
      sessionId: sessionId,
      expectedRevision: admission.snapshot.revision,
    );
    expect(released.submission.workState, ConversationWorkState.running);
    expect(turns.executeCount, 1);
    expect((await conversation.visibleMessages(sessionId)).single.content, 'Wait for capacity');
  });

  test('committed work is held when the transcript fails the pre-dispatch integrity check', () async {
    turns.setBusy();
    final queued = await _submit(conversation, sessionId, 'corrupt-transcript', 'Original durable text');
    final transcript = File('${temporaryDirectory.path}/$sessionId/messages.ndjson');
    await transcript.writeAsString(
      (await transcript.readAsString()).replaceFirst('Original durable text', 'Corrupted durable text'),
    );
    turns.clearBusy();

    await expectLater(
      conversation.releaseNext(sessionId: sessionId, expectedRevision: queued.snapshot.revision),
      throwsA(
        isA<ConversationMutationException>().having((error) => error.code, 'code', 'SUBMISSION_INTEGRITY_FAILED'),
      ),
    );

    final state = await sessions.getConversationState(sessionId);
    expect(state.findSubmission('corrupt-transcript')?.commitState, SubmissionCommitState.integrityFailed);
    expect(state.findSubmission('corrupt-transcript')?.workState, ConversationWorkState.held);
    expect(turns.executeCount, 0);
  });

  test('recovery refuses to overwrite a mismatched accepted attachment manifest', () async {
    final attachmentId = '00000000-0000-4000-8000-000000000001';
    final bytes = utf8.encode('attachment text');
    final digest = 'sha256:${sha256.convert(bytes)}';
    final attachmentDirectory = Directory('${temporaryDirectory.path}/$sessionId/attachments')..createSync();
    await File('${attachmentDirectory.path}/$attachmentId.data').writeAsBytes(bytes);
    await File('${attachmentDirectory.path}/$attachmentId.json').writeAsString(
      jsonEncode({
        'id': attachmentId,
        'filename': 'notes.txt',
        'mediaType': 'text/plain',
        'size': bytes.length,
        'digest': digest,
        'state': 'ready',
      }),
    );
    turns.setBusy();
    final interrupted = ConversationService(
      sessions: sessions,
      messages: messages,
      turns: turns,
      mutations: SessionMutationCoordinator(),
      failpoint: (boundary, _) {
        if (boundary == 'accepted_manifest') throw StateError('simulated crash after manifest write');
      },
    );
    await expectLater(
      interrupted.submit(
        sessionId: sessionId,
        submissionId: 'attachment-manifest',
        revisionId: 'attachment-manifest-revision',
        message: 'Use the attachment',
        attachments: [
          {'id': attachmentId},
        ],
        references: const [],
      ),
      throwsStateError,
    );
    final manifest = File('${temporaryDirectory.path}/$sessionId/conversation/manifests/attachment-manifest.json');
    await manifest.writeAsString(jsonEncode({'submissionId': 'different', 'attachments': const []}));

    final recovered = ConversationService(
      sessions: sessions,
      messages: messages,
      turns: turns,
      mutations: SessionMutationCoordinator(),
    );
    final state = await recovered.snapshot(sessionId);

    expect(state.findSubmission('attachment-manifest')?.commitState, SubmissionCommitState.integrityFailed);
    expect(state.findSubmission('attachment-manifest')?.workState, ConversationWorkState.held);
    expect(jsonDecode(await manifest.readAsString()), {'submissionId': 'different', 'attachments': const []});
    expect(turns.executeCount, 0);
  });

  test('attachment metadata uses the same bounded resolver as admission', () async {
    final longId = '00000000-0000-4000-8000-000000000010';
    final longBytes = utf8.encode(List.filled(21000, 'x').join());
    await _writeReadyAttachment(temporaryDirectory, sessionId, longId, longBytes);

    await conversation.submit(
      sessionId: sessionId,
      submissionId: 'bounded-attachment',
      revisionId: 'bounded-attachment-revision',
      message: 'Read this',
      attachments: [
        {'id': longId},
      ],
      references: const [],
    );

    final context = turns.executedMessages.single.last['content'] as String;
    expect(context, contains('[Attachment content truncated]'));
    expect(context.length, lessThan(20500));

    final opaqueSession = (await sessions.createSession()).id;
    final opaqueId = '00000000-0000-4000-8000-000000000011';
    await _writeReadyAttachment(temporaryDirectory, opaqueSession, opaqueId, const [0xff, 0xfe, 0xfd]);
    final opaque = await conversation.submit(
      sessionId: opaqueSession,
      submissionId: 'opaque-attachment',
      revisionId: 'opaque-attachment-revision',
      message: 'Keep opaque bytes',
      attachments: [
        {'id': opaqueId},
      ],
      references: const [],
    );
    expect(opaque.submission.workState, ConversationWorkState.running);
    expect(turns.executeCount, 2);
  });
}

Future<void> _writeReadyAttachment(Directory root, String sessionId, String attachmentId, List<int> bytes) async {
  final directory = Directory('${root.path}/$sessionId/attachments')..createSync(recursive: true);
  final digest = 'sha256:${sha256.convert(bytes)}';
  await File('${directory.path}/$attachmentId.data').writeAsBytes(bytes);
  await File('${directory.path}/$attachmentId.json').writeAsString(
    jsonEncode({
      'id': attachmentId,
      'filename': 'proof.txt',
      'mediaType': 'text/plain',
      'size': bytes.length,
      'digest': digest,
      'state': 'ready',
    }),
  );
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

Future<void> _waitForWorkState(
  ConversationService conversation,
  String sessionId,
  String submissionId,
  ConversationWorkState expected,
) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    final state = await conversation.snapshot(sessionId);
    if (state.findSubmission(submissionId)?.workState == expected) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Submission $submissionId did not reach ${expected.name}');
}

final class _CompletingTurnManager extends FakeTurnManager {
  new(super.messages, super.worker);

  final Map<String, Completer<TurnOutcome>> _waiting = {};
  final List<List<Map<String, dynamic>>> executedMessages = [];
  final Completer<void> _secondDispatch = Completer<void>();

  int get executeCount => executedMessages.length;
  Future<void> get secondDispatch => _secondDispatch.future;

  @override
  void executeTurn(
    String sessionId,
    String turnId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
  }) {
    if (_waiting[sessionId]?.isCompleted ?? true) _waiting[sessionId] = Completer<TurnOutcome>();
    executedMessages.add(messages);
    if (executedMessages.length >= 2 && !_secondDispatch.isCompleted) _secondDispatch.complete();
    super.executeTurn(sessionId, turnId, messages, source: source, agentName: agentName);
  }

  @override
  Future<TurnOutcome> waitForOutcome(String sessionId, String turnId) => _waiting[sessionId]!.future;

  void complete(String sessionId, String turnId) {
    final outcome = TurnOutcome(
      turnId: turnId,
      sessionId: sessionId,
      status: TurnStatus.completed,
      completedAt: DateTime.utc(2026, 9, 14, 12),
    );
    setRecentOutcome(turnId, outcome);
    releaseTurn(sessionId, turnId);
    _waiting[sessionId]?.complete(outcome);
  }
}

final class _PausingApprovalSessionService extends SessionService {
  new({required super.baseDir});

  int reads = 0;
  int writes = 0;
  ConversationRecordState? pauseState;
  final writeStarted = Completer<void>();
  final releaseWrite = Completer<void>();

  @override
  Future<ConversationState> getConversationState(String id) {
    reads += 1;
    return super.getConversationState(id);
  }

  @override
  Future<void> updateConversationState(String id, ConversationState state) async {
    writes += 1;
    if (pauseState != null && state.findRecord('shutdown-approval')?.state == pauseState && !writeStarted.isCompleted) {
      writeStarted.complete();
      await releaseWrite.future;
    }
    await super.updateConversationState(id, state);
  }
}
