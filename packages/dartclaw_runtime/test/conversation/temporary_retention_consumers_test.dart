import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

void main() {
  test('temporary messages remain readable while durable projection and files stay empty', () async {
    final root = Directory.systemTemp.createTempSync('temporary-consumers-');
    addTearDown(() => root.deleteSync(recursive: true));
    final sessions = SessionService(baseDir: root.path);
    final messages = MessageService(baseDir: root.path, retentionForSession: sessions.retentionFor);
    final session = await sessions.createSession(retention: ConversationRetention.process);
    final message = await messages.insertMessage(sessionId: session.id, role: 'user', content: 'consumer marker');
    expect((await messages.getMessages(session.id)).single.id, message.id);
    expect(
      ConversationIndexProjection.document(message: message, sessionType: session.type, retention: session.retention),
      isNull,
    );
    expect(root.listSync(recursive: true), isEmpty);
  });
}
