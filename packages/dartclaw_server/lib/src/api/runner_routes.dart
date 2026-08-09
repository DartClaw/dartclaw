import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../task/runner_observer.dart';

/// Creates a [Router] with harness-runner REST API endpoints.
///
/// `GET /api/runners` — all runners with metrics and pool status.
/// `GET /api/runners/<id>` — single runner metrics by pool index.
Router runnerRoutes(RunnerObserver observer) {
  final router = Router();

  router.get('/api/runners', (Request request) {
    final body = jsonEncode({
      'runners': observer.metrics.map((m) => m.toJson()).toList(),
      'pool': {
        'size': observer.poolStatus.size,
        'activeCount': observer.poolStatus.activeCount,
        'availableCount': observer.poolStatus.availableCount,
        'maxConcurrentWorkers': observer.poolStatus.maxConcurrentWorkers,
      },
    });
    return Response.ok(body, headers: {'Content-Type': 'application/json'});
  });

  router.get('/api/runners/<id>', (Request request, String id) {
    final runnerId = int.tryParse(id);
    if (runnerId == null) {
      return Response(
        400,
        body: jsonEncode({'error': 'Invalid runner ID'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
    final metrics = observer.metricsFor(runnerId);
    if (metrics == null) {
      return Response.notFound(
        jsonEncode({'error': 'Runner not found: $runnerId'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
    return Response.ok(jsonEncode(metrics.toJson()), headers: {'Content-Type': 'application/json'});
  });

  return router;
}
