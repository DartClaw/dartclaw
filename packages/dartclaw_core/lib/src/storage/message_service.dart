import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'atomic_write.dart';
import 'uuid_validation.dart';
import 'write_op.dart';

/// Receives synchronous notifications after authoritative message mutations.
abstract interface class MessageServiceObserver {
  /// Called after a message line has been durably appended.
  void onMessageAppended(Message message);

  /// Called after a session's message file has been truncated.
  void onMessagesCleared(String sessionId, List<String> messageIds);
}

/// Resolves the persistence boundary owned by the session authority.
typedef SessionRetentionResolver = Future<ConversationRetention?> Function(String sessionId);

/// Manages message persistence with cursor-based crash recovery.
class MessageService {
  static final _log = Logger('MessageService');

  final String baseDir;
  static const _uuid = Uuid();
  final Map<String, int> _lineCounts = {};
  late final BoundedWriteQueue _queue;
  final List<MessageServiceObserver> _observers = [];
  final SessionRetentionResolver? retentionForSession;
  final int maxProcessMessagesPerSession;
  final Map<String, List<Message>> _processMessages = {};

  new({
    required this.baseDir,
    MessageServiceObserver? observer,
    this.retentionForSession,
    this.maxProcessMessagesPerSession = 500,
  }) {
    if (observer != null) _observers.add(observer);
    _queue = BoundedWriteQueue(logger: _log);
  }

  /// Registers a message mutation observer once.
  void registerObserver(MessageServiceObserver observer) {
    if (_observers.contains(observer)) throw StateError('Message service observer is already registered');
    _observers.add(observer);
  }

  Future<Message> insertMessage({
    required String sessionId,
    required String role,
    required String content,
    String? metadata,
  }) async {
    if (!isValidUuid(sessionId)) throw ArgumentError('Invalid session ID');
    if (role.trim().isEmpty) throw ArgumentError('role must not be empty');

    if (await _retention(sessionId) == ConversationRetention.process) {
      final entries = _processMessages.putIfAbsent(sessionId, () => []);
      return _appendProcessMessage(
        entries,
        messageId: _uuid.v4(),
        sessionId: sessionId,
        role: role,
        content: content,
        metadata: metadata,
        createdAt: DateTime.now(),
      );
    }

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
    unawaited(
      op.completer.future.catchError((Object e, StackTrace st) {
        if (!completer.isCompleted) completer.completeError(e, st);
      }),
    );
    return completer.future.then((message) {
      _notify((observer) => observer.onMessageAppended(message));
      return message;
    });
  }

  /// Appends a message under a caller-supplied stable identity, or returns the
  /// matching durable row when recovery repeats the same write.
  Future<Message> insertMessageWithIdentity({
    required String sessionId,
    required String messageId,
    required String role,
    required String content,
    String? metadata,
    required DateTime createdAt,
    bool notifyObserver = true,
  }) async {
    if (!isValidUuid(sessionId)) throw ArgumentError('Invalid session ID');
    if (!isValidUuid(messageId)) throw ArgumentError('Invalid message ID');
    if (role.trim().isEmpty) throw ArgumentError('role must not be empty');

    if (await _retention(sessionId) == ConversationRetention.process) {
      final entries = _processMessages.putIfAbsent(sessionId, () => []);
      for (final existing in entries) {
        if (existing.id != messageId) continue;
        if (existing.role != role || existing.content != content || existing.metadata != metadata) {
          throw MessageIdentityConflict(messageId);
        }
        return existing;
      }
      return _appendProcessMessage(
        entries,
        messageId: messageId,
        sessionId: sessionId,
        role: role,
        content: content,
        metadata: metadata,
        createdAt: createdAt,
        notifyObserver: notifyObserver,
      );
    }

    Message? inserted;
    var appended = false;
    final op = WriteOp(() async {
      final sessionDir = Directory(p.join(baseDir, sessionId));
      if (!sessionDir.existsSync()) throw StateError('Session directory does not exist: $sessionId');
      final file = File(p.join(sessionDir.path, 'messages.ndjson'));
      final lines = await _repairTornFinalLine(file);
      for (var index = 0; index < lines.length; index++) {
        final line = lines[index].trim();
        if (line.isEmpty) continue;
        final json = jsonDecode(line) as Map<String, dynamic>;
        if (json['id'] != messageId) continue;
        json['cursor'] = index + 1;
        final existing = Message.fromJson(json);
        if (existing.sessionId != sessionId ||
            existing.role != role ||
            existing.content != content ||
            existing.metadata != metadata) {
          throw MessageIdentityConflict(messageId);
        }
        inserted = existing;
        _lineCounts[sessionId] = lines.where((item) => item.trim().isNotEmpty).length;
        return;
      }

      final cursor = lines.where((item) => item.trim().isNotEmpty).length + 1;
      final message = Message(
        cursor: cursor,
        id: messageId,
        sessionId: sessionId,
        role: role,
        content: content,
        metadata: metadata,
        createdAt: createdAt,
      );
      await file.writeAsString('${jsonEncode(message.toJson())}\n', mode: FileMode.append);
      _lineCounts[sessionId] = cursor;
      inserted = message;
      appended = true;
    });
    _queue.add(op);
    return op.completer.future.then((_) {
      final message = inserted!;
      if (appended && notifyObserver) _notify((observer) => observer.onMessageAppended(message));
      return message;
    });
  }

  /// Publishes a previously inserted stable message to the configured observer.
  void publishMessage(Message message) => _notify((observer) => observer.onMessageAppended(message));

  /// Rewrites one queued user message while preserving its stable identity and cursor.
  Future<Message> replaceMessageWithIdentity({
    required String sessionId,
    required String messageId,
    required String content,
    String? metadata,
  }) async {
    if (await _retention(sessionId) == ConversationRetention.process) {
      final entries = _processMessages[sessionId] ?? const [];
      final index = entries.indexWhere((message) => message.id == messageId);
      if (index < 0) throw StateError('Message does not exist: $messageId');
      final updated = _replaceMessageContent(entries[index], content: content, metadata: metadata);
      entries[index] = updated;
      return updated;
    }
    Message? replaced;
    final op = WriteOp(() async {
      final file = _messagesFile(sessionId);
      final lines = await _repairTornFinalLine(file);
      for (var index = 0; index < lines.length; index++) {
        final line = lines[index].trim();
        if (line.isEmpty) continue;
        final json = jsonDecode(line) as Map<String, dynamic>;
        if (json['id'] != messageId) continue;
        json['cursor'] = index + 1;
        final existing = Message.fromJson(json);
        final updated = _replaceMessageContent(existing, content: content, metadata: metadata);
        lines[index] = jsonEncode(updated.toJson());
        await atomicWriteBytes(file, utf8.encode('${lines.join('\n')}\n'));
        replaced = updated;
        return;
      }
      throw StateError('Message does not exist: $messageId');
    });
    _queue.add(op);
    return op.completer.future.then((_) => replaced!);
  }

  Future<List<Message>> getMessages(String sessionId) => _readMessagesForward(sessionId, startLine: 1);

  Future<List<Message>> getMessagesAfterCursor(String sessionId, int cursor) =>
      _readMessagesForward(sessionId, startLine: cursor + 1);

  Future<List<Message>> _readMessagesForward(String sessionId, {required int startLine}) async {
    if (await _retention(sessionId) == ConversationRetention.process) {
      return List.unmodifiable((_processMessages[sessionId] ?? const []).skip(startLine - 1));
    }
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
    if (count <= 0) return [];
    if (await _retention(sessionId) == ConversationRetention.process) {
      final entries = _processMessages[sessionId] ?? const [];
      return List.unmodifiable(entries.skip(entries.length > count ? entries.length - count : 0));
    }
    final ndjsonFile = _messagesFile(sessionId);

    if (!ndjsonFile.existsSync()) return [];

    final lines = await ndjsonFile.readAsLines();
    return _collectMessagesBackwards(sessionId, lines, startIndex: lines.length - 1, count: count);
  }

  Future<List<Message>> getMessagesBefore(String sessionId, int cursor, {int count = 50}) async {
    if (cursor <= 1 || count <= 0) return [];
    if (await _retention(sessionId) == ConversationRetention.process) {
      final entries = (_processMessages[sessionId] ?? const []).where((message) => message.cursor < cursor).toList();
      return List.unmodifiable(entries.skip(entries.length > count ? entries.length - count : 0));
    }
    final ndjsonFile = _messagesFile(sessionId);

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

  Future<List<Message>> getMessagesTailWhere(
    String sessionId, {
    required bool Function(Message message) include,
    int count = 200,
  }) async {
    if (count <= 0) return const [];
    final result = <Message>[];
    await for (final message in _streamMessages(sessionId)) {
      if (!include(message)) continue;
      result.add(message);
      if (result.length > count) result.removeAt(0);
    }
    return List.unmodifiable(result);
  }

  Future<List<Message>> getMessagesBeforeWhere(
    String sessionId,
    int cursor, {
    required bool Function(Message message) include,
    int count = 100,
  }) async {
    if (cursor <= 1 || count <= 0) return const [];
    final result = <Message>[];
    await for (final message in _streamMessages(sessionId)) {
      if (message.cursor >= cursor) break;
      if (!include(message)) continue;
      result.add(message);
      if (result.length > count) result.removeAt(0);
    }
    return List.unmodifiable(result);
  }

  Future<List<Message>> getMessagesAroundWhere(
    String sessionId,
    String messageId, {
    required bool Function(Message message) include,
    int before = 50,
    int after = 49,
  }) async {
    if (!isValidUuid(messageId)) throw ArgumentError('Invalid message ID');
    if (before < 0 || after < 0) throw ArgumentError('Window sizes must not be negative');
    final leading = <Message>[];
    final result = <Message>[];
    var found = false;
    await for (final message in _streamMessages(sessionId)) {
      if (!found) {
        if (message.id == messageId) {
          if (!include(message)) return const [];
          result
            ..addAll(leading)
            ..add(message);
          found = true;
        } else if (include(message)) {
          leading.add(message);
          if (leading.length > before) leading.removeAt(0);
        }
        continue;
      }
      if (include(message)) result.add(message);
      if (result.length >= leading.length + 1 + after) break;
    }
    return found ? List.unmodifiable(result) : const [];
  }

  Future<Message?> getMessage(String sessionId, String messageId) async {
    if (!isValidUuid(messageId)) throw ArgumentError('Invalid message ID');
    for (final message in await _readMessagesForward(sessionId, startLine: 1)) {
      if (message.id == messageId) return message;
    }
    return null;
  }

  Stream<Message> _streamMessages(String sessionId) async* {
    if (await _retention(sessionId) == ConversationRetention.process) {
      yield* Stream.fromIterable(_processMessages[sessionId] ?? const []);
      return;
    }
    final file = _messagesFile(sessionId);
    if (!file.existsSync()) return;
    var cursor = 0;
    await for (final line in file.openRead().transform(utf8.decoder).transform(const LineSplitter())) {
      cursor += 1;
      if (line.trim().isEmpty) continue;
      try {
        final json = jsonDecode(line) as Map<String, dynamic>;
        json['cursor'] = cursor;
        yield Message.fromJson(json);
      } catch (error) {
        _log.warning('Malformed NDJSON line $cursor in session $sessionId: $error');
      }
    }
  }

  /// Clears all messages for [sessionId] by truncating the NDJSON file.
  Future<void> clearMessages(String sessionId) async {
    if (await _retention(sessionId) == ConversationRetention.process) {
      final cleared = _processMessages.remove(sessionId) ?? const [];
      _notify((observer) => observer.onMessagesCleared(sessionId, cleared.map((message) => message.id).toList()));
      return;
    }
    final ndjsonFile = _messagesFile(sessionId);
    var clearedIds = const <String>[];
    final op = WriteOp(() async {
      if (ndjsonFile.existsSync()) {
        clearedIds = (await _readMessagesForward(
          sessionId,
          startLine: 1,
        )).map((message) => message.id).toList(growable: false);
        await ndjsonFile.writeAsString('');
      }
      _lineCounts.remove(sessionId);
    });
    _queue.add(op);
    return op.completer.future.then((_) {
      _notify((observer) => observer.onMessagesCleared(sessionId, clearedIds));
    });
  }

  Future<ConversationRetention> _retention(String sessionId) async {
    final resolver = retentionForSession;
    if (resolver == null) return ConversationRetention.durable;
    final retention = await resolver(sessionId);
    if (retention == null) throw StateError('Session does not exist: $sessionId');
    return retention;
  }

  Message _appendProcessMessage(
    List<Message> entries, {
    required String messageId,
    required String sessionId,
    required String role,
    required String content,
    required String? metadata,
    required DateTime createdAt,
    bool notifyObserver = true,
  }) {
    if (entries.length >= maxProcessMessagesPerSession) throw StateError('Temporary message capacity reached');
    final message = Message(
      cursor: entries.length + 1,
      id: messageId,
      sessionId: sessionId,
      role: role,
      content: content,
      metadata: metadata,
      createdAt: createdAt,
    );
    entries.add(message);
    if (notifyObserver) _notify((observer) => observer.onMessageAppended(message));
    return message;
  }

  Message _replaceMessageContent(Message existing, {required String content, required String? metadata}) => Message(
    cursor: existing.cursor,
    id: existing.id,
    sessionId: existing.sessionId,
    role: existing.role,
    content: content,
    metadata: metadata,
    createdAt: existing.createdAt,
  );

  Future<void> dispose() async {
    await _queue.close();
  }

  void _notify(void Function(MessageServiceObserver observer) notification) {
    for (final observer in _observers) {
      try {
        notification(observer);
      } catch (error, stackTrace) {
        _log.warning('Message observer failed: $error', error, stackTrace);
      }
    }
  }

  Future<int> _countLines(File file) async {
    if (!file.existsSync()) return 0;
    final lines = await file.readAsLines();
    return lines.where((line) => line.trim().isNotEmpty).length;
  }

  Future<List<String>> _repairTornFinalLine(File file) async {
    if (!file.existsSync()) return [];
    final source = await file.readAsString();
    if (source.isEmpty) return [];
    final lines = source.split('\n');
    if (source.endsWith('\n')) {
      lines.removeLast();
      return lines;
    }
    final finalLine = lines.removeLast();
    try {
      jsonDecode(finalLine);
      await file.writeAsString('$source\n');
      lines.add(finalLine);
    } on FormatException {
      final repaired = lines.isEmpty ? '' : '${lines.join('\n')}\n';
      await file.writeAsString(repaired);
      _log.warning('Removed a torn final NDJSON line in ${file.path}');
    }
    return lines;
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

/// A stable message identity already names different durable content.
final class MessageIdentityConflict implements Exception {
  final String messageId;

  const new(this.messageId);

  @override
  String toString() => 'MessageIdentityConflict: $messageId';
}
