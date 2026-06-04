// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:dartclaw/dartclaw.dart';
import 'package:path/path.dart' as p;

const _sessionKey = 'sdk-example:multi-turn-cli';

Future<void> main(List<String> args) async {
  final store = _ConversationStore(baseDir: p.join(Directory.current.path, '.dartclaw-sdk-example', 'sessions'));
  final session = await store.session();

  if (args.contains('--demo')) {
    await _runDemo(store, session.id);
    return;
  }

  final onceIndex = args.indexOf('--once');
  if (onceIndex != -1) {
    final prompt = args.skip(onceIndex + 1).join(' ').trim();
    if (prompt.isEmpty) {
      stderr.writeln('usage: dart run multi_turn_cli --once "your prompt"');
      exitCode = 64;
      return;
    }
    await _runLiveTurn(store, session.id, prompt);
    return;
  }

  if (!stdin.hasTerminal) {
    stderr.writeln('No terminal detected. Use --demo or --once "prompt".');
    exitCode = 64;
    return;
  }

  print('Multi-turn DartClaw CLI. Type "exit" to stop.');
  while (true) {
    stdout.write('you> ');
    final prompt = stdin.readLineSync()?.trim();
    if (prompt == null || prompt == 'exit') break;
    if (prompt.isEmpty) continue;
    await _runLiveTurn(store, session.id, prompt);
  }
}

Future<void> _runDemo(_ConversationStore store, String sessionId) async {
  await store.clear(sessionId);
  await store.recordUser(sessionId, 'Remember that SDK examples use local dependency overrides.');
  await store.recordAssistant(sessionId, 'Noted. Local overrides keep the examples runnable before publication.');
  await store.recordUser(sessionId, 'What did I ask you to remember?');
  await store.recordAssistant(sessionId, 'SDK examples use local dependency overrides.');

  final history = await store.history(sessionId);
  for (final message in history) {
    print('${message.role}> ${message.content}');
  }
  print('turns=${history.length}');
}

Future<void> _runLiveTurn(_ConversationStore store, String sessionId, String prompt) async {
  await store.recordUser(sessionId, prompt);
  final history = await store.history(sessionId);
  final harness = ClaudeCodeHarness(cwd: Directory.current.path);
  await harness.start();

  final assistant = StringBuffer();
  final sub = harness.events.listen((event) {
    if (event case DeltaEvent(:final text)) {
      assistant.write(text);
      stdout.write(text);
    }
  });

  try {
    await harness.turn(
      sessionId: sessionId,
      messages: [
        for (final message in history) {'role': message.role, 'content': message.content},
      ],
      systemPrompt: 'You are a concise assistant in a small SDK multi-turn CLI example.',
    );
    stdout.writeln();
    final content = assistant.toString().trim();
    if (content.isNotEmpty) await store.recordAssistant(sessionId, content);
  } finally {
    await sub.cancel();
    await harness.dispose();
  }
}

final class _ConversationStore {
  _ConversationStore({required String baseDir})
    : _sessions = SessionService(baseDir: baseDir),
      _messages = MessageService(baseDir: baseDir);

  final SessionService _sessions;
  final MessageService _messages;

  Future<Session> session() => _sessions.getOrCreateByKey(_sessionKey);

  Future<void> recordUser(String sessionId, String content) async {
    await _messages.insertMessage(sessionId: sessionId, role: 'user', content: content);
  }

  Future<void> recordAssistant(String sessionId, String content) async {
    await _messages.insertMessage(sessionId: sessionId, role: 'assistant', content: content);
  }

  Future<void> clear(String sessionId) => _messages.clearMessages(sessionId);

  Future<List<Message>> history(String sessionId) => _messages.getMessages(sessionId);
}
