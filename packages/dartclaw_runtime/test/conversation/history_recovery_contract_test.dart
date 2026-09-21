import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_kernel/dartclaw_kernel.dart'
    show AgentDefinition, AgentWorkspace, SessionType, TurnLimitsConfig;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager;
import 'package:dartclaw_runtime/src/concurrency/session_mutation_coordinator.dart';
import 'package:dartclaw_runtime/src/conversation/conversation_service.dart';
import 'package:dartclaw_runtime/src/turn_manager.dart' as runtime;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../session_turn_manager_test_support.dart';

void main() {
  late Directory root;
  late SessionService sessions;
  late MessageService messages;
  late FakeAgentHarness worker;
  late FakeTurnManager turns;
  late ConversationService conversation;
  late String sessionId;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('dartclaw_history_recovery_');
    sessions = SessionService(baseDir: root.path);
    messages = MessageService(baseDir: root.path);
    worker = FakeAgentHarness();
    turns = FakeTurnManager(messages, worker);
    conversation = ConversationService(
      sessions: sessions,
      messages: messages,
      turns: turns,
      mutations: SessionMutationCoordinator(),
    );
    sessionId = (await sessions.createSession()).id;
  });

  tearDown(() async {
    await messages.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('retry links one new attempt while source input context and partial output stay unchanged', () async {
    final source = await conversation.submit(
      sessionId: sessionId,
      submissionId: 'source',
      revisionId: 'source-r1',
      message: 'Original request',
      attachments: const [],
      references: const [
        {'type': 'project', 'id': '_local', 'label': 'Local'},
      ],
    );
    final partial = await messages.insertMessage(sessionId: sessionId, role: 'assistant', content: 'Partial output');
    var state = await sessions.getConversationState(sessionId);
    final failed = source.submission.copyWith(
      workState: ConversationWorkState.failed,
      detail: 'provider failed',
      updatedAt: DateTime.utc(2026, 9, 14),
    );
    state = state.put(failed);
    await sessions.updateConversationState(sessionId, state);
    turns.releaseTurn(sessionId, failed.turnId!);
    final sourceBytes = await File('${root.path}/$sessionId/messages.ndjson').readAsBytes();
    final sourceMessageCount = (await messages.getMessages(sessionId)).length;

    await expectLater(
      conversation.retry(sessionId: sessionId, sourceAttemptId: 'missing-attempt', mutationId: 'missing-retry'),
      throwsA(isA<ConversationMutationException>().having((error) => error.code, 'code', 'ATTEMPT_NOT_FOUND')),
    );
    var completedState = await sessions.getConversationState(sessionId);
    completedState = completedState.put(
      failed.copyWith(workState: ConversationWorkState.completed, updatedAt: DateTime.utc(2026, 9, 14, 1)),
    );
    await sessions.updateConversationState(sessionId, completedState);
    await expectLater(
      conversation.retry(sessionId: sessionId, sourceAttemptId: failed.attemptId!, mutationId: 'success-retry'),
      throwsA(isA<ConversationMutationException>().having((error) => error.code, 'code', 'ATTEMPT_NOT_RETRYABLE')),
    );
    await sessions.updateConversationState(sessionId, completedState.put(failed));

    final staleReference = ConversationService(
      sessions: sessions,
      messages: messages,
      turns: turns,
      mutations: SessionMutationCoordinator(),
      referenceValidator: (_) async =>
          throw const ConversationMutationException(409, 'REFERENCE_UNAVAILABLE', 'Retained reference is unavailable'),
    );
    await expectLater(
      staleReference.retry(sessionId: sessionId, sourceAttemptId: failed.attemptId!, mutationId: 'stale-retry'),
      throwsA(isA<ConversationMutationException>().having((error) => error.code, 'code', 'REFERENCE_UNAVAILABLE')),
    );
    expect(await messages.getMessages(sessionId), hasLength(sourceMessageCount));

    final rawHandler = sessionRoutes(sessions, messages, turns, worker).call;
    final branchAdminHandler = localAdminMiddleware()(rawHandler);
    final sessionsBeforeStaleBranch = (await sessions.listSessions()).map((session) => session.id).toSet();
    final revisionBeforeStaleBranch = (await sessions.getConversationState(sessionId)).revision;
    final missingRevision = await branchAdminHandler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/sessions/$sessionId/messages/${source.submission.messageId}/branch'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({'mutation_id': 'missing-revision-branch', 'kind': 'fork'}),
      ),
    );
    expect(missingRevision.statusCode, 400);
    final staleRevision = await branchAdminHandler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/sessions/$sessionId/messages/${source.submission.messageId}/branch'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({
          'mutation_id': 'stale-revision-branch',
          'kind': 'fork',
          'conversation_revision': revisionBeforeStaleBranch - 1,
        }),
      ),
    );
    expect(staleRevision.statusCode, 409);
    expect((await sessions.listSessions()).map((session) => session.id).toSet(), sessionsBeforeStaleBranch);
    expect((await sessions.getConversationState(sessionId)).findBranch('stale-revision-branch'), isNull);
    final unauthorized = await rawHandler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/sessions/$sessionId/attempts/${failed.attemptId}/retry'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({'mutation_id': 'unauthorized-retry'}),
      ),
    );
    expect(unauthorized.statusCode, 403);
    expect(await messages.getMessages(sessionId), hasLength(sourceMessageCount));

    final beforeRetry = await conversation.snapshot(sessionId);
    final originalContext = source.submission.admittedContext!;
    await conversation.updateContext(
      sessionId: sessionId,
      expectedRevision: beforeRetry.revision,
      projectId: originalContext.projectId,
      directory: originalContext.directory,
      provider: originalContext.provider,
      model: 'next-turn-model',
    );
    final retry = await conversation.retry(
      sessionId: sessionId,
      sourceAttemptId: failed.attemptId!,
      mutationId: 'retry-1',
    );
    final repeated = await conversation.retry(
      sessionId: sessionId,
      sourceAttemptId: failed.attemptId!,
      mutationId: 'retry-1',
    );

    final current = await conversation.snapshot(sessionId);
    expect(retry.submission.message, 'Original request');
    expect(retry.submission.admittedContext?.toJson(), originalContext.toJson());
    expect(current.nextContext?.model, 'next-turn-model');
    expect(retry.submission.attemptId, isNotNull);
    expect(retry.submission.attemptId, isNot(failed.attemptId));
    expect(repeated.submission.messageId, retry.submission.messageId);
    expect(current.findSubmission('source')?.workState, ConversationWorkState.failed);
    expect((await messages.getMessage(sessionId, partial.id))?.content, 'Partial output');
    expect(current.findBranch('retry-1')?.sourceAttemptId, failed.attemptId);
    await expectLater(
      conversation.retry(sessionId: sessionId, sourceAttemptId: 'different-attempt', mutationId: 'retry-1'),
      throwsA(isA<ConversationMutationException>().having((error) => error.code, 'code', 'HISTORY_IDENTITY_CONFLICT')),
    );
    final currentBytes = await File('${root.path}/$sessionId/messages.ndjson').readAsBytes();
    expect(currentBytes.sublist(0, sourceBytes.length), sourceBytes);

    final adminHandler = localAdminMiddleware()(rawHandler);
    final replayResponse = await adminHandler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/sessions/$sessionId/attempts/${failed.attemptId}/retry'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({'mutation_id': 'retry-1'}),
      ),
    );
    expect(replayResponse.statusCode, 200);
    final replayBody = jsonDecode(await replayResponse.readAsString()) as Map<String, dynamic>;
    expect(replayBody['warning'], contains('external tool effects'));
  });

  test('fork copies the visible completed prefix without admitting interleaved queued input', () async {
    final first = await conversation.submit(
      sessionId: sessionId,
      submissionId: 'visible-first',
      revisionId: 'visible-first-r1',
      message: 'Visible input',
      attachments: const [],
      references: const [],
    );
    final queued = await conversation.submit(
      sessionId: sessionId,
      submissionId: 'hidden-queued',
      revisionId: 'hidden-queued-r1',
      message: 'Private unsent queued input',
      attachments: const [],
      references: const [],
    );
    expect(queued.submission.workState, ConversationWorkState.queued);
    final response = await messages.insertMessage(sessionId: sessionId, role: 'assistant', content: 'Visible result');
    final state = await sessions.getConversationState(sessionId);
    await sessions.updateConversationState(
      sessionId,
      state.put(first.submission.copyWith(workState: ConversationWorkState.completed)),
    );
    final sourceBytes = await File('${root.path}/$sessionId/messages.ndjson').readAsBytes();
    final branch = await conversation.branchFromMessage(
      sessionId: sessionId,
      sourceMessageId: response.id,
      mutationId: 'visible-prefix-fork',
      kind: ConversationBranchKind.fork,
    );
    final destinationId = branch['destinationSessionId'] as String;
    expect((await messages.getMessages(destinationId)).map((message) => message.content), [
      'Visible input',
      'Visible result',
    ]);
    expect((await sessions.getConversationState(destinationId)).queue, isEmpty);
    expect(
      (await sessions.getConversationState(sessionId)).findSubmission('hidden-queued')?.workState,
      ConversationWorkState.queued,
    );
    expect(await File('${root.path}/$sessionId/messages.ndjson').readAsBytes(), sourceBytes);
  });

  test('edit and fork preserve source lineage eligibility and explicit destination boundaries', () async {
    const attachmentId = '00000000-0000-4000-8000-000000000101';
    final attachmentBytes = utf8.encode('branch attachment');
    final attachmentDirectory = Directory('${root.path}/$sessionId/attachments')..createSync(recursive: true);
    await File('${attachmentDirectory.path}/$attachmentId.data').writeAsBytes(attachmentBytes);
    await File('${attachmentDirectory.path}/$attachmentId.json').writeAsString(
      jsonEncode({
        'id': attachmentId,
        'filename': 'branch.txt',
        'mediaType': 'text/plain',
        'size': attachmentBytes.length,
        'digest': 'sha256:${sha256.convert(attachmentBytes)}',
        'state': 'ready',
      }),
    );
    final source = await conversation.submit(
      sessionId: sessionId,
      submissionId: 'branch-source',
      revisionId: 'branch-source-r1',
      message: 'Original prompt',
      attachments: const [
        {'id': attachmentId},
      ],
      references: const [],
    );
    var state = await sessions.getConversationState(sessionId);
    state = state.put(
      source.submission.copyWith(workState: ConversationWorkState.completed, updatedAt: DateTime.utc(2026, 9, 14)),
    );
    await sessions.updateConversationState(sessionId, state);
    turns.releaseTurn(sessionId, source.submission.turnId!);
    final answer = await messages.insertMessage(sessionId: sessionId, role: 'assistant', content: 'Original answer');
    final sourceBytes = await File('${root.path}/$sessionId/messages.ndjson').readAsBytes();

    await expectLater(
      conversation.branchFromMessage(
        sessionId: sessionId,
        sourceMessageId: '00000000-0000-4000-8000-000000000099',
        mutationId: 'missing-branch',
        kind: ConversationBranchKind.fork,
      ),
      throwsA(isA<ConversationMutationException>().having((error) => error.code, 'code', 'MESSAGE_NOT_FOUND')),
    );
    var activeState = await sessions.getConversationState(sessionId);
    activeState = activeState.put(
      source.submission.copyWith(workState: ConversationWorkState.running, updatedAt: DateTime.utc(2026, 9, 14, 1)),
    );
    await sessions.updateConversationState(sessionId, activeState);
    await expectLater(
      conversation.branchFromMessage(
        sessionId: sessionId,
        sourceMessageId: answer.id,
        mutationId: 'active-branch',
        kind: ConversationBranchKind.fork,
      ),
      throwsA(isA<ConversationMutationException>().having((error) => error.code, 'code', 'MESSAGE_NOT_COMPLETE')),
    );
    await sessions.updateConversationState(
      sessionId,
      activeState.put(
        source.submission.copyWith(workState: ConversationWorkState.completed, updatedAt: DateTime.utc(2026, 9, 14, 2)),
      ),
    );

    final branchRevision = (await sessions.getConversationState(sessionId)).revision;
    final fork = await conversation.branchFromMessage(
      sessionId: sessionId,
      sourceMessageId: answer.id,
      mutationId: 'fork-1',
      kind: ConversationBranchKind.fork,
      expectedRevision: branchRevision,
    );
    final forkRepeat = await conversation.branchFromMessage(
      sessionId: sessionId,
      sourceMessageId: answer.id,
      mutationId: 'fork-1',
      kind: ConversationBranchKind.fork,
      expectedRevision: branchRevision,
    );
    expect(forkRepeat['destinationSessionId'], fork['destinationSessionId']);
    final sessionsAfterFork = (await sessions.listSessions()).map((session) => session.id).toSet();
    await expectLater(
      conversation.branchFromMessage(
        sessionId: sessionId,
        sourceMessageId: answer.id,
        mutationId: 'stale-new-fork',
        kind: ConversationBranchKind.fork,
        expectedRevision: branchRevision,
      ),
      throwsA(
        isA<ConversationMutationException>().having((error) => error.code, 'code', 'STALE_CONVERSATION_REVISION'),
      ),
    );
    expect((await sessions.listSessions()).map((session) => session.id).toSet(), sessionsAfterFork);
    expect((await sessions.getConversationState(sessionId)).findBranch('stale-new-fork'), isNull);
    await expectLater(
      conversation.branchFromMessage(
        sessionId: sessionId,
        sourceMessageId: source.submission.messageId,
        mutationId: 'fork-1',
        kind: ConversationBranchKind.fork,
      ),
      throwsA(isA<ConversationMutationException>().having((error) => error.code, 'code', 'HISTORY_IDENTITY_CONFLICT')),
    );
    final forkMessages = await messages.getMessages(fork['destinationSessionId']! as String);
    expect(forkMessages.map((message) => message.content), ['Original prompt', 'Original answer']);
    expect(
      await File('${root.path}/${fork['destinationSessionId']}/attachments/$attachmentId.data').readAsBytes(),
      attachmentBytes,
    );

    final edit = await conversation.branchFromMessage(
      sessionId: sessionId,
      sourceMessageId: source.submission.messageId,
      mutationId: 'edit-1',
      kind: ConversationBranchKind.edit,
      editedMessage: 'Edited prompt',
    );
    final editMessages = await messages.getMessages(edit['destinationSessionId']! as String);
    expect(editMessages.last.content, 'Edited prompt');
    expect(await File('${root.path}/$sessionId/messages.ndjson').readAsBytes(), sourceBytes);

    await expectLater(
      conversation.branchFromMessage(
        sessionId: sessionId,
        sourceMessageId: answer.id,
        mutationId: 'edit-invalid',
        kind: ConversationBranchKind.edit,
        editedMessage: 'invalid',
      ),
      throwsA(isA<ConversationMutationException>().having((error) => error.code, 'code', 'EDIT_SOURCE_INVALID')),
    );

    final staleReference = ConversationService(
      sessions: sessions,
      messages: messages,
      turns: turns,
      mutations: SessionMutationCoordinator(),
      referenceValidator: (_) async =>
          throw const ConversationMutationException(409, 'REFERENCE_UNAVAILABLE', 'Retained reference is unavailable'),
    );
    var sourceWithReference = await sessions.getConversationState(sessionId);
    sourceWithReference = sourceWithReference.put(
      source.submission.copyWith(
        workState: ConversationWorkState.completed,
        references: const [
          {'type': 'file', 'id': 'removed.txt', 'label': 'removed.txt'},
        ],
        updatedAt: DateTime.utc(2026, 9, 14, 3),
      ),
    );
    await sessions.updateConversationState(sessionId, sourceWithReference);
    await expectLater(
      staleReference.branchFromMessage(
        sessionId: sessionId,
        sourceMessageId: source.submission.messageId,
        mutationId: 'stale-edit',
        kind: ConversationBranchKind.edit,
        editedMessage: 'Edited stale prompt',
      ),
      throwsA(isA<ConversationMutationException>().having((error) => error.code, 'code', 'UNKNOWN_REFERENCE')),
    );
    await expectLater(
      staleReference.branchFromMessage(
        sessionId: sessionId,
        sourceMessageId: source.submission.messageId,
        mutationId: 'stale-fork',
        kind: ConversationBranchKind.fork,
      ),
      throwsA(isA<ConversationMutationException>().having((error) => error.code, 'code', 'UNKNOWN_REFERENCE')),
    );

    final rawHandler = sessionRoutes(sessions, messages, turns, worker).call;
    final unauthorized = await rawHandler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/sessions/$sessionId/messages/${source.submission.messageId}/branch'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({'mutation_id': 'unauthorized-branch', 'kind': 'fork'}),
      ),
    );
    expect(unauthorized.statusCode, 403);

    for (final type in [
      SessionType.archive,
      SessionType.channel,
      SessionType.cron,
      SessionType.task,
      SessionType.logicalAgent,
    ]) {
      final ineligible = await sessions.createSession(type: type);
      final message = await messages.insertMessage(sessionId: ineligible.id, role: 'user', content: 'Cannot branch');
      await expectLater(
        conversation.branchFromMessage(
          sessionId: ineligible.id,
          sourceMessageId: message.id,
          mutationId: 'ineligible-${type.name}',
          kind: ConversationBranchKind.fork,
        ),
        throwsA(isA<ConversationMutationException>().having((error) => error.code, 'code', 'BRANCH_UNAVAILABLE')),
      );
    }

    final configured = await sessions.createSession(
      provider: 'stale-provider',
      workspace: const AgentWorkspace(agentId: 'research', directory: '/workspace/current'),
    );
    final configuredMessage = await messages.insertMessage(
      sessionId: configured.id,
      role: 'assistant',
      content: 'Configured history',
    );
    final configuredTurns = runtime.TurnManager(
      messages: messages,
      worker: worker,
      behavior: BehaviorFileService(workspaceDir: root.path),
      sessions: sessions,
      turnLimits: const TurnLimitsConfig.defaults(),
      agentDefinitions: (agentId) => const {
        'research': AgentDefinition(
          id: 'research',
          description: 'Research',
          prompt: '',
          provider: 'codex',
          workspace: AgentWorkspace(agentId: 'research', directory: '/workspace/current'),
        ),
      }[agentId],
    );
    final configuredConversation = ConversationService(
      sessions: sessions,
      messages: messages,
      turns: configuredTurns,
      mutations: SessionMutationCoordinator(),
    );
    final configuredFork = await configuredConversation.branchFromMessage(
      sessionId: configured.id,
      sourceMessageId: configuredMessage.id,
      mutationId: 'configured-fork',
      kind: ConversationBranchKind.fork,
    );
    final configuredDestination = await sessions.getSession(configuredFork['destinationSessionId']! as String);
    expect(configuredDestination?.provider, 'codex');
    expect(configuredDestination?.workspace?.agentId, 'research');
    expect(configuredDestination?.workspace?.directory, '/workspace/current');

    final removedTurns = runtime.TurnManager(
      messages: messages,
      worker: worker,
      behavior: BehaviorFileService(workspaceDir: root.path),
      sessions: sessions,
      turnLimits: const TurnLimitsConfig.defaults(),
      agentDefinitions: (agentId) => const <String, AgentDefinition>{}[agentId],
    );
    await expectLater(
      ConversationService(
        sessions: sessions,
        messages: messages,
        turns: removedTurns,
        mutations: SessionMutationCoordinator(),
      ).branchFromMessage(
        sessionId: configured.id,
        sourceMessageId: configuredMessage.id,
        mutationId: 'removed-configured-fork',
        kind: ConversationBranchKind.fork,
      ),
      throwsA(
        isA<ConversationMutationException>().having((error) => error.code, 'code', 'BRANCH_DESTINATION_UNAVAILABLE'),
      ),
    );
    final changedTurns = runtime.TurnManager(
      messages: messages,
      worker: worker,
      behavior: BehaviorFileService(workspaceDir: root.path),
      sessions: sessions,
      turnLimits: const TurnLimitsConfig.defaults(),
      agentDefinitions: (agentId) => const {
        'research': AgentDefinition(
          id: 'research',
          description: 'Research',
          prompt: '',
          provider: 'codex',
          workspace: AgentWorkspace(agentId: 'research', directory: '/workspace/changed'),
        ),
      }[agentId],
    );
    await expectLater(
      ConversationService(
        sessions: sessions,
        messages: messages,
        turns: changedTurns,
        mutations: SessionMutationCoordinator(),
      ).branchFromMessage(
        sessionId: configured.id,
        sourceMessageId: configuredMessage.id,
        mutationId: 'changed-configured-fork',
        kind: ConversationBranchKind.fork,
      ),
      throwsA(
        isA<ConversationMutationException>().having((error) => error.code, 'code', 'BRANCH_DESTINATION_UNAVAILABLE'),
      ),
    );
  });

  test('reserved branch identity resumes one exact destination after partial failure', () async {
    final source = await conversation.submit(
      sessionId: sessionId,
      submissionId: 'crash-source',
      revisionId: 'crash-source-r1',
      message: 'Original',
      attachments: const [],
      references: const [],
    );
    var state = await sessions.getConversationState(sessionId);
    state = state.put(source.submission.copyWith(workState: ConversationWorkState.completed));
    await sessions.updateConversationState(sessionId, state);
    turns.releaseTurn(sessionId, source.submission.turnId!);
    final answer = await messages.insertMessage(sessionId: sessionId, role: 'assistant', content: 'Answer');
    for (final boundary in const [
      'branch_reserved',
      'branch_destination',
      'branch_history_copied',
      'branch_destination_linked',
    ]) {
      final mutationId = 'crash-fork-$boundary';
      final originalRevision = (await sessions.getConversationState(sessionId)).revision;
      var failed = false;
      final interrupted = ConversationService(
        sessions: sessions,
        messages: messages,
        turns: turns,
        mutations: SessionMutationCoordinator(),
        branchFailpoint: (reachedBoundary, _) {
          if (!failed && reachedBoundary == boundary) {
            failed = true;
            throw StateError('simulated crash at $boundary');
          }
        },
      );
      await expectLater(
        interrupted.branchFromMessage(
          sessionId: sessionId,
          sourceMessageId: answer.id,
          mutationId: mutationId,
          kind: ConversationBranchKind.fork,
          expectedRevision: originalRevision,
        ),
        throwsStateError,
      );
      final reserved = (await sessions.getConversationState(sessionId)).findBranch(mutationId)!;
      expect(reserved.completed, isFalse, reason: boundary);
      final recovered = await conversation.branchFromMessage(
        sessionId: sessionId,
        sourceMessageId: answer.id,
        mutationId: mutationId,
        kind: ConversationBranchKind.fork,
        expectedRevision: originalRevision,
      );
      expect(recovered['destinationSessionId'], reserved.destinationSessionId, reason: boundary);
      expect((await sessions.getConversationState(sessionId)).findBranch(mutationId)?.completed, isTrue);
      expect(
        (await sessions.getConversationState(reserved.destinationSessionId)).findBranch(mutationId)?.completed,
        isTrue,
      );
      expect(await messages.getMessages(reserved.destinationSessionId), hasLength(2), reason: boundary);
    }

    final dispatchesBeforeEdit = turns.executeCallCount;
    var failed = false;
    final interruptedEdit = ConversationService(
      sessions: sessions,
      messages: messages,
      turns: turns,
      mutations: SessionMutationCoordinator(),
      branchFailpoint: (boundary, _) {
        if (!failed && boundary == 'branch_edit_admitted') {
          failed = true;
          throw StateError('simulated edit crash');
        }
      },
    );
    await expectLater(
      interruptedEdit.branchFromMessage(
        sessionId: sessionId,
        sourceMessageId: source.submission.messageId,
        mutationId: 'crash-edit',
        kind: ConversationBranchKind.edit,
        editedMessage: 'Edited once',
      ),
      throwsStateError,
    );
    expect(turns.executeCallCount, dispatchesBeforeEdit + 1);
    final reservedEdit = (await sessions.getConversationState(sessionId)).findBranch('crash-edit')!;
    final recoveredEdit = await conversation.branchFromMessage(
      sessionId: sessionId,
      sourceMessageId: source.submission.messageId,
      mutationId: 'crash-edit',
      kind: ConversationBranchKind.edit,
      editedMessage: 'Edited once',
    );
    expect(recoveredEdit['destinationSessionId'], reservedEdit.destinationSessionId);
    final editState = await sessions.getConversationState(reservedEdit.destinationSessionId);
    expect(editState.submissions.where((claim) => claim.submissionId == 'crash-edit'), hasLength(1));
    expect(
      (await messages.getMessages(reservedEdit.destinationSessionId)).where((item) => item.content == 'Edited once'),
      hasLength(1),
    );
    expect(turns.executeCallCount, dispatchesBeforeEdit + 1);
  });
}
