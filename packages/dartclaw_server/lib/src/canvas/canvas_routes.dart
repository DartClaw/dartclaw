import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../api/api_helpers.dart';
import '../templates/canvas_standalone.dart';
import '../turn_manager.dart';
import 'canvas_service.dart';
import 'canvas_share_middleware.dart';
import 'canvas_state.dart';
import 'canvas_utils.dart';

Router canvasRoutes({
  required CanvasService canvasService,
  required TurnManager turns,
  required SessionService sessions,
}) {
  final router = Router();
  final actionLimiter = _ActionRateLimiter();

  router.get('/<token>', (Request request, String token) async {
    return _withShareToken(request, canvasService, (authorizedRequest, shareToken) async {
      if (shareToken.token != token) {
        return Response.notFound('Not found');
      }
      final nonce = generateCspNonce();
      final html = canvasStandaloneTemplate(
        token: shareToken.token,
        permission: shareToken.permission.name,
        streamUrl: '/canvas/${Uri.encodeComponent(shareToken.token)}/stream',
        actionUrl: '/canvas/${Uri.encodeComponent(shareToken.token)}/action',
        nonce: nonce,
      );
      return Response.ok(
        html,
        headers: {
          'Content-Type': 'text/html; charset=utf-8',
          'Content-Security-Policy': canvasCspHeader(nonce),
        },
      );
    });
  });

  router.get('/<token>/stream', (Request request, String token) async {
    return _withShareToken(request, canvasService, (authorizedRequest, shareToken) async {
      if (shareToken.token != token) {
        return Response.notFound('Not found');
      }

      StreamController<List<int>> streamController;
      try {
        streamController = canvasService.subscribe(shareToken.sessionKey);
      } on StateError catch (error) {
        return Response(429, body: error.message);
      }
      final state = canvasService.getState(shareToken.sessionKey) ?? const CanvasState();
      streamController.add(sseFrame('canvas_state', {'html': state.currentHtml, 'visible': state.visible}));

      return Response.ok(
        streamController.stream,
        headers: {
          'Content-Type': 'text/event-stream',
          'Cache-Control': 'no-cache',
          'Connection': 'keep-alive',
          'X-Accel-Buffering': 'no',
        },
      );
    });
  });

  router.post('/<token>/action', (Request request, String token) async {
    return _withShareToken(request, canvasService, (authorizedRequest, shareToken) async {
      if (shareToken.token != token || shareToken.permission != CanvasPermission.interact) {
        return Response.notFound('Not found');
      }

      if (!actionLimiter.allow(shareToken.token)) {
        return Response(429, body: 'Rate limit exceeded');
      }

      final parsed = await readJsonObject(authorizedRequest);
      if (parsed.error != null) return parsed.error!;
      final body = parsed.value!;
      final action = trimmedStringOrNull(body['action']);
      if (action == null || action.isEmpty) {
        return errorResponse(400, 'INVALID_INPUT', 'Field "action" is required');
      }

      final nickname = _parseCookie(authorizedRequest.headers['cookie'], 'canvas_nickname') ?? 'anonymous';
      final payloadText = _formatPayload(body['payload']);
      final content = '[Canvas] $action: $payloadText (from: $nickname via canvas)';

      final session = await sessions.getOrCreateByKey(shareToken.sessionKey, type: SessionType.channel);
      await turns.startTurn(
        session.id,
        [
          {'role': 'user', 'content': content},
        ],
        source: 'canvas',
        isHumanInput: true,
      );

      return jsonResponse(200, {'ok': true});
    });
  });

  return router;
}

Future<Response> _withShareToken(
  Request request,
  CanvasService canvasService,
  Future<Response> Function(Request request, CanvasShareToken shareToken) onAuthorized,
) async {
  final guardedHandler = canvasShareMiddleware(canvasService)((authorizedRequest) async {
    final shareToken = getShareToken(authorizedRequest);
    if (shareToken == null) {
      return Response.notFound('Not found');
    }
    return onAuthorized(authorizedRequest, shareToken);
  });
  return guardedHandler(request);
}

String _formatPayload(Object? payload) {
  if (payload == null) return '{}';
  if (payload is String) {
    final value = payload.trim();
    return value.isEmpty ? '{}' : value;
  }
  return jsonEncode(payload);
}

String? _parseCookie(String? header, String name) {
  if (header == null || header.isEmpty) return null;
  for (final part in header.split(';')) {
    final trimmed = part.trim();
    final equalsIndex = trimmed.indexOf('=');
    if (equalsIndex <= 0) continue;
    final key = trimmed.substring(0, equalsIndex).trim();
    if (key != name) continue;
    final raw = trimmed.substring(equalsIndex + 1).trim();
    try {
      return Uri.decodeComponent(raw);
    } catch (_) {
      return raw;
    }
  }
  return null;
}

/// Simple per-token rate limiter for canvas action requests.
class _ActionRateLimiter {
  final int _maxActions;
  final Duration _window;
  final Map<String, List<DateTime>> _history = {};

  _ActionRateLimiter({int maxActions = 10, Duration window = const Duration(minutes: 1)})
    : _maxActions = maxActions,
      _window = window;

  bool allow(String token) {
    final now = DateTime.now();
    final cutoff = now.subtract(_window);
    final list = _history.putIfAbsent(token, () => []);
    list.removeWhere((t) => t.isBefore(cutoff));
    if (list.length >= _maxActions) return false;
    list.add(now);
    return true;
  }
}
