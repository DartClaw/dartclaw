import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/auth_utils.dart';

final _log = Logger('WebhookRoutes');

/// HTTP routes for channel webhooks.
///
/// These endpoints are excluded from gateway auth — GOWA calls them directly.
/// When [webhookSecret] is set, incoming requests must include a matching
/// `secret` query parameter.
Router webhookRoutes({WhatsAppChannel? whatsApp, String? webhookSecret}) {
  final router = Router();

  if (whatsApp != null) {
    router.post('/webhook/whatsapp', (Request request) async {
      // Validate webhook secret if configured
      if (webhookSecret != null) {
        final requestSecret = request.requestedUri.queryParameters['secret'];
        if (requestSecret == null || !constantTimeEquals(requestSecret, webhookSecret)) {
          _log.warning('Webhook request with invalid/missing secret');
          return Response.forbidden('');
        }
      }

      final body = await readBounded(request, maxWebhookPayloadBytes);
      if (body == null) {
        _log.warning('WhatsApp webhook payload exceeds size limit');
        return Response(413);
      }

      try {
        final payload = jsonDecode(body) as Map<String, dynamic>;
        whatsApp.handleWebhook(payload);
      } catch (e) {
        _log.warning('Invalid WhatsApp webhook payload', e);
      }
      // Return 200 immediately — processing is async
      return Response.ok('');
    });
  }

  return router;
}
