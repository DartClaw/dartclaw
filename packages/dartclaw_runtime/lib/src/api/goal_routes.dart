import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

import '../task/goal_service.dart';
import 'api_helpers.dart';

final _log = Logger('GoalRoutes');

/// Creates a [Router] exposing goal CRUD API endpoints.
Router goalRoutes(GoalService goals) {
  final router = Router();

  router.post('/api/goals', (Request request) async {
    try {
      final body = await readJsonObject(request);
      if (body.error != null) return body.error!;

      final idValue = body.value!['id'];
      final titleValue = body.value!['title'];
      final missionValue = body.value!['mission'];
      final parentGoalIdValue = body.value!['parentGoalId'];

      if (idValue != null && idValue is! String) {
        return errorResponse(400, 'INVALID_INPUT', 'id must be a string', {'field': 'id'});
      }
      if (titleValue != null && titleValue is! String) {
        return errorResponse(400, 'INVALID_INPUT', 'title must be a string', {'field': 'title'});
      }
      if (missionValue != null && missionValue is! String) {
        return errorResponse(400, 'INVALID_INPUT', 'mission must be a string', {'field': 'mission'});
      }
      if (parentGoalIdValue != null && parentGoalIdValue is! String) {
        return errorResponse(400, 'INVALID_INPUT', 'parentGoalId must be a string', {'field': 'parentGoalId'});
      }

      final id = (idValue as String?)?.trim();
      final title = (titleValue as String?)?.trim();
      final mission = (missionValue as String?)?.trim();
      final parentGoalId = (parentGoalIdValue as String?)?.trim();

      if (title == null || title.isEmpty) {
        return errorResponse(400, 'INVALID_INPUT', 'title must not be empty', {'field': 'title'});
      }
      if (mission == null || mission.isEmpty) {
        return errorResponse(400, 'INVALID_INPUT', 'mission must not be empty', {'field': 'mission'});
      }

      try {
        final goal = await goals.create(
          id: id == null || id.isEmpty ? const Uuid().v4() : id,
          title: title,
          mission: mission,
          parentGoalId: parentGoalId == null || parentGoalId.isEmpty ? null : parentGoalId,
        );
        return jsonResponse(201, goal.toJson());
      } on ArgumentError {
        return errorResponse(404, 'PARENT_GOAL_NOT_FOUND', 'Parent goal not found');
      } on StateError catch (e) {
        return errorResponse(409, 'GOAL_HIERARCHY_TOO_DEEP', e.message);
      }
    } catch (e, st) {
      _log.warning('Failed to create goal: $e', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to create goal');
    }
  });

  router.get('/api/goals', (Request request) async {
    try {
      final list = await goals.list();
      return jsonResponse(200, list.map((goal) => goal.toJson()).toList());
    } catch (e, st) {
      _log.warning('Failed to list goals: $e', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to list goals');
    }
  });

  router.get('/api/goals/<id>', (Request request, String id) async {
    try {
      final goal = await goals.get(id);
      if (goal == null) return _goalNotFound();
      return jsonResponse(200, goal.toJson());
    } catch (e, st) {
      _log.warning('Failed to get goal $id: $e', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to get goal');
    }
  });

  router.delete('/api/goals/<id>', (Request request, String id) async {
    try {
      await goals.delete(id);
      return Response(204);
    } catch (e, st) {
      _log.warning('Failed to delete goal $id: $e', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to delete goal');
    }
  });

  return router;
}

Response _goalNotFound() => errorResponse(404, 'GOAL_NOT_FOUND', 'Goal not found');
