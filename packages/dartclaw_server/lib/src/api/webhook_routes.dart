import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

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
        if (requestSecret != webhookSecret) {
          _log.warning('Webhook request with invalid/missing secret');
          return Response.forbidden('');
        }
      }

      try {
        final body = await request.readAsString();
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
