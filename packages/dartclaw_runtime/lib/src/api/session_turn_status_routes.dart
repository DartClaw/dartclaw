import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show SessionType;
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/request_auth_context.dart';
import '../concurrency/session_mutation_coordinator.dart';
import '../conversation/conversation_service.dart';
import '../turn_manager.dart' show TurnManager;
import '../turn_wait_status.dart';
import 'api_helpers.dart';

final _log = Logger('SessionTurnStatusRoutes');

/// Registers the stuck-turn status and early-cancel turn endpoints on [router].
///
/// Routes registered (operator/admin only):
/// - `POST /api/sessions/<id>/turn/stop` — cancels the active turn if cancellable.
/// - `GET /api/sessions/<id>/turn-status` — returns the turn-status snapshot.
/// - `POST /api/sessions/<id>/turns/<turnId>/cancel` — cancels a specific turn by id.
void registerSessionTurnStatusRoutes(
  Router router, {
  required SessionService sessions,
  required TurnManager turns,
  required ConversationService conversation,
  required SessionMutationCoordinator sessionMutations,
}) {
  // POST /api/sessions/<id>/turn/stop
  router.post('/api/sessions/<id>/turn/stop', (Request request, String id) async {
    try {
      if (!requestHasAdminAccess(request)) {
        return errorResponse(403, 'TURN_CANCEL_FORBIDDEN', 'Turn cancel requires operator/admin access');
      }
      final session = await sessions.getSession(id);
      if (session == null) {
        return errorResponse(404, 'SESSION_NOT_FOUND', 'Session not found');
      }
      final snapshot = turns.turnStatus(id);
      final turnId = snapshot.turnId;
      if (turnId == null) {
        return errorResponse(404, 'TURN_NOT_FOUND', 'Turn not found');
      }
      if (!snapshot.canCancel) {
        return errorResponse(409, 'TURN_NOT_CANCELLABLE', 'Turn is not cancellable');
      }
      if (session.type != SessionType.user && session.type != SessionType.main) {
        await sessionMutations.run(id, () => turns.cancelTurnById(id, turnId, TurnCancelReason.operatorCancel));
        final state = await sessions.getConversationState(id);
        return jsonResponse(200, {'status': 'stopped', 'conversation_revision': state.revision});
      }
      final state = await conversation.stop(sessionId: id, turnId: turnId);
      return jsonResponse(200, {'status': 'stopped', 'conversation_revision': state.revision});
    } on ConversationMutationException catch (e) {
      return errorResponse(e.statusCode, e.code, e.message);
    } on TurnCancelException catch (e) {
      return errorResponse(e.statusCode, e.code, e.message);
    } catch (e) {
      _log.warning('Failed to stop turn for $id: $e', e);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to stop turn');
    }
  });

  // GET /api/sessions/<id>/turn-status
  router.get('/api/sessions/<id>/turn-status', (Request request, String id) async {
    try {
      if (!requestHasAdminAccess(request)) {
        return errorResponse(403, 'TURN_STATUS_FORBIDDEN', 'Turn status requires operator/admin access');
      }
      final session = await sessions.getSession(id);
      if (session == null) {
        return errorResponse(404, 'SESSION_NOT_FOUND', 'Session not found');
      }
      return jsonResponse(200, turns.turnStatus(id).toJson());
    } catch (e) {
      _log.warning('Failed to get turn status for $id: $e', e);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to get turn status');
    }
  });

  // POST /api/sessions/<id>/turns/<turnId>/cancel
  router.post('/api/sessions/<id>/turns/<turnId>/cancel', (Request request, String id, String turnId) async {
    try {
      if (!requestHasAdminAccess(request)) {
        return errorResponse(403, 'TURN_CANCEL_FORBIDDEN', 'Turn cancel requires operator/admin access');
      }
      final session = await sessions.getSession(id);
      if (session == null) {
        return errorResponse(404, 'SESSION_NOT_FOUND', 'Session not found');
      }
      final parsed = await readJsonObject(request);
      if (parsed.error != null) {
        return errorResponse(400, 'TURN_CANCEL_BAD_REQUEST', 'JSON body must be an object');
      }
      final reasonValue = parsed.value?['reason'];
      if (reasonValue is! String || reasonValue.trim().isEmpty) {
        return errorResponse(400, 'TURN_CANCEL_BAD_REQUEST', 'reason is required');
      }
      final reason = TurnCancelReason.parse(reasonValue.trim());
      if (reason == null) {
        return errorResponse(400, 'TURN_CANCEL_INVALID_REASON', 'Invalid turn cancel reason');
      }
      try {
        if (reason == TurnCancelReason.operatorCancel &&
            (session.type == SessionType.user || session.type == SessionType.main)) {
          final state = await conversation.stop(sessionId: id, turnId: turnId);
          return jsonResponse(200, {'status': 'cancelled', 'conversation_revision': state.revision});
        }
        final result = await sessionMutations.run(id, () => turns.cancelTurnById(id, turnId, reason));
        return jsonResponse(200, result.toJson());
      } on ConversationMutationException catch (e) {
        return errorResponse(e.statusCode, e.code, e.message);
      } on TurnCancelException catch (e) {
        return errorResponse(e.statusCode, e.code, e.message);
      }
    } catch (e) {
      _log.warning('Failed to cancel turn $turnId for $id: $e', e);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to cancel turn');
    }
  });
}
