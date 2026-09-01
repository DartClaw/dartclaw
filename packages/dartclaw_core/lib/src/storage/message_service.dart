import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'uuid_validation.dart';
import 'write_op.dart';

/// Manages message persistence with cursor-based crash recovery.
class MessageService {
  static final _log = Logger('MessageService');

  final String baseDir;
  static const _uuid = Uuid();
  final Map<String, int> _lineCounts = {};
  late final BoundedWriteQueue _queue;

  new({required this.baseDir}) {
    _queue = BoundedWriteQueue(logger: _log);
  }

  Future<Message> insertMessage({
    required String sessionId,
    required String role,
    required String content,
    String? metadata,
  }) {
    if (!isValidUuid(sessionId)) throw ArgumentError('Invalid session ID');
    if (role.trim().isEmpty) throw ArgumentError('role must not be empty');

    final completer = Completer<Message>();
    final op = WriteOp(() async {
      // FK check: session dir must exist
      final sessionDir = Directory(p.join(baseDir, sessionId));
      if (!sessionDir.existsSync()) {
        throw StateError('Session directory does not exist: $sessionId');
      }

      final id = _uuid.v4();
      final now = DateTime.now();
      final ndjsonFile = File(p.join(sessionDir.path, 'messages.ndjson'));

      final message = Message(
        cursor: 0, // placeholder, assigned after append
        id: id,
        sessionId: sessionId,
        role: role,
        content: content,
        metadata: metadata,
        createdAt: now,
      );

      final line = jsonEncode(message.toJson());
      final currentCount = _lineCounts[sessionId] ?? await _countLines(ndjsonFile);
      await ndjsonFile.writeAsString('$line\n', mode: FileMode.append);
      final lineCount = currentCount + 1;
      _lineCounts[sessionId] = lineCount;

      completer.complete(
        Message(
          cursor: lineCount,
          id: id,
          sessionId: sessionId,
          role: role,
          content: content,
          metadata: metadata,
          createdAt: now,
        ),
      );
    });
    _queue.add(op);
    op.completer.future.catchError((Object e, StackTrace st) {
      if (!completer.isCompleted) completer.completeError(e, st);
    });
    return completer.future;
  }

  Future<List<Message>> getMessages(String sessionId) => _readMessagesForward(sessionId, startLine: 1);

  Future<List<Message>> getMessagesAfterCursor(String sessionId, int cursor) =>
      _readMessagesForward(sessionId, startLine: cursor + 1);

  Future<List<Message>> _readMessagesForward(String sessionId, {required int startLine}) async {
    final ndjsonFile = _messagesFile(sessionId);
    if (!ndjsonFile.existsSync()) return [];

    final lines = await ndjsonFile.readAsLines();
    final messages = <Message>[];
    for (var i = startLine - 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      try {
        final json = jsonDecode(line) as Map<String, dynamic>;
        json['cursor'] = i + 1;
        messages.add(Message.fromJson(json));
      } catch (e) {
        _log.warning('Malformed NDJSON line ${i + 1} in session $sessionId: $e');
      }
    }
    return messages;
  }

  Future<List<Message>> getMessagesTail(String sessionId, {int count = 200}) async {
    final ndjsonFile = _messagesFile(sessionId);
    if (count <= 0) return [];

    if (!ndjsonFile.existsSync()) return [];

    final lines = await ndjsonFile.readAsLines();
    return _collectMessagesBackwards(sessionId, lines, startIndex: lines.length - 1, count: count);
  }

  Future<List<Message>> getMessagesBefore(String sessionId, int cursor, {int count = 50}) async {
    final ndjsonFile = _messagesFile(sessionId);
    if (cursor <= 1 || count <= 0) return [];

    if (!ndjsonFile.existsSync()) return [];

    final lines = await ndjsonFile.readAsLines();
    final startIndex = cursor - 2;
    if (startIndex < 0) return [];

    return _collectMessagesBackwards(
      sessionId,
      lines,
      startIndex: startIndex < lines.length ? startIndex : lines.length - 1,
      count: count,
    );
  }

  /// Clears all messages for [sessionId] by truncating the NDJSON file.
  Future<void> clearMessages(String sessionId) {
    final ndjsonFile = _messagesFile(sessionId);
    final op = WriteOp(() async {
      if (ndjsonFile.existsSync()) {
        await ndjsonFile.writeAsString('');
      }
      _lineCounts.remove(sessionId);
    });
    _queue.add(op);
    return op.completer.future;
  }

  Future<void> dispose() async {
    await _queue.close();
  }

  Future<int> _countLines(File file) async {
    if (!file.existsSync()) return 0;
    final lines = await file.readAsLines();
    return lines.where((line) => line.trim().isNotEmpty).length;
  }

  File _messagesFile(String sessionId) {
    if (!isValidUuid(sessionId)) throw ArgumentError('Invalid session ID');
    return File(p.join(baseDir, sessionId, 'messages.ndjson'));
  }

  List<Message> _collectMessagesBackwards(
    String sessionId,
    List<String> lines, {
    required int startIndex,
    required int count,
  }) {
    final messages = <Message>[];
    for (var i = startIndex; i >= 0 && messages.length < count; i--) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      try {
        final json = jsonDecode(line) as Map<String, dynamic>;
        json['cursor'] = i + 1;
        messages.add(Message.fromJson(json));
      } catch (e) {
        _log.warning('Malformed NDJSON line ${i + 1} in session $sessionId: $e');
      }
    }
    return messages.reversed.toList();
  }
}
