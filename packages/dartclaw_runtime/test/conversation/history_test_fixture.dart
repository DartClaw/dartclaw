import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';

final class HistoryTestFixture {
  static const conversationCount = 200;
  static const messageCount = 2000;

  new _({
    required this.root,
    required this.sessions,
    required this.messages,
    required this.sessionIds,
    required this.messageIds,
  });

  final Directory root;
  SessionService sessions;
  MessageService messages;
  final List<String> sessionIds;
  final List<String> messageIds;
  final approvalBarrier = Completer<void>();

  String get selectedSessionId => sessionIds.first;

  static Future<HistoryTestFixture> create() async {
    final root = Directory.systemTemp.createTempSync('dartclaw_history_fixture_');
    final sessions = SessionService(baseDir: root.path);
    final messages = MessageService(baseDir: root.path);
    final sessionIds = <String>[];
    final messageIds = <String>[];
    for (var conversation = 0; conversation < conversationCount; conversation += 1) {
      final session = await sessions.createSession(provider: 'fixture');
      sessionIds.add(session.id);
      for (var index = 0; index < messageCount ~/ conversationCount; index += 1) {
        final message = await messages.insertMessage(
          sessionId: session.id,
          role: index.isEven ? 'user' : 'assistant',
          content: 'Conversation $conversation message $index',
        );
        messageIds.add(message.id);
      }
    }
    return HistoryTestFixture._(
      root: root,
      sessions: sessions,
      messages: messages,
      sessionIds: List.unmodifiable(sessionIds),
      messageIds: List.unmodifiable(messageIds),
    );
  }

  Future<void> recordToolState(ConversationRecordState state) async {
    final now = DateTime.utc(2026, 9, 14, 12);
    final current = await sessions.getConversationState(selectedSessionId);
    await sessions.updateConversationState(
      selectedSessionId,
      current.putRecord(
        ConversationDisplayRecord(
          id: 'tool-1',
          attemptId: 'attempt-1',
          turnId: 'turn-1',
          kind: ConversationRecordKind.tool,
          state: state,
          label: 'shell',
          createdAt: now,
          updatedAt: now,
        ),
      ),
    );
  }

  Future<void> restart() async {
    await messages.dispose();
    sessions = SessionService(baseDir: root.path);
    messages = MessageService(baseDir: root.path);
  }

  Future<void> dispose() async {
    await messages.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}
