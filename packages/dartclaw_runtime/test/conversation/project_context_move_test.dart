import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/concurrency/session_mutation_coordinator.dart';
import 'package:dartclaw_runtime/src/conversation/conversation_service.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness, FakeProjectService;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../session_turn_manager_test_support.dart';

void main() {
  late Directory root;
  late Directory owner;
  late Directory checkout;
  late SessionService sessions;
  late MessageService messages;
  late FakeTurnManager turns;
  late ConversationService conversation;
  late String sessionId;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('project_context_move_');
    owner = Directory(p.join(root.path, 'owner'))..createSync();
    checkout = Directory(p.join(root.path, 'checkout'))..createSync();
    sessions = SessionService(baseDir: root.path);
    messages = MessageService(baseDir: root.path);
    turns = FakeTurnManager(messages, FakeAgentHarness());
    final projects = FakeProjectService(
      localProject: Project(
        id: '_local',
        name: 'Local',
        remoteUrl: '',
        localPath: root.path,
        status: ProjectStatus.ready,
        createdAt: DateTime.utc(2026),
      ),
      projects: [
        Project(
          id: 'checkout',
          name: 'Checkout',
          remoteUrl: '',
          localPath: checkout.path,
          status: ProjectStatus.ready,
          createdAt: DateTime.utc(2026),
        ),
      ],
    );
    conversation = ConversationService(
      sessions: sessions,
      messages: messages,
      turns: turns,
      mutations: SessionMutationCoordinator(),
      projects: projects,
      ownerWorkspaceDir: owner.path,
    );
    sessionId = (await sessions.createSession()).id;
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<ConversationState> move(
    ConversationState state,
    String? projectId,
    String directory, {
    List<Map<String, dynamic>> references = const [],
  }) => conversation.updateContext(
    sessionId: sessionId,
    expectedRevision: state.revision,
    projectId: projectId,
    directory: directory,
    provider: 'claude',
    references: references,
  );

  test('idle moves retain one identity and history, mark each real change, and reset continuity', () async {
    final initial = await conversation.snapshot(sessionId);
    expect(initial.nextContext?.projectId, isNull);
    final toCheckout = await move(initial, 'checkout', checkout.path);
    expect(toCheckout.nextContext?.projectId, 'checkout');
    expect(toCheckout.records.single.kind, ConversationRecordKind.contextChange);
    expect(toCheckout.records.single.label, contains('Future messages run in Checkout'));
    expect(turns.resetContinuitySessionIds, [sessionId]);

    final noOp = await move(toCheckout, 'checkout', checkout.path);
    expect(noOp.revision, toCheckout.revision);
    expect(noOp.records, hasLength(1));

    final back = await move(noOp, null, owner.path);
    expect(back.nextContext?.projectId, isNull);
    expect(back.records, hasLength(2));
    expect(back.records.last.label, contains('Future messages run in General chat'));
    expect(turns.resetContinuitySessionIds, [sessionId, sessionId]);
    expect((await sessions.getSession(sessionId))!.id, sessionId);
  });

  test('stale revision, missing destination, and invalid draft reference preserve source context', () async {
    final initial = await conversation.snapshot(sessionId);
    File(p.join(owner.path, 'draft.md')).writeAsStringSync('source only');
    for (final failure in [
      () => conversation.updateContext(
        sessionId: sessionId,
        expectedRevision: initial.revision - 1,
        projectId: 'checkout',
        directory: checkout.path,
        provider: 'claude',
      ),
      () => move(initial, 'missing', checkout.path),
    ]) {
      await expectLater(failure(), throwsA(isA<ConversationMutationException>()));
      final unchanged = await conversation.snapshot(sessionId);
      expect(unchanged.revision, initial.revision);
      expect(unchanged.nextContext?.projectId, isNull);
      expect(unchanged.records, isEmpty);
    }
    await expectLater(
      move(
        initial,
        'checkout',
        checkout.path,
        references: [
          {'type': 'file', 'id': 'draft.md'},
        ],
      ),
      throwsA(
        isA<ConversationMutationException>()
            .having((error) => error.message, 'message', contains('draft.md'))
            .having((error) => error.message, 'correction', contains('Remove or replace')),
      ),
    );
    final afterInvalidReference = await conversation.snapshot(sessionId);
    expect(afterInvalidReference.revision, initial.revision);
    expect(afterInvalidReference.nextContext?.projectId, isNull);
    expect(afterInvalidReference.records, isEmpty);
  });

  test('pending accepted work refuses a move before changing context or history', () async {
    final initial = await conversation.snapshot(sessionId);
    await conversation.submit(
      sessionId: sessionId,
      submissionId: 'active',
      revisionId: 'active-r1',
      message: 'Keep this work',
      attachments: const [],
      references: const [],
    );
    final active = await conversation.snapshot(sessionId);
    await expectLater(
      move(active, 'checkout', checkout.path),
      throwsA(isA<ConversationMutationException>().having((error) => error.code, 'code', 'CONTEXT_MOVE_BUSY')),
    );
    final unchanged = await conversation.snapshot(sessionId);
    expect(unchanged.revision, active.revision);
    expect(unchanged.nextContext?.projectId, isNull);
    expect(unchanged.records, isEmpty);
    expect(turns.resetContinuitySessionIds, isEmpty);
    expect(initial.nextContext?.directory, owner.resolveSymbolicLinksSync());
  });

  test('queued, held, dispatching, and running claims refuse a move without an active turn', () async {
    for (final status in [
      ConversationWorkState.queued,
      ConversationWorkState.held,
      ConversationWorkState.dispatching,
      ConversationWorkState.running,
    ]) {
      sessionId = (await sessions.createSession()).id;
      final initial = await conversation.snapshot(sessionId);
      final pending = initial.put(
        ConversationSubmissionClaim(
          submissionId: 'pending-${status.name}',
          revisionId: 'pending-r1',
          messageId: 'pending-message',
          attemptId: 'pending-attempt',
          payloadDigest: 'fixture',
          message: 'Keep pending work',
          commitState: SubmissionCommitState.committed,
          workState: status,
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
          admittedContext: initial.nextContext,
        ),
      );
      await sessions.updateConversationState(sessionId, pending);
      await expectLater(
        move(pending, 'checkout', checkout.path),
        throwsA(isA<ConversationMutationException>().having((error) => error.code, 'code', 'CONTEXT_MOVE_BUSY')),
        reason: status.name,
      );
      final unchanged = await conversation.snapshot(sessionId);
      expect(unchanged.revision, pending.revision);
      expect(unchanged.nextContext?.projectId, isNull);
      expect(unchanged.records, isEmpty);
    }
  });

  test('Agent, temporary, channel, task, cron, and archived conversations cannot move', () async {
    final ineligible = <Session>[
      await sessions.createSession(type: SessionType.main),
      await sessions.createSession(retention: ConversationRetention.process),
      await sessions.createSession(type: SessionType.channel, channelKey: 'fixture:channel'),
      await sessions.createSession(type: SessionType.task),
      await sessions.createSession(type: SessionType.cron),
      await sessions.createSession(type: SessionType.logicalAgent),
      await sessions.createSession(type: SessionType.archive),
      await sessions.createSession(
        workspace: AgentWorkspace.pinned(agentId: 'fixture-agent', directory: owner.path),
      ),
    ];
    for (final session in ineligible) {
      sessionId = session.id;
      final initial = await conversation.snapshot(sessionId);
      final targetId = initial.nextContext?.projectId == null ? 'checkout' : null;
      final targetDirectory = targetId == null ? owner.path : checkout.path;
      await expectLater(
        move(initial, targetId, targetDirectory),
        throwsA(isA<ConversationMutationException>().having((error) => error.code, 'code', 'CONTEXT_MOVE_UNAVAILABLE')),
        reason: session.type.name,
      );
      final unchanged = await conversation.snapshot(sessionId);
      expect(unchanged.revision, initial.revision);
      expect(unchanged.records, isEmpty);
    }
  });
}
