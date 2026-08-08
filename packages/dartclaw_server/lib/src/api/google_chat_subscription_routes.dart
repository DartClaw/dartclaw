import 'dart:convert';

import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'api_helpers.dart';

final _log = Logger('GoogleChatSubscriptionRoutes');

typedef _GoogleChatSubscriptionMutation = Future<Response> Function(String spaceId, String normalizedSpaceId);

Future<Response> _runSubscriptionPreflight(
  Request request, {
  required bool configured,
  required _GoogleChatSubscriptionMutation mutate,
}) async {
  if (!configured) {
    return errorResponse(503, 'NOT_CONFIGURED', 'Space events are not configured');
  }

  final body = await _parseJsonBody(request);
  if (body == null) {
    return errorResponse(400, 'INVALID_INPUT', 'Request body must be valid JSON');
  }

  final rawSpaceId = body['spaceId'];
  if (rawSpaceId is! String || rawSpaceId.trim().isEmpty) {
    return errorResponse(400, 'INVALID_INPUT', '"spaceId" is required and must be a non-empty string');
  }

  final spaceId = rawSpaceId;
  return mutate(spaceId, spaceId.trim());
}

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
    return _runSubscriptionPreflight(
      request,
      configured: manager != null,
      mutate: (spaceId, normalizedSpaceId) async {
        try {
          final subscription = await manager!.subscribe(normalizedSpaceId);
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
      },
    );
  });

  // DELETE /api/google-chat/subscriptions — unsubscribe from a space
  //
  // Uses request body for spaceId to avoid path-parameter encoding issues
  // with slashes in space IDs like "spaces/AAAA".
  router.delete('/api/google-chat/subscriptions', (Request request) async {
    final manager = subscriptionManager;
    return _runSubscriptionPreflight(
      request,
      configured: manager != null,
      mutate: (spaceId, normalizedSpaceId) async {
        try {
          final deleted = await manager!.unsubscribe(normalizedSpaceId);
          if (!deleted) {
            return jsonResponse(200, {
              'deleted': false,
              'spaceId': normalizedSpaceId,
              'message': 'Removed from local tracking but remote API delete failed',
            });
          }
          return jsonResponse(200, {'deleted': true, 'spaceId': normalizedSpaceId});
        } catch (e) {
          _log.warning('Failed to unsubscribe from $spaceId', e);
          return errorResponse(500, 'UNSUBSCRIBE_FAILED', 'Failed to unsubscribe from $spaceId: $e');
        }
      },
    );
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
