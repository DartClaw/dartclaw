import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'package:dartclaw_storage/dartclaw_storage.dart';

import 'api_helpers.dart';

final _log = Logger('TraceRoutes');

/// Creates a [Router] exposing the trace query API endpoint.
Router traceRoutes(TurnTraceService traceService) {
  final router = Router();

  router.get('/api/traces', (Request request) async {
    final params = request.url.queryParameters;

    // Parse optional string filters.
    final taskId = params['taskId'];
    final sessionId = params['sessionId'];
    final model = params['model'];
    final provider = params['provider'];

    // Parse runnerId (optional int).
    int? runnerId;
    final runnerIdStr = params['runnerId'];
    if (runnerIdStr != null) {
      runnerId = int.tryParse(runnerIdStr);
      if (runnerId == null) {
        return errorResponse(400, 'INVALID_PARAM', 'runnerId must be an integer', {'field': 'runnerId'});
      }
    }

    // Parse since/until (optional ISO 8601 date-time).
    DateTime? since;
    final sinceStr = params['since'];
    if (sinceStr != null) {
      since = DateTime.tryParse(sinceStr);
      if (since == null) {
        return errorResponse(400, 'INVALID_PARAM', 'since must be a valid ISO 8601 date-time', {'field': 'since'});
      }
    }

    DateTime? until;
    final untilStr = params['until'];
    if (untilStr != null) {
      until = DateTime.tryParse(untilStr);
      if (until == null) {
        return errorResponse(400, 'INVALID_PARAM', 'until must be a valid ISO 8601 date-time', {'field': 'until'});
      }
    }

    // Parse limit (default 50, max 500).
    int limit = 50;
    final limitStr = params['limit'];
    if (limitStr != null) {
      final parsed = int.tryParse(limitStr);
      if (parsed == null || parsed < 0) {
        return errorResponse(400, 'INVALID_PARAM', 'limit must be a non-negative integer', {'field': 'limit'});
      }
      limit = parsed;
    }

    // Parse offset (default 0).
    int offset = 0;
    final offsetStr = params['offset'];
    if (offsetStr != null) {
      final parsed = int.tryParse(offsetStr);
      if (parsed == null || parsed < 0) {
        return errorResponse(400, 'INVALID_PARAM', 'offset must be a non-negative integer', {'field': 'offset'});
      }
      offset = parsed;
    }

    try {
      final result = await traceService.query(
        taskId: taskId,
        sessionId: sessionId,
        runnerId: runnerId,
        model: model,
        provider: provider,
        since: since,
        until: until,
        limit: limit,
        offset: offset,
      );
      return Response.ok(jsonEncode(result.toJson()), headers: {'content-type': 'application/json; charset=utf-8'});
    } catch (e, st) {
      _log.warning('Trace query failed', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to query traces');
    }
  });

  return router;
}
