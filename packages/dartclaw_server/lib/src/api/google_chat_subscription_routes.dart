import 'dart:convert';

import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'api_helpers.dart';

final _log = Logger('GoogleChatSubscriptionRoutes');

/// API routes for managing Google Chat Space Events subscriptions.
///
/// If space events are not configured (null manager), all routes return 503.
Router googleChatSubscriptionRoutes({required WorkspaceEventsManager? subscriptionManager}) {
  final router = Router();

  // GET /api/google-chat/subscriptions — list active subscriptions
  router.get('/api/google-chat/subscriptions', (Request request) async {
    final manager = subscriptionManager;
    if (manager == null) {
      return errorResponse(503, 'NOT_CONFIGURED', 'Space events are not configured');
    }

    try {
      final subscriptions = manager.subscriptions.values.toList();
      return jsonResponse(200, {
        'subscriptions': [
          for (final sub in subscriptions)
            {
              'spaceId': sub.spaceId,
              'subscriptionName': sub.subscriptionName,
              'expireTime': sub.expireTime.toUtc().toIso8601String(),
              'status': sub.isExpired ? 'expired' : 'active',
            },
        ],
        'total': subscriptions.length,
      });
    } catch (e) {
      _log.warning('Failed to list subscriptions', e);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to list subscriptions: $e');
    }
  });

  // POST /api/google-chat/subscriptions — subscribe to a space
  router.post('/api/google-chat/subscriptions', (Request request) async {
    final manager = subscriptionManager;
    if (manager == null) {
      return errorResponse(503, 'NOT_CONFIGURED', 'Space events are not configured');
    }

    final body = await _parseJsonBody(request);
    if (body == null) {
      return errorResponse(400, 'INVALID_INPUT', 'Request body must be valid JSON');
    }

    final spaceId = body['spaceId'] as String?;
    if (spaceId == null || spaceId.trim().isEmpty) {
      return errorResponse(400, 'INVALID_INPUT', '"spaceId" is required and must be a non-empty string');
    }

    try {
      final subscription = await manager.subscribe(spaceId.trim());
      if (subscription == null) {
        return errorResponse(500, 'SUBSCRIPTION_FAILED', 'Failed to subscribe to $spaceId — manager returned null');
      }
      return jsonResponse(201, {
        'subscription': {
          'spaceId': subscription.spaceId,
          'subscriptionName': subscription.subscriptionName,
          'expireTime': subscription.expireTime.toUtc().toIso8601String(),
        },
      });
    } catch (e) {
      _log.warning('Failed to create subscription for $spaceId', e);
      return errorResponse(500, 'SUBSCRIPTION_FAILED', 'Failed to subscribe to $spaceId: $e');
    }
  });

  // DELETE /api/google-chat/subscriptions — unsubscribe from a space
  //
  // Uses request body for spaceId to avoid path-parameter encoding issues
  // with slashes in space IDs like "spaces/AAAA".
  router.delete('/api/google-chat/subscriptions', (Request request) async {
    final manager = subscriptionManager;
    if (manager == null) {
      return errorResponse(503, 'NOT_CONFIGURED', 'Space events are not configured');
    }

    final body = await _parseJsonBody(request);
    if (body == null) {
      return errorResponse(400, 'INVALID_INPUT', 'Request body must be valid JSON');
    }

    final spaceId = body['spaceId'] as String?;
    if (spaceId == null || spaceId.trim().isEmpty) {
      return errorResponse(400, 'INVALID_INPUT', '"spaceId" is required and must be a non-empty string');
    }

    try {
      final deleted = await manager.unsubscribe(spaceId.trim());
      if (!deleted) {
        return jsonResponse(200, {
          'deleted': false,
          'spaceId': spaceId.trim(),
          'message': 'Removed from local tracking but remote API delete failed',
        });
      }
      return jsonResponse(200, {'deleted': true, 'spaceId': spaceId.trim()});
    } catch (e) {
      _log.warning('Failed to unsubscribe from $spaceId', e);
      return errorResponse(500, 'UNSUBSCRIBE_FAILED', 'Failed to unsubscribe from $spaceId: $e');
    }
  });

  return router;
}

Future<Map<String, dynamic>?> _parseJsonBody(Request request) async {
  final body = await request.readAsString();
  if (body.isEmpty) return null;
  try {
    final parsed = jsonDecode(body);
    if (parsed is Map<String, dynamic>) return parsed;
    return null;
  } catch (e) {
    return null;
  }
}
