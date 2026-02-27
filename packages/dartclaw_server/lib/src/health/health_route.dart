import 'dart:convert';

import 'package:shelf/shelf.dart';

import 'health_service.dart';

/// Returns a shelf [Handler] for `GET /health`.
Handler healthHandler(HealthService service) {
  return (Request request) {
    final status = service.getStatus();
    return Response.ok(
      jsonEncode(status),
      headers: {'Content-Type': 'application/json'},
    );
  };
}
