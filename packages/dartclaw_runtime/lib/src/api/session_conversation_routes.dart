import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show SessionType;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/request_auth_context.dart';
import '../conversation/conversation_service.dart';
import '../turn_manager.dart' show TurnManager;
import 'api_helpers.dart';

void registerSessionConversationRoutes(
  Router router, {
  required SessionService sessions,
  required ConversationService conversation,
  required TurnManager turns,
}) {
  router.get('/api/sessions/<id>/conversation-state', (Request request, String id) async {
    if (!requestHasAdminAccess(request)) {
      return errorResponse(403, 'CONVERSATION_FORBIDDEN', 'Conversation state requires operator/admin access');
    }
    if (await sessions.getSession(id) == null) {
      return errorResponse(404, 'SESSION_NOT_FOUND', 'Session not found');
    }
    final state = await conversation.snapshot(id);
    final session = await sessions.getSession(id);
    final storedMessages = await conversation.visibleMessages(id);
    final latest = storedMessages.lastOrNull;
    final status = turns.turnStatus(id);
    return jsonResponse(200, {
      ..._snapshotJson(id, state),
      'activity': {
        'origin': session?.channelKey ?? session?.type.name ?? 'unknown',
        'ordinary_controls': session?.type == SessionType.user || session?.type == SessionType.main,
        'message_id': latest?.id,
        'message_cursor': latest?.cursor ?? 0,
        'turn': status.toJson(),
      },
    });
  });

  router.patch('/api/sessions/<id>/queue/<queueId>', (Request request, String id, String queueId) async {
    try {
      if (!requestHasAdminAccess(request)) {
        return errorResponse(403, 'CONVERSATION_FORBIDDEN', 'Queue mutation requires operator/admin access');
      }
      final body = await readJsonObject(request);
      if (body.error != null) return errorResponse(400, 'INVALID_INPUT', 'JSON body must be an object');
      final value = body.value!;
      final expectedRevision = value['conversation_revision'];
      final revisionId = value['revision_id'];
      final message = value['message'];
      if (expectedRevision is! int || revisionId is! String || message is! String) {
        return errorResponse(400, 'INVALID_INPUT', 'conversation_revision, revision_id, and message are required');
      }
      final result = await conversation.editQueueItem(
        sessionId: id,
        queueId: queueId,
        expectedRevision: expectedRevision,
        revisionId: revisionId,
        message: message,
        attachments: _objects(value['attachments']),
        references: _objects(value['references']),
      );
      return jsonResponse(200, result.toJson());
    } on ConversationMutationException catch (error) {
      return _mutationError(error);
    }
  });

  router.delete('/api/sessions/<id>/queue/<queueId>', (Request request, String id, String queueId) async {
    try {
      if (!requestHasAdminAccess(request)) {
        return errorResponse(403, 'CONVERSATION_FORBIDDEN', 'Queue mutation requires operator/admin access');
      }
      final body = await readJsonObject(request);
      if (body.error != null || body.value?['conversation_revision'] is! int) {
        return errorResponse(400, 'INVALID_INPUT', 'conversation_revision is required');
      }
      final result = await conversation.removeQueueItem(
        sessionId: id,
        queueId: queueId,
        expectedRevision: body.value!['conversation_revision'] as int,
      );
      return jsonResponse(200, result.toJson());
    } on ConversationMutationException catch (error) {
      return _mutationError(error);
    }
  });

  router.post('/api/sessions/<id>/queue/release', (Request request, String id) async {
    try {
      if (!requestHasAdminAccess(request)) {
        return errorResponse(403, 'CONVERSATION_FORBIDDEN', 'Queue release requires operator/admin access');
      }
      final body = await readJsonObject(request);
      if (body.error != null || body.value?['conversation_revision'] is! int) {
        return errorResponse(400, 'INVALID_INPUT', 'conversation_revision is required');
      }
      final result = await conversation.releaseNext(
        sessionId: id,
        expectedRevision: body.value!['conversation_revision'] as int,
      );
      return jsonResponse(202, result.toJson());
    } on ConversationMutationException catch (error) {
      return _mutationError(error);
    }
  });

  router.post('/api/sessions/<id>/steer', (Request request, String id) async {
    try {
      if (!requestHasAdminAccess(request)) {
        return errorResponse(403, 'CONVERSATION_FORBIDDEN', 'Steer requires operator/admin access');
      }
      final session = await sessions.getSession(id);
      if (session == null) return errorResponse(404, 'SESSION_NOT_FOUND', 'Session not found');
      if (session.type != SessionType.user && session.type != SessionType.main) {
        return errorResponse(409, 'STEER_UNSUPPORTED', 'Steer is available only for ordinary conversations');
      }
      final status = turns.turnStatus(id);
      if (status.turnId == null || !status.canCancel) {
        return errorResponse(409, 'STEER_UNSUPPORTED', 'Steer requires a cancellable active turn');
      }
      final body = await readJsonObject(request);
      if (body.error != null) return errorResponse(400, 'INVALID_INPUT', 'JSON body must be an object');
      final value = body.value!;
      if (value['submission_id'] is! String || value['revision_id'] is! String || value['message'] is! String) {
        return errorResponse(400, 'INVALID_INPUT', 'submission_id, revision_id, and message are required');
      }
      await conversation.stop(sessionId: id, turnId: status.turnId!);
      final result = await conversation.submit(
        sessionId: id,
        submissionId: value['submission_id'] as String,
        revisionId: value['revision_id'] as String,
        message: value['message'] as String,
        attachments: _objects(value['attachments']),
        references: _objects(value['references']),
      );
      return jsonResponse(202, result.toJson());
    } on ConversationMutationException catch (error) {
      return _mutationError(error);
    }
  });
}

Response _mutationError(ConversationMutationException error) => errorResponse(
  error.statusCode,
  error.code,
  error.message,
  {if (error.current != null) 'current': _snapshotJson('', error.current!)},
);

List<Map<String, dynamic>> _objects(Object? value) {
  if (value == null) return const [];
  if (value is! List) throw const ConversationMutationException(400, 'INVALID_INPUT', 'Expected a JSON array');
  return value
      .map((item) {
        if (item is! Map) throw const ConversationMutationException(400, 'INVALID_INPUT', 'Expected JSON objects');
        return Map<String, dynamic>.from(item);
      })
      .toList(growable: false);
}

Map<String, Object> _snapshotJson(String sessionId, ConversationState state) => {
  if (sessionId.isNotEmpty) 'session_id': sessionId,
  'revision': state.revision,
  'submissions': state.submissions.map((submission) => submission.toJson()).toList(growable: false),
  'queue': state.queue.map((submission) => submission.toJson()).toList(growable: false),
};
