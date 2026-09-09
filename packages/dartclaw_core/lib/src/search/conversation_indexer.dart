import 'dart:async';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:logging/logging.dart';

import '../storage/message_service.dart';
import '../storage/session_service.dart';
import 'conversation_index_projection.dart';

/// Projects message and session mutations into the derived conversation index.
final class ConversationIndexer implements MessageServiceObserver, SessionServiceObserver {
  static final _log = Logger('ConversationIndexer');

  /// Creates an indexer over the authoritative session and message stores.
  new({
    required this.index,
    required this.sessions,
    required this.messages,
    this.synchronizeVectors,
    this.userId = 'owner',
  });

  /// Derived conversation index.
  final FullTextIndex index;

  /// Session metadata authority.
  final SessionService sessions;

  /// Message NDJSON authority.
  final MessageService messages;

  /// Reconciles vectors after a matching lexical mutation succeeds.
  final Future<void> Function(Iterable<String> documentIds, {required String userId})? synchronizeVectors;

  /// Instance owner scope used for every index operation.
  final String userId;

  Future<void> _pending = Future.value();

  /// Completes after every queued index mutation has settled.
  Future<void> get idle => _pending;

  @override
  void onMessageAppended(Message message) {
    _enqueue(() async {
      final session = await sessions.getSession(message.sessionId);
      if (session == null) return;
      final document = ConversationIndexProjection.document(message: message, sessionType: session.type);
      if (document == null) return;
      await index.upsert([document], userId: userId);
      await synchronizeVectors?.call([document.id], userId: userId);
    });
  }

  @override
  void onMessagesCleared(String sessionId, List<String> messageIds) {
    _enqueue(() async {
      await index.delete(messageIds, userId: userId);
      await synchronizeVectors?.call(messageIds, userId: userId);
    });
  }

  @override
  void onSessionDeleting(String sessionId) {
    _enqueue(() => _deleteSession(sessionId));
  }

  @override
  void onSessionTypeChanged(String sessionId, SessionType oldType, SessionType newType) {
    if (oldType.isChatFacing == newType.isChatFacing) return;
    if (!newType.isChatFacing) {
      _enqueue(() => _deleteSession(sessionId));
      return;
    }
    _enqueue(() async {
      final stored = await messages.getMessages(sessionId);
      final documents = stored
          .map((message) => ConversationIndexProjection.document(message: message, sessionType: newType))
          .whereType<SearchDocument>()
          .toList(growable: false);
      if (documents.isEmpty) return;
      await index.upsert(documents, userId: userId);
      await synchronizeVectors?.call(documents.map((document) => document.id), userId: userId);
    });
  }

  Future<void> _deleteSession(String sessionId) async {
    final chunkCount = await index.count(userId: userId);
    if (chunkCount == 0) return;
    final rows = await index.listRecent(userId: userId, limit: chunkCount);
    final ids = rows.where((row) => row.metadata['session_id'] == sessionId).map((row) => row.id).toSet();
    await index.delete(ids, userId: userId);
    await synchronizeVectors?.call(ids, userId: userId);
  }

  void _enqueue(Future<void> Function() mutation) {
    _pending = _pending.then((_) async {
      try {
        await mutation();
      } catch (error, stackTrace) {
        _log.warning('Conversation indexing failed: $error', error, stackTrace);
      }
    });
  }
}
