import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../api/api_helpers.dart';
import '../templates/canvas_embed.dart';
import '../web/web_utils.dart';
import 'canvas_service.dart';
import 'canvas_state.dart';
import 'canvas_utils.dart';
import 'qr_generator.dart';

Router canvasAdminRoutes({required CanvasService canvasService}) {
  final router = Router();

  router.get('/api/canvas/share', (Request request) {
    final sessionKey = request.requestedUri.queryParameters['sessionKey'] ?? SessionKey.webSession();
    final baseUrl = request.requestedUri.origin;
    final state = canvasService.getState(sessionKey);
    final tokens = state?.activeTokens.where((token) => !token.isExpired).toList(growable: false) ?? const [];
    return jsonResponse(200, tokens.map((token) => _tokenJson(token, baseUrl)).toList(growable: false));
  });

  router.post('/api/canvas/share', (Request request) async {
    final parsed = await readJsonObject(request);
    if (parsed.error != null) return parsed.error!;

    final body = parsed.value!;
    final sessionKey = trimmedStringOrNull(body['sessionKey']);
    final permission = CanvasPermission.fromName(trimmedStringOrNull(body['permission']) ?? 'interact');
    if (sessionKey == null || sessionKey.isEmpty) {
      return errorResponse(400, 'INVALID_INPUT', 'Field "sessionKey" is required');
    }
    if (permission == null) {
      return errorResponse(400, 'INVALID_INPUT', 'Field "permission" must be "view" or "interact"');
    }

    final ttl = parseDuration(trimmedStringOrNull(body['ttl']) ?? '8h');
    if (ttl == null || ttl <= Duration.zero) {
      return errorResponse(400, 'INVALID_INPUT', 'Field "ttl" must be a duration like "30m" or "8h"');
    }

    final token = canvasService.createShareToken(
      sessionKey,
      permission: permission,
      ttl: ttl,
      label: _normalizedLabel(trimmedStringOrNull(body['label'])),
    );
    return jsonResponse(200, _tokenJson(token, request.requestedUri.origin));
  });

  router.delete('/api/canvas/share/<token>', (Request request, String token) {
    canvasService.revokeShareToken(token);
    return jsonResponse(200, {'revoked': true});
  });

  router.get('/api/sessions/<key>/canvas/embed', (Request request, String key) {
    final sessionKey = Uri.decodeComponent(key);
    final nonce = generateCspNonce();
    final html = canvasEmbedTemplate(
      sessionKey: sessionKey,
      streamUrl: '/api/sessions/${Uri.encodeComponent(sessionKey)}/canvas/embed/stream',
      nonce: nonce,
    );
    return Response.ok(html, headers: {
      ...htmlHeaders,
      'Content-Security-Policy': canvasCspHeader(nonce),
    });
  });

  router.get('/api/sessions/<key>/canvas/embed/stream', (Request request, String key) {
    final sessionKey = Uri.decodeComponent(key);
    StreamController<List<int>> controller;
    try {
      controller = canvasService.subscribe(sessionKey);
    } on StateError catch (error) {
      return Response(429, body: error.message);
    }
    final state = canvasService.getState(sessionKey) ?? const CanvasState();
    controller.add(sseFrame('canvas_state', {'html': state.currentHtml, 'visible': state.visible}));
    return Response.ok(
      controller.stream,
      headers: {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
        'X-Accel-Buffering': 'no',
      },
    );
  });

  return router;
}

Map<String, dynamic> _tokenJson(CanvasShareToken token, String baseUrl) {
  final url = '$baseUrl/canvas/${token.token}';
  return {
    'token': token.token,
    'url': url,
    'permission': token.permission.name,
    'expiresAt': token.expiresAt.toIso8601String(),
    'label': token.label,
    'qrSvg': generateQrSvg(url),
  };
}

String? _normalizedLabel(String? label) {
  if (label == null || label.isEmpty) return null;
  return label;
}
