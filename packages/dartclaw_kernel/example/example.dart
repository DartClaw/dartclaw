import 'package:dartclaw_kernel/dartclaw_kernel.dart';

Future<void> main() async {
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
  final guards = GuardChain(guards: [CommandGuard(), NetworkGuard()]);
  final verdict = await guards.evaluateMessageReceived(
    'Please summarize the release notes for me.',
    source: 'example',
    sessionId: session.id,
  );

  print('Session: ${session.title} (${session.type.name})');
  print('Message: ${message.role} -> ${message.content}');
  print('Session key: $sessionKey');
  print('Memory hit: ${result.text} from ${result.source}');
  print('Guard verdict: $verdict');
}
