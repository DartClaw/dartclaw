import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/concurrency/session_mutation_coordinator.dart';
import 'package:dartclaw_runtime/src/conversation/conversation_service.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness, FakeProjectService;
import 'package:test/test.dart';

import '../session_turn_manager_test_support.dart';

void main() {
  late Directory root;
  late SessionService sessions;
  late MessageService messages;
  late _ContextTurns turns;
  late ConversationService conversation;
  late String sessionId;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('effective_session_context_');
    sessions = SessionService(baseDir: root.path);
    messages = MessageService(baseDir: root.path);
    turns = _ContextTurns(messages, FakeAgentHarness());
    final projects = FakeProjectService(
      localProject: Project(
        id: '_local',
        name: 'Local',
        remoteUrl: '',
        localPath: root.path,
        defaultBranch: 'main',
        status: ProjectStatus.ready,
        createdAt: DateTime.utc(2026, 9, 14),
      ),
    );
    conversation = ConversationService(
      sessions: sessions,
      messages: messages,
      turns: turns,
      mutations: SessionMutationCoordinator(),
      contextCapabilities: const {
        'claude': EffectiveContextCapabilities(model: true, effort: true),
        'acp': EffectiveContextCapabilities.unavailable,
      },
      projects: projects,
    );
    sessionId = (await sessions.createSession(
      workspace: AgentWorkspace.pinned(agentId: 'configured-agent', directory: root.path),
    )).id;
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('session context stages by revision and admission snapshots one next-turn context', () async {
    final initial = await conversation.snapshot(sessionId);
    expect(initial.nextContext?.projectId, '_local');
    expect((await sessions.getSession(sessionId))?.workspace?.storagePrincipal, 'agent:configured-agent');

    final staged = await conversation.updateContext(
      sessionId: sessionId,
      expectedRevision: initial.revision,
      projectId: '_local',
      directory: root.path,
      provider: 'claude',
      model: 'opus',
      effort: 'high',
    );
    expect(staged.nextContext?.model, 'opus');
    final active = await _submit(conversation, sessionId, 'active');
    expect(active.submission.admittedContext?.model, 'opus');
    expect(turns.context?.provider, 'claude');
    expect(turns.context?.directory, root.resolveSymbolicLinksSync());
    expect(turns.context?.model, 'opus');
    expect(turns.context?.effort, 'high');

    final next = await conversation.updateContext(
      sessionId: sessionId,
      expectedRevision: active.snapshot.revision,
      projectId: '_local',
      directory: root.path,
      provider: 'claude',
      model: 'sonnet',
      effort: 'medium',
    );
    final queued = await _submit(conversation, sessionId, 'queued');
    expect(queued.submission.admittedContext?.model, 'sonnet');
    expect(queued.submission.workState, ConversationWorkState.queued);
    expect(queued.snapshot.currentContext?.model, 'opus');
    expect(queued.snapshot.nextContext?.model, 'sonnet');

    final reloaded = ConversationService(
      sessions: sessions,
      messages: messages,
      turns: turns,
      mutations: SessionMutationCoordinator(),
      contextCapabilities: const {'claude': EffectiveContextCapabilities(model: true, effort: true)},
      projects: FakeProjectService(
        localProject: Project(
          id: '_local',
          name: 'Local',
          remoteUrl: '',
          localPath: root.path,
          defaultBranch: 'main',
          status: ProjectStatus.ready,
          createdAt: DateTime.utc(2026, 9, 14),
        ),
      ),
    );
    final persisted = await reloaded.snapshot(sessionId);
    expect(persisted.nextContext?.toJson(), next.nextContext?.toJson());
    expect(persisted.findSubmission('queued')?.admittedContext?.model, 'sonnet');
  });

  test('authorized changes revalidate drafts and stale changes fail atomically', () async {
    final initial = await conversation.snapshot(sessionId);
    final accepted = await conversation.updateContext(
      sessionId: sessionId,
      expectedRevision: initial.revision,
      projectId: '_local',
      directory: root.path,
      provider: 'claude',
    );

    for (final mutation in [
      () => conversation.updateContext(
        sessionId: sessionId,
        expectedRevision: initial.revision,
        projectId: '_local',
        directory: root.path,
        provider: 'claude',
      ),
      () => conversation.updateContext(
        sessionId: sessionId,
        expectedRevision: accepted.revision,
        projectId: 'another-project',
        directory: root.path,
        provider: 'claude',
      ),
      () => conversation.updateContext(
        sessionId: sessionId,
        expectedRevision: accepted.revision,
        projectId: '_local',
        directory: root.path,
        provider: 'acp',
        model: 'ignored-model',
      ),
    ]) {
      await expectLater(mutation(), throwsA(isA<ConversationMutationException>()));
      final unchanged = await conversation.snapshot(sessionId);
      expect(unchanged.revision, accepted.revision);
      expect(unchanged.nextContext?.toJson(), accepted.nextContext?.toJson());
    }

    await expectLater(
      conversation.submit(
        sessionId: sessionId,
        submissionId: 'bad-reference',
        revisionId: 'r1',
        message: 'draft remains client-owned',
        attachments: const [],
        references: const [
          {'type': 'file', 'id': 'missing.txt'},
        ],
      ),
      throwsA(isA<ConversationMutationException>().having((error) => error.code, 'code', 'UNKNOWN_REFERENCE')),
    );
    expect((await conversation.snapshot(sessionId)).submissions, isEmpty);
    expect(turns.reserveCalled, isFalse);
  });

  test('queue edits validate references against the item admitted context before mutation', () async {
    final projectA = Directory('${root.path}/project-a')..createSync();
    final projectB = Directory('${root.path}/project-b')..createSync();
    File('${projectA.path}/a.md').writeAsStringSync('A');
    File('${projectB.path}/b.md').writeAsStringSync('B');
    final localTurns = _ContextTurns(messages, FakeAgentHarness());
    final service = ConversationService(
      sessions: sessions,
      messages: messages,
      turns: localTurns,
      mutations: SessionMutationCoordinator(),
      contextCapabilities: const {'claude': EffectiveContextCapabilities(model: true, effort: true)},
      projects: FakeProjectService(
        localProject: Project(
          id: '_local',
          name: 'Project A',
          remoteUrl: '',
          localPath: projectA.path,
          defaultBranch: 'main',
          status: ProjectStatus.ready,
          createdAt: DateTime.utc(2026, 9, 14),
        ),
        projects: [
          Project(
            id: 'project-b',
            name: 'Project B',
            remoteUrl: '',
            localPath: projectB.path,
            defaultBranch: 'main',
            status: ProjectStatus.ready,
            createdAt: DateTime.utc(2026, 9, 14),
          ),
        ],
        defaultProjectId: '_local',
      ),
    );
    final queueSession = (await sessions.createSession()).id;
    await _submit(service, queueSession, 'active-a');
    final queued = await service.submit(
      sessionId: queueSession,
      submissionId: 'queued-a',
      revisionId: 'queued-a-r1',
      message: 'queued under A',
      attachments: const [],
      references: const [
        {'type': 'file', 'id': 'a.md'},
      ],
    );
    final stagedB = await service.updateContext(
      sessionId: queueSession,
      expectedRevision: queued.snapshot.revision,
      projectId: 'project-b',
      directory: projectB.path,
      provider: 'claude',
    );
    final before = (await service.snapshot(queueSession)).toJson();
    final messagesBefore = (await messages.getMessages(queueSession)).map((message) => message.toJson()).toList();

    for (final invalid in ['b.md', 'missing.md']) {
      await expectLater(
        service.editQueueItem(
          sessionId: queueSession,
          queueId: queued.submission.queueId!,
          expectedRevision: stagedB.revision,
          revisionId: 'queued-a-$invalid',
          message: 'must remain unchanged',
          attachments: const [],
          references: [
            {'type': 'file', 'id': invalid},
          ],
        ),
        throwsA(isA<ConversationMutationException>().having((error) => error.code, 'code', 'UNKNOWN_REFERENCE')),
      );
      expect((await service.snapshot(queueSession)).toJson(), before);
      expect((await messages.getMessages(queueSession)).map((message) => message.toJson()).toList(), messagesBefore);
    }

    final valid = await service.editQueueItem(
      sessionId: queueSession,
      queueId: queued.submission.queueId!,
      expectedRevision: stagedB.revision,
      revisionId: 'queued-a-r2',
      message: 'still admitted under A',
      attachments: const [],
      references: const [
        {'type': 'file', 'id': 'a.md'},
      ],
    );
    expect(valid.submission.admittedContext?.projectId, '_local');
    expect(valid.submission.references.single['id'], 'a.md');
  });
  test('recovery branches retain the selected project and reject stale references before copying', () async {
    final selected = Directory('${root.path}/selected')..createSync();
    final reference = File('${selected.path}/retained.md')..writeAsStringSync('selected project content');
    final projects = FakeProjectService(
      localProject: Project(
        id: '_local',
        name: 'Default',
        remoteUrl: '',
        localPath: root.path,
        defaultBranch: 'main',
        status: ProjectStatus.ready,
        createdAt: DateTime.utc(2026, 9, 14),
      ),
      projects: [
        Project(
          id: 'selected',
          name: 'Selected',
          remoteUrl: '',
          localPath: selected.path,
          defaultBranch: 'main',
          status: ProjectStatus.ready,
          createdAt: DateTime.utc(2026, 9, 14),
        ),
      ],
    );
    final service = ConversationService(
      sessions: sessions,
      messages: messages,
      turns: turns,
      mutations: SessionMutationCoordinator(),
      projects: projects,
      contextCapabilities: const {'claude': EffectiveContextCapabilities(model: true, effort: true)},
    );
    final source = await sessions.createSession(provider: 'claude');
    final initial = await service.snapshot(source.id);
    await service.updateContext(
      sessionId: source.id,
      expectedRevision: initial.revision,
      projectId: 'selected',
      directory: selected.path,
      provider: 'claude',
      model: 'opus',
      effort: 'high',
    );
    final accepted = await service.submit(
      sessionId: source.id,
      submissionId: 'branch-context',
      revisionId: 'branch-context-r1',
      message: 'Use the retained file',
      attachments: const [],
      references: const [
        {'type': 'file', 'id': 'retained.md'},
      ],
    );
    final complete = accepted.snapshot.put(accepted.submission.copyWith(workState: ConversationWorkState.completed));
    await sessions.updateConversationState(source.id, complete);
    turns.releaseTurn(source.id, accepted.submission.turnId!);
    final originalMessages = File('${root.path}/${source.id}/messages.ndjson').readAsBytesSync();
    for (final kind in [ConversationBranchKind.fork, ConversationBranchKind.edit]) {
      final branch = await service.branchFromMessage(
        sessionId: source.id,
        sourceMessageId: accepted.submission.messageId,
        mutationId: 'branch-${kind.name}',
        kind: kind,
        editedMessage: kind == ConversationBranchKind.edit ? 'Use the same selected file' : null,
      );
      final destinationId = branch['destinationSessionId'] as String;
      final destination = await sessions.getConversationState(destinationId);
      expect(destination.nextContext?.projectId, 'selected');
      expect(destination.nextContext?.referenceRoot, selected.resolveSymbolicLinksSync());
      expect(destination.nextContext?.model, 'opus');
      expect(destination.nextContext?.effort, 'high');
      if (kind == ConversationBranchKind.edit) {
        expect(destination.submissions.single.admittedContext?.projectId, 'selected');
        expect(turns.context?.directory, selected.resolveSymbolicLinksSync());
      }
      expect(File('${root.path}/${source.id}/messages.ndjson').readAsBytesSync(), originalMessages);
    }
    final beforeSessions = (await sessions.listSessions()).map((session) => session.id).toSet();
    final beforeState = (await sessions.getConversationState(source.id)).toJson();
    reference.deleteSync();
    await expectLater(
      service.branchFromMessage(
        sessionId: source.id,
        sourceMessageId: accepted.submission.messageId,
        mutationId: 'stale-file-branch',
        kind: ConversationBranchKind.fork,
      ),
      throwsA(isA<ConversationMutationException>().having((error) => error.code, 'code', 'UNKNOWN_REFERENCE')),
    );
    expect((await sessions.listSessions()).map((session) => session.id).toSet(), beforeSessions);
    expect((await sessions.getConversationState(source.id)).toJson(), beforeState);
  });
}

Future<ConversationAdmission> _submit(ConversationService service, String sessionId, String id) => service.submit(
  sessionId: sessionId,
  submissionId: id,
  revisionId: '$id-r1',
  message: id,
  attachments: const [],
  references: const [],
);

final class _ContextTurns extends FakeTurnManager {
  new(super.messages, super.worker);

  ({String provider, String directory, String? model, String? effort})? context;

  @override
  Future<String> reserveContextTurn(
    String sessionId, {
    required String provider,
    required String directory,
    String? model,
    String? effort,
    required PromptScope promptScope,
    required TurnOrigin origin,
  }) {
    context = (provider: provider, directory: directory, model: model, effort: effort);
    return super.reserveContextTurn(
      sessionId,
      provider: provider,
      directory: directory,
      model: model,
      effort: effort,
      promptScope: promptScope,
      origin: origin,
    );
  }
}
