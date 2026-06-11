import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../session/session_reset_service.dart';
import '../templates/sidebar.dart' show NavItem, SidebarData;
import '../turn_manager.dart' show TurnManager;
import 'api_helpers.dart';
import 'chat_command_handler.dart';
import 'session_attachment_routes.dart';
import 'session_lifecycle_routes.dart';
import 'session_message_routes.dart';
import 'session_routes_support.dart';
import 'session_turn_status_routes.dart';

final _log = Logger('SessionRoutes');

// ---------------------------------------------------------------------------
// Public route factory
// ---------------------------------------------------------------------------

/// Creates a [Router] exposing session CRUD and turn execution API endpoints.
///
/// Session CRUD (list/get/create/patch) is handled here; cohesive route groups
/// are registered from sibling `session_*_routes.dart` files.
Router sessionRoutes(
  SessionService sessions,
  MessageService messages,
  TurnManager turns,
  AgentHarness worker, {
  SessionResetService? resetService,
  MessageRedactor? redactor,
  ChatCommandHandler? chatCommandHandler,
  ProjectService? projectService,
  Future<SidebarData> Function({String? activeSessionId})? sidebarData,
  String Function({required SidebarData sidebarData, List<NavItem> navItems})? buildSidebarHtml,
}) {
  final router = Router();

  // GET /api/sessions
  router.get('/api/sessions', (Request request) async {
    try {
      final typeParam = request.url.queryParameters['type'];
      final typeFilter = typeParam != null ? SessionType.values.asNameMap()[typeParam] : null;
      final list = await sessions.listSessions(type: typeFilter);
      return jsonResponse(200, list.map((s) => s.toJson()).toList());
    } catch (e) {
      _log.warning('Failed to list sessions: $e', e);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to list sessions');
    }
  });

  // GET /api/sessions/<id>
  router.get('/api/sessions/<id>', (Request request, String id) async {
    try {
      final session = await sessions.getSession(id);
      if (session == null) {
        return errorResponse(404, 'SESSION_NOT_FOUND', 'Session not found');
      }
      return jsonResponse(200, session.toJson());
    } catch (e) {
      _log.warning('Failed to get session $id: $e', e);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to get session');
    }
  });

  // POST /api/sessions
  router.post('/api/sessions', (Request request) async {
    try {
      final queryProvider = trimmedOrNull(request.url.queryParameters['provider']);
      final parsed = queryProvider == null
          ? await parseOptionalBodyField(request, 'provider')
          : (value: queryProvider, error: null);
      if (parsed.error != null) return parsed.error!;
      final providerValidation = _validateSessionProvider(parsed.value, turns.pool);
      if (providerValidation != null) return providerValidation;

      final session = await sessions.createSession(provider: parsed.value);
      return jsonResponse(201, session.toJson());
    } catch (e) {
      _log.warning('Failed to create session: $e', e);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to create session');
    }
  });

  // PATCH /api/sessions/<id>
  router.patch('/api/sessions/<id>', (Request request, String id) async {
    try {
      final session = await sessions.getSession(id);
      if (session == null) {
        return errorResponse(404, 'SESSION_NOT_FOUND', 'Session not found');
      }

      final parsed = await parseBodyField(request, 'title');
      if (parsed.error != null) return parsed.error!;
      final title = parsed.value;

      final titleValidation = _validateTitle(title);
      if (titleValidation != null) return titleValidation;

      final trimmed = title!.trim();
      await sessions.updateTitle(id, trimmed);
      final updated = await sessions.getSession(id);
      if (updated == null) {
        return errorResponse(404, 'SESSION_NOT_FOUND', 'Session not found');
      }
      return jsonResponse(200, updated.toJson());
    } catch (e) {
      _log.warning('Failed to update session $id: $e', e);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to update session');
    }
  });

  // Message history, chat-send, commands, and SSE stream.
  registerSessionMessageRoutes(
    router,
    sessions: sessions,
    messages: messages,
    turns: turns,
    worker: worker,
    redactor: redactor,
    chatCommandHandler: chatCommandHandler,
    projectService: projectService,
  );

  // Attachment upload + reference autocomplete.
  registerSessionAttachmentRoutes(router, sessions: sessions, messages: messages, projectService: projectService);

  // Stuck-turn status + early-cancel endpoints (turn/stop, turn-status, turns/<turnId>/cancel).
  registerSessionTurnStatusRoutes(router, sessions: sessions, turns: turns);

  // Session lifecycle (delete / resume / archive / reset).
  registerSessionLifecycleRoutes(
    router,
    sessions: sessions,
    turns: turns,
    resetService: resetService,
    sidebarData: sidebarData,
    buildSidebarHtml: buildSidebarHtml,
  );

  return router;
}

// ---------------------------------------------------------------------------
// Validation helpers
// ---------------------------------------------------------------------------

/// Returns an error [Response] if [title] is invalid, otherwise null.
Response? _validateTitle(String? title) {
  if (title == null || title.trim().isEmpty) {
    return errorResponse(400, 'INVALID_INPUT', 'title must not be empty', {'field': 'title'});
  }
  if (title.trim().length > 120) {
    return errorResponse(400, 'INVALID_INPUT', 'title must not exceed 120 characters', {'field': 'title'});
  }
  return null;
}

Response? _validateSessionProvider(String? provider, HarnessPool pool) {
  if (provider == null) {
    return null;
  }
  if (pool.hasTaskRunnerForProvider(provider)) {
    return null;
  }
  return errorResponse(400, 'PROVIDER_UNAVAILABLE', 'Provider "$provider" is not available for session overrides', {
    'field': 'provider',
    'provider': provider,
  });
}
