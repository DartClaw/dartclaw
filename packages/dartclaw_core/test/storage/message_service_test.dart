import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late SessionService sessions;
  late MessageService messages;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_test_messages_');
    sessions = SessionService(baseDir: tempDir.path);
    messages = MessageService(baseDir: tempDir.path);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('insertMessage', () {
    test('inserts and returns message with cursor', () async {
      final session = await sessions.createSession();
      final msg = await messages.insertMessage(sessionId: session.id, role: 'user', content: 'Hello');
      expect(msg.cursor, equals(1));
      expect(msg.role, equals('user'));
      expect(msg.content, equals('Hello'));
      expect(msg.sessionId, equals(session.id));
    });

    test('increments cursor for each message', () async {
      final session = await sessions.createSession();
      final m1 = await messages.insertMessage(sessionId: session.id, role: 'user', content: 'First');
      final m2 = await messages.insertMessage(sessionId: session.id, role: 'assistant', content: 'Second');
      expect(m1.cursor, equals(1));
      expect(m2.cursor, equals(2));
    });

    test('resumes cursor from existing file after service restart', () async {
      final session = await sessions.createSession();
      await messages.insertMessage(sessionId: session.id, role: 'user', content: 'First');
      await messages.insertMessage(sessionId: session.id, role: 'assistant', content: 'Second');
      await messages.dispose();

      messages = MessageService(baseDir: tempDir.path);
      final third = await messages.insertMessage(sessionId: session.id, role: 'user', content: 'Third');

      expect(third.cursor, equals(3));
    });

    test('throws on empty role', () async {
      final session = await sessions.createSession();
      expect(
        () => messages.insertMessage(sessionId: session.id, role: '', content: 'Hi'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws when session dir does not exist', () async {
      expect(
        () => messages.insertMessage(sessionId: '00000000-0000-0000-0000-000000000000', role: 'user', content: 'Hi'),
        throwsA(isA<StateError>()),
      );
    });

    test('supports optional metadata', () async {
      final session = await sessions.createSession();
      final msg = await messages.insertMessage(
        sessionId: session.id,
        role: 'user',
        content: 'Test',
        metadata: '{"key":"val"}',
      );
      expect(msg.metadata, equals('{"key":"val"}'));
    });
  });

  group('getMessages', () {
    test('returns empty list for session with no messages', () async {
      final session = await sessions.createSession();
      final msgs = await messages.getMessages(session.id);
      expect(msgs, isEmpty);
    });

    test('returns messages in order with correct cursors', () async {
      final session = await sessions.createSession();
      await messages.insertMessage(sessionId: session.id, role: 'user', content: 'A');
      await messages.insertMessage(sessionId: session.id, role: 'assistant', content: 'B');

      final msgs = await messages.getMessages(session.id);
      expect(msgs.length, equals(2));
      expect(msgs[0].cursor, equals(1));
      expect(msgs[0].content, equals('A'));
      expect(msgs[1].cursor, equals(2));
      expect(msgs[1].content, equals('B'));
    });

    test('skips malformed NDJSON lines gracefully', () async {
      final session = await sessions.createSession();
      await messages.insertMessage(sessionId: session.id, role: 'user', content: 'Valid');

      // Manually append a malformed line
      final ndjsonFile = File('${tempDir.path}/${session.id}/messages.ndjson');
      await ndjsonFile.writeAsString('not-valid-json\n', mode: FileMode.append);

      await messages.insertMessage(sessionId: session.id, role: 'assistant', content: 'Also valid');

      final msgs = await messages.getMessages(session.id);
      expect(msgs.length, equals(2));
      expect(msgs[0].content, equals('Valid'));
      expect(msgs[1].content, equals('Also valid'));
    });
  });

  group('getMessagesAfterCursor', () {
    test('returns messages after cursor', () async {
      final session = await sessions.createSession();
      await messages.insertMessage(sessionId: session.id, role: 'user', content: 'First');
      await messages.insertMessage(sessionId: session.id, role: 'assistant', content: 'Second');
      await messages.insertMessage(sessionId: session.id, role: 'user', content: 'Third');

      final after1 = await messages.getMessagesAfterCursor(session.id, 1);
      expect(after1.length, equals(2));
      expect(after1[0].content, equals('Second'));
      expect(after1[1].content, equals('Third'));
    });

    test('returns empty when cursor is at end', () async {
      final session = await sessions.createSession();
      await messages.insertMessage(sessionId: session.id, role: 'user', content: 'Only');

      final after = await messages.getMessagesAfterCursor(session.id, 1);
      expect(after, isEmpty);
    });

    test('returns empty for non-existent session', () async {
      final msgs = await messages.getMessagesAfterCursor('00000000-0000-0000-0000-000000000000', 0);
      expect(msgs, isEmpty);
    });
  });

  group('tail windows', () {
    test('getMessagesTail returns the last N messages', () async {
      final session = await sessions.createSession();
      for (var i = 1; i <= 5; i++) {
        await messages.insertMessage(sessionId: session.id, role: 'user', content: 'Message $i');
      }

      final tail = await messages.getMessagesTail(session.id, count: 2);
      expect(tail.map((m) => m.content).toList(), ['Message 4', 'Message 5']);
      expect(tail.map((m) => m.cursor).toList(), [4, 5]);
    });

    test('getMessagesBefore returns the previous window without gaps', () async {
      final session = await sessions.createSession();
      for (var i = 1; i <= 6; i++) {
        await messages.insertMessage(sessionId: session.id, role: 'user', content: 'Message $i');
      }

      final window = await messages.getMessagesBefore(session.id, 6, count: 3);
      expect(window.map((m) => m.content).toList(), ['Message 3', 'Message 4', 'Message 5']);
      expect(window.map((m) => m.cursor).toList(), [3, 4, 5]);
    });

    test('getMessagesTail returns all messages when history is smaller than the window', () async {
      final session = await sessions.createSession();
      await messages.insertMessage(sessionId: session.id, role: 'user', content: 'Only');

      final tail = await messages.getMessagesTail(session.id, count: 200);
      expect(tail, hasLength(1));
      expect(tail.single.content, 'Only');
    });
  });

  group('NDJSON format', () {
    test('each line is valid JSON', () async {
      final session = await sessions.createSession();
      await messages.insertMessage(sessionId: session.id, role: 'user', content: 'Test');

      final ndjsonFile = File('${tempDir.path}/${session.id}/messages.ndjson');
      final lines = await ndjsonFile.readAsLines();
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        expect(() => jsonDecode(line), returnsNormally);
      }
    });
  });

  group('write queue', () {
    test('concurrent inserts are serialized and all succeed', () async {
      final session = await sessions.createSession();
      // Fire multiple inserts concurrently
      final futures = List.generate(
        10,
        (i) => messages.insertMessage(sessionId: session.id, role: 'user', content: 'Msg $i'),
      );
      final results = await Future.wait(futures);

      // All should succeed with unique, sequential cursors
      final cursors = results.map((m) => m.cursor).toSet();
      expect(cursors.length, equals(10));
      expect(results.every((m) => m.content.startsWith('Msg')), isTrue);

      // Verify file has exactly 10 lines
      final msgs = await messages.getMessages(session.id);
      expect(msgs.length, equals(10));
    });

    test('dispose completes pending writes then closes', () async {
      final session = await sessions.createSession();
      // Start some writes, then dispose
      final f1 = messages.insertMessage(sessionId: session.id, role: 'user', content: 'Before dispose');
      await f1; // ensure at least one completes

      await messages.dispose();

      // After dispose, the queue is closed — further adds will throw
      expect(
        () => messages.insertMessage(sessionId: session.id, role: 'user', content: 'After dispose'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('clearMessages', () {
    test('resets cached cursor state', () async {
      final session = await sessions.createSession();
      await messages.insertMessage(sessionId: session.id, role: 'user', content: 'First');
      await messages.insertMessage(sessionId: session.id, role: 'assistant', content: 'Second');

      await messages.clearMessages(session.id);
      final reset = await messages.insertMessage(sessionId: session.id, role: 'user', content: 'After clear');

      expect(reset.cursor, equals(1));
    });
  });
}
