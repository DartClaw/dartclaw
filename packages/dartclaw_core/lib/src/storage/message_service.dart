import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:dartclaw_models/dartclaw_models.dart';
import 'uuid_validation.dart';

class _WriteOp {
  final Future<void> Function() fn;
  final Completer<void> completer;
  _WriteOp(this.fn) : completer = Completer<void>();
}

/// Manages message persistence with cursor-based crash recovery.
class MessageService {
  static final _log = Logger('MessageService');

  final String baseDir;
  static const _uuid = Uuid();
  final _queue = StreamController<_WriteOp>();
  late final StreamSubscription<void> _queueSub;

  MessageService({required this.baseDir}) {
    _queueSub = _queue.stream
        .asyncMap((op) async {
          try {
            await op.fn();
            op.completer.complete();
          } catch (e, st) {
            op.completer.completeError(e, st);
          }
        })
        .listen((_) {});
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
    final op = _WriteOp(() async {
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
      await ndjsonFile.writeAsString('$line\n', mode: FileMode.append);

      // Inline line count during write to avoid second file read
      final fileContent = await ndjsonFile.readAsString();
      final lineCount = fileContent.isEmpty ? 0 : fileContent.split('\n').where((l) => l.trim().isNotEmpty).length;

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

  Future<List<Message>> getMessages(String sessionId) async {
    if (!isValidUuid(sessionId)) throw ArgumentError('Invalid session ID');
    final ndjsonFile = File(p.join(baseDir, sessionId, 'messages.ndjson'));
    if (!ndjsonFile.existsSync()) return [];

    final lines = await ndjsonFile.readAsLines();
    final messages = <Message>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      try {
        final json = jsonDecode(line) as Map<String, dynamic>;
        // Override cursor with 1-based line number
        json['cursor'] = i + 1;
        messages.add(Message.fromJson(json));
      } catch (e) {
        _log.warning('Malformed NDJSON line ${i + 1} in session $sessionId: $e');
      }
    }
    return messages;
  }

  Future<List<Message>> getMessagesAfterCursor(String sessionId, int cursor) async {
    if (!isValidUuid(sessionId)) throw ArgumentError('Invalid session ID');
    final ndjsonFile = File(p.join(baseDir, sessionId, 'messages.ndjson'));
    if (!ndjsonFile.existsSync()) return [];

    final lines = await ndjsonFile.readAsLines();
    final messages = <Message>[];
    for (var i = cursor; i < lines.length; i++) {
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

  /// Clears all messages for [sessionId] by truncating the NDJSON file.
  Future<void> clearMessages(String sessionId) {
    if (!isValidUuid(sessionId)) throw ArgumentError('Invalid session ID');
    final completer = Completer<void>();
    final op = _WriteOp(() async {
      final ndjsonFile = File(p.join(baseDir, sessionId, 'messages.ndjson'));
      if (ndjsonFile.existsSync()) {
        await ndjsonFile.writeAsString('');
      }
      completer.complete();
    });
    _queue.add(op);
    unawaited(op.completer.future.catchError((Object e, StackTrace st) {
      if (!completer.isCompleted) completer.completeError(e, st);
    }));
    return completer.future;
  }

  Future<void> dispose() async {
    await _queue.close();
    await _queueSub.cancel();
  }
}
