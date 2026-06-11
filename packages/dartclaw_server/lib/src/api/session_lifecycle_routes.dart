import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../session/session_reset_service.dart';
import '../templates/sidebar.dart' show NavItem, SidebarData;
import '../turn_manager.dart' show TurnManager;
import 'api_helpers.dart';
import 'session_routes_support.dart';

final _log = Logger('SessionLifecycleRoutes');

/// Registers session lifecycle (delete / resume / archive / reset) endpoints.
///
/// Routes registered:
/// - `DELETE /api/sessions/<id>` — delete a non-protected session.
/// - `POST   /api/sessions/<id>/resume` — convert an archive back to a user session.
/// - `POST   /api/sessions/<id>/archive` — archive a user session.
/// - `POST   /api/sessions/<id>/reset` — reset session continuity + state.
void registerSessionLifecycleRoutes(
  Router router, {
  required SessionService sessions,
  required TurnManager turns,
  SessionResetService? resetService,
  Future<SidebarData> Function({String? activeSessionId})? sidebarData,
  String Function({required SidebarData sidebarData, List<NavItem> navItems})? buildSidebarHtml,
}) {
  // DELETE /api/sessions/<id>
  router.delete('/api/sessions/<id>', (Request request, String id) async {
    try {
      final session = await sessions.getSession(id);
      if (session == null) {
        return errorResponse(404, 'SESSION_NOT_FOUND', 'Session not found');
      }
      if (SessionService.protectedTypes.contains(session.type)) {
        return errorResponse(403, 'FORBIDDEN', 'Cannot delete ${session.type.name} session');
      }

      await turns.cancelTurn(id);
      try {
        await turns.waitForCompletion(id);
      } catch (e) {
        // TimeoutException or turn completer error — log and proceed with delete
        _log.warning('waitForCompletion for session $id: $e');
      }
      await sessions.deleteSession(id);
      return Response(204);
    } catch (e) {
      _log.warning('Failed to delete session $id: $e', e);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to delete session');
    }
  });

  // POST /api/sessions/<id>/resume — convert archive to user session
  router.post('/api/sessions/<id>/resume', (Request request, String id) async {
    try {
      final session = await sessions.getSession(id);
      if (session == null) {
        return errorResponse(404, 'SESSION_NOT_FOUND', 'Session not found');
      }
      if (session.type != SessionType.archive) {
        return errorResponse(400, 'INVALID_STATE', 'Only archive sessions can be resumed');
      }
      final updated = await sessions.updateSessionType(id, SessionType.user);
      if (updated == null) {
        return errorResponse(500, 'INTERNAL_ERROR', 'Failed to update session type');
      }
      return jsonResponse(200, updated.toJson());
    } catch (e) {
      _log.warning('Failed to resume session $id: $e', e);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to resume session');
    }
  });

  // POST /api/sessions/<id>/archive — convert user session to archive
  router.post('/api/sessions/<id>/archive', (Request request, String id) async {
    try {
      final session = await sessions.getSession(id);
      if (session == null) {
        return errorResponse(404, 'SESSION_NOT_FOUND', 'Session not found');
      }
      if (session.type != SessionType.user) {
        return errorResponse(400, 'INVALID_STATE', 'Only user sessions can be archived');
      }

      await turns.cancelTurn(id);
      try {
        await turns.waitForCompletion(id);
      } catch (e) {
        _log.warning('waitForCompletion for session $id: $e');
      }

      final updated = await sessions.updateSessionType(id, SessionType.archive);
      if (updated == null) {
        return errorResponse(500, 'INTERNAL_ERROR', 'Failed to update session type');
      }

      final sidebarDataBuilder = sidebarData;
      final sidebarHtmlBuilder = buildSidebarHtml;
      final activeSessionId = trimmedOrNull(request.headers['x-dartclaw-active-session-id']);
      if (sidebarDataBuilder != null && sidebarHtmlBuilder != null) {
        if (activeSessionId == id) {
          return Response(200, headers: {'HX-Redirect': '/'});
        }
        final sidebarData = await sidebarDataBuilder(activeSessionId: activeSessionId);
        final sidebarHtml = sidebarHtmlBuilder(sidebarData: sidebarData, navItems: const []);
        return Response(
          200,
          body: _withSidebarOobSwap(sidebarHtml),
          headers: {'content-type': 'text/html; charset=utf-8'},
        );
      }

      return jsonResponse(200, updated.toJson());
    } catch (e) {
      _log.warning('Failed to archive session $id: $e', e);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to archive session');
    }
  });

  // POST /api/sessions/<id>/reset
  router.post('/api/sessions/<id>/reset', (Request request, String id) async {
    try {
      final session = await sessions.getSession(id);
      if (session == null) {
        return errorResponse(404, 'SESSION_NOT_FOUND', 'Session not found');
      }
      if (session.type == SessionType.archive) {
        return errorResponse(403, 'FORBIDDEN', 'Cannot reset archived session');
      }
      if (session.type == SessionType.task) {
        return errorResponse(403, 'FORBIDDEN', 'Task sessions are managed via the task API');
      }
      if (turns.isActive(id)) {
        return errorResponse(409, 'SESSION_BUSY', 'Cannot reset: turn in progress');
      }
      final rs = resetService;
      if (rs == null) {
        return errorResponse(501, 'NOT_IMPLEMENTED', 'Reset service not available');
      }
      try {
        await turns.resetSessionContinuity(id);
      } on BusyTurnException {
        return errorResponse(409, 'SESSION_BUSY', 'Cannot reset: turn in progress');
      }
      await rs.resetSession(id, resetContinuity: false);
      return jsonResponse(200, {'status': 'reset'});
    } catch (e) {
      _log.warning('Failed to reset session $id: $e', e);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to reset session');
    }
  });
}

String _withSidebarOobSwap(String html) {
  final withSidebar = html.contains('hx-swap-oob=')
      ? html
      : html.replaceFirst('<aside ', '<aside hx-swap-oob="outerHTML" ');
  return withSidebar.replaceFirst(
    '<button class="sidebar-scrim"',
    '<button hx-swap-oob="outerHTML:.sidebar-scrim" class="sidebar-scrim"',
  );
}
