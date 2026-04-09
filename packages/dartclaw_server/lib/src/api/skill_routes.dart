import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' show SkillRegistry;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

/// Creates a [Router] exposing skill discovery API endpoints.
Router skillRoutes(SkillRegistry skills) {
  final router = Router();

  // GET /api/skills
  router.get('/api/skills', (Request request) {
    final allSkills = skills.listAll();
    return Response.ok(
      jsonEncode({
        'skills': allSkills.map((s) => s.toJson()).toList(),
        'count': allSkills.length,
      }),
      headers: {'Content-Type': 'application/json'},
    );
  });

  return router;
}
