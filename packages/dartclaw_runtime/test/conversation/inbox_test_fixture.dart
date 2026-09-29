import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/src/concurrency/session_mutation_coordinator.dart';
import 'package:dartclaw_runtime/src/conversation/inbox_service.dart';

final class InboxTestFixture {
  static const conversationCount = 200;
  static final now = DateTime.utc(2026, 9, 30, 12);

  new _(this.root, this.sessions, this.messages, this.mutations, this.inbox, this.sessionIds);

  final Directory root;
  final SessionService sessions;
  final MessageService messages;
  final SessionMutationCoordinator mutations;
  final ConversationInboxService inbox;
  final List<String> sessionIds;

  static Future<InboxTestFixture> create({int count = 10, int autoSettleIdleDays = 0}) async {
    final root = Directory.systemTemp.createTempSync('dartclaw_inbox_fixture_');
    final sessions = SessionService(baseDir: root.path);
    final messages = MessageService(baseDir: root.path);
    final ids = <String>[];
    for (var index = 0; index < count; index += 1) {
      final id = '00000000-0000-4000-8000-${index.toString().padLeft(12, '0')}';
      await sessions.createSessionWithIdentity(id: id, provider: 'fixture');
      await sessions.updateTitle(id, 'Conversation ${index.toString().padLeft(3, '0')}');
      ids.add(id);
    }
    final mutations = SessionMutationCoordinator();
    final inbox = ConversationInboxService(
      sessions: sessions,
      messages: messages,
      mutations: mutations,
      clock: () => now,
      autoSettleIdleDays: autoSettleIdleDays,
    );
    return InboxTestFixture._(root, sessions, messages, mutations, inbox, List.unmodifiable(ids));
  }

  Future<int> makeEligible(String sessionId) async {
    final message = await messages.insertMessageWithIdentity(
      sessionId: sessionId,
      messageId: sessionId,
      role: 'assistant',
      content: 'Done',
      createdAt: now.subtract(const Duration(days: 2)),
    );
    final current = await sessions.getConversationState(sessionId);
    final completed = current.put(
      ConversationSubmissionClaim(
        submissionId: 'submission-$sessionId',
        revisionId: 'revision-$sessionId',
        messageId: message.id,
        attemptId: 'attempt-$sessionId',
        payloadDigest: 'fixture',
        message: 'Done',
        commitState: SubmissionCommitState.committed,
        workState: ConversationWorkState.completed,
        turnId: 'turn-$sessionId',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await sessions.updateConversationState(sessionId, completed);
    final read = await inbox.advanceRead(
      sessionId: sessionId,
      expectedRevision: completed.revision,
      visibleMessageId: message.id,
      foreground: true,
    );
    final attention = await inbox.markAttentionRead(
      sessionId: sessionId,
      expectedRevision: read.revision,
      eventId: 'submission:submission-$sessionId',
    );
    return attention.revision;
  }

  Future<void> dispose() async {
    await inbox.dispose();
    await messages.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}
