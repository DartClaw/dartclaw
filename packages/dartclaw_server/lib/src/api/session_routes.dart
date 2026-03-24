import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../session/session_reset_service.dart';
import '../templates/sidebar.dart' show NavItem, SidebarData;
import '../templates/loader.dart';
import 'api_helpers.dart';
import '../harness_pool.dart';
import '../turn_manager.dart';
import 'stream_handler.dart';

final _log = Logger('SessionRoutes');

// ---------------------------------------------------------------------------
// Public route factory
// ---------------------------------------------------------------------------

/// Creates a [Router] exposing session CRUD and turn execution API endpoints.
Router sessionRoutes(
  SessionService sessions,
  MessageService messages,
  TurnManager turns,
  AgentHarness worker, {
  SessionResetService? resetService,
  MessageRedactor? redactor,
  Future<SidebarData> Function()? buildSidebarData,
  String Function({required SidebarData sidebarData, String? activeSessionId, List<NavItem> navItems})? buildSidebarHtml,
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

  // POST /api/sessions
  router.post('/api/sessions', (Request request) async {
    try {
      final queryProvider = _trimmedOrNull(request.url.queryParameters['provider']);
      final parsed = queryProvider == null
          ? await _parseOptionalField(request, 'provider')
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

      final parsed = await _parseField(request, 'title');
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

  // GET /api/sessions/<id>/messages
  router.get('/api/sessions/<id>/messages', (Request request, String id) async {
    try {
      final session = await sessions.getSession(id);
      if (session == null) {
        return errorResponse(404, 'SESSION_NOT_FOUND', 'Session not found');
      }

      final list = await messages.getMessages(id);
      return jsonResponse(200, list.map(_messageToJson).toList());
    } catch (e) {
      _log.warning('Failed to get messages for $id: $e', e);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to get messages');
    }
  });

  // POST /api/sessions/<id>/send
  router.post('/api/sessions/<id>/send', (Request request, String id) async {
    try {
      // 1. Look up session
      final session = await sessions.getSession(id);
      if (session == null) {
        return errorResponse(404, 'SESSION_NOT_FOUND', 'Session not found');
      }
      if (session.type == SessionType.archive) {
        return errorResponse(403, 'FORBIDDEN', 'Cannot send to archived session');
      }
      if (session.type == SessionType.task) {
        return errorResponse(403, 'FORBIDDEN', 'Task sessions are managed via the task API');
      }
      final providerValidation = _validateSessionProviderForSend(session.provider, turns.pool);
      if (providerValidation != null) return providerValidation;

      // 2. Parse + validate message
      final parsed = await _parseField(request, 'message');
      if (parsed.error != null) return parsed.error!;
      final rawMessage = parsed.value;

      final messageValidation = _validateMessage(rawMessage);
      if (messageValidation != null) return messageValidation;

      final trimmedMessage = rawMessage!.trim();

      // 3. Reserve turn — same-session queues behind active turn, global cap → 409.
      final String turnId;
      try {
        turnId = await turns.reserveTurn(id, isHumanInput: true);
      } on BusyTurnException {
        if (session.provider != null) {
          return errorResponse(409, 'AGENT_BUSY_PROVIDER', 'No idle ${session.provider} workers available', {
            'provider': session.provider,
          });
        }
        return errorResponse(409, 'AGENT_BUSY_GLOBAL', 'Agent is busy with another session');
      }

      // 4. Persist + fetch messages; release reservation on failure.
      try {
        await messages.insertMessage(sessionId: id, role: 'user', content: trimmedMessage);
        final sessionMessages = await messages.getMessages(id);
        final messagesList = sessionMessages.map(_messageToJson).toList();
        // 5. Launch async execution.
        turns.executeTurn(id, turnId, messagesList, source: 'web');
      } catch (e) {
        turns.releaseTurn(id, turnId);
        rethrow;
      }

      // 6. Return HTML fragment
      final html = templateLoader.trellis.renderFragment(
        templateLoader.source('chat'),
        fragment: 'sendResponse',
        context: {'message': trimmedMessage, 'sseUrl': '/api/sessions/$id/stream?turn=$turnId'},
      );

      return Response(200, body: html, headers: {'content-type': 'text/html; charset=utf-8'});
    } catch (e) {
      _log.warning('Failed to send message for $id: $e', e);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to send message');
    }
  });

  // GET /api/sessions/<id>/stream
  router.get('/api/sessions/<id>/stream', (Request request, String id) async {
    final turnId = request.url.queryParameters['turn'];
    if (turnId == null || turnId.isEmpty) {
      return errorResponse(404, 'TURN_NOT_FOUND', 'turn query parameter is required');
    }

    final isActive = turns.isActiveTurn(id, turnId);
    final outcome = turns.recentOutcome(id, turnId);

    if (!isActive && outcome == null) {
      return errorResponse(404, 'TURN_NOT_FOUND', 'Turn not found or expired');
    }

    return sseStreamResponse(worker, turns, id, turnId, redactor: redactor);
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

      final sidebarDataBuilder = buildSidebarData;
      final sidebarHtmlBuilder = buildSidebarHtml;
      final activeSessionId = _trimmedOrNull(request.headers['x-dartclaw-active-session-id']);
      if (sidebarDataBuilder != null && sidebarHtmlBuilder != null) {
        if (activeSessionId == id) {
          return Response(200, headers: {'HX-Redirect': '/'});
        }
        final sidebarData = await sidebarDataBuilder();
        final sidebarHtml = sidebarHtmlBuilder(
          sidebarData: sidebarData,
          activeSessionId: activeSessionId,
          navItems: const [],
        );
        return Response(200, body: _withSidebarOobSwap(sidebarHtml), headers: {'content-type': 'text/html; charset=utf-8'});
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
      await rs.resetSession(id);
      return jsonResponse(200, {'status': 'reset'});
    } catch (e) {
      _log.warning('Failed to reset session $id: $e', e);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to reset session');
    }
  });

  return router;
}

// ---------------------------------------------------------------------------
// Serialization helpers
// ---------------------------------------------------------------------------

Map<String, dynamic> _messageToJson(Message m) => {
  'id': m.id,
  'sessionId': m.sessionId,
  'role': m.role,
  'content': m.content,
  'cursor': m.cursor,
  'metadata': m.metadata != null ? _tryParseJson(m.metadata!) : null,
  'createdAt': m.createdAt.toIso8601String(),
};

dynamic _tryParseJson(String s) {
  try {
    return jsonDecode(s);
  } catch (e) {
    return s;
  }
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

// ---------------------------------------------------------------------------
// Body parsing
// ---------------------------------------------------------------------------

/// Extracts a named field from form-urlencoded or JSON request body.
Future<({String? value, Response? error})> _parseField(Request request, String field) async {
  final ct = request.headers['content-type'] ?? '';
  if (ct.startsWith('application/x-www-form-urlencoded')) {
    final body = await request.readAsString();
    final params = Uri.splitQueryString(body);
    return (value: params[field], error: null);
  }
  if (ct.startsWith('application/json')) {
    try {
      final body = await request.readAsString();
      final json = jsonDecode(body) as Map<String, dynamic>;
      return (value: json[field] as String?, error: null);
    } on FormatException {
      return (value: null, error: errorResponse(400, 'INVALID_INPUT', 'Invalid JSON body'));
    } on TypeError {
      return (value: null, error: errorResponse(400, 'INVALID_INPUT', 'Invalid JSON structure'));
    }
  }
  return (value: null, error: errorResponse(415, 'UNSUPPORTED_MEDIA_TYPE', 'Unsupported content type'));
}

Future<({String? value, Response? error})> _parseOptionalField(Request request, String field) async {
  if ((request.contentLength ?? 0) == 0 && request.headers['content-type'] == null) {
    return (value: null, error: null);
  }

  final parsed = await _parseField(request, field);
  if (parsed.error != null) return parsed;
  return (value: _trimmedOrNull(parsed.value), error: null);
}

// ---------------------------------------------------------------------------
// Validation helpers
// ---------------------------------------------------------------------------

/// Returns an error [Response] if [message] is invalid, otherwise null.
Response? _validateMessage(String? message) {
  if (message == null || message.trim().isEmpty) {
    return errorResponse(400, 'INVALID_INPUT', 'message must not be empty', {'field': 'message'});
  }
  if (message.trim().length > 20000) {
    return errorResponse(400, 'INVALID_INPUT', 'message must not exceed 20000 characters', {'field': 'message'});
  }
  return null;
}

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

Response? _validateSessionProviderForSend(String? provider, HarnessPool pool) {
  if (provider == null) {
    return null;
  }
  if (pool.hasTaskRunnerForProvider(provider)) {
    return null;
  }
  return errorResponse(409, 'PROVIDER_UNAVAILABLE', 'Provider "$provider" is not available for session overrides', {
    'provider': provider,
  });
}

String? _trimmedOrNull(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  return trimmed;
}
