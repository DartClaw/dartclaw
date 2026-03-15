// ignore_for_file: avoid_print

import 'package:dartclaw_models/dartclaw_models.dart';

void main() {
  final session = Session(
    id: 'session-1',
    title: 'Example session',
    type: SessionType.user,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );

  final message = Message(
    cursor: 1,
    id: 'message-1',
    sessionId: session.id,
    role: 'user',
    content: "Summarize today's standup.",
    createdAt: DateTime.now(),
  );

  final sessionKey = SessionKey.dmPerContact(peerId: '+46700000000');
  final result = MemorySearchResult(
    text: 'Remember to follow up on the deployment.',
    source: 'MEMORY.md',
    category: 'ops',
    score: 0.92,
  );

  print('Session: ${session.title} (${session.type.name})');
  print('Message: ${message.role} -> ${message.content}');
  print('Session key: $sessionKey');
  print('Memory hit: ${result.text} from ${result.source}');
}
