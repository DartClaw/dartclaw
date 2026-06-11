import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'api_test_helpers.dart';

void main() {
  late Database db;
  late SqliteTaskRepository taskRepository;
  late GoalService goals;
  late Handler handler;
  late ApiRouteTestClient api;

  setUp(() {
    db = openTaskDbInMemory();
    taskRepository = SqliteTaskRepository(db);
    goals = GoalService(SqliteGoalRepository(db));
    handler = goalRoutes(goals).call;
    api = ApiRouteTestClient(handler);
  });

  tearDown(() async {
    await goals.dispose();
    await taskRepository.dispose();
  });

  group('POST /api/goals', () {
    test('creates goal', () async {
      final body = await api.expectJsonObject(
        'POST',
        '/api/goals',
        json: {'title': 'Ship 0.8', 'mission': 'Deliver the release safely.'},
        status: 201,
      );

      expect(body['title'], 'Ship 0.8');
      expect(body['mission'], 'Deliver the release safely.');
      expect(body['id'], isNotEmpty);
    });

    test('creates goal with parent', () async {
      final parent = await goals.create(id: 'goal-root', title: 'Platform', mission: 'Strengthen the platform.');

      final body = await api.expectJsonObject(
        'POST',
        '/api/goals',
        json: {'title': 'Ship 0.8', 'mission': 'Deliver the release safely.', 'parentGoalId': parent.id},
        status: 201,
      );

      expect(body['parentGoalId'], 'goal-root');
    });

    test('returns 400 for missing title', () async {
      final code = await api.expectJsonErrorCode(
        'POST',
        '/api/goals',
        json: {'mission': 'Deliver the release safely.'},
        status: 400,
      );

      expect(code, 'INVALID_INPUT');
    });

    test('returns 400 for missing mission', () async {
      final code = await api.expectJsonErrorCode('POST', '/api/goals', json: {'title': 'Ship 0.8'}, status: 400);

      expect(code, 'INVALID_INPUT');
    });

    test('returns 400 for malformed field types', () async {
      final invalidTitle = await api.expectJsonErrorCode(
        'POST',
        '/api/goals',
        json: {'title': 123, 'mission': 'Deliver the release safely.'},
        status: 400,
      );
      expect(invalidTitle, 'INVALID_INPUT');

      final invalidMission = await api.expectJsonErrorCode(
        'POST',
        '/api/goals',
        json: {'title': 'Ship 0.8', 'mission': 123},
        status: 400,
      );
      expect(invalidMission, 'INVALID_INPUT');
    });

    test('returns 404 for missing parent', () async {
      final code = await api.expectJsonErrorCode(
        'POST',
        '/api/goals',
        json: {'title': 'Ship 0.8', 'mission': 'Deliver the release safely.', 'parentGoalId': 'missing'},
        status: 404,
      );

      expect(code, 'PARENT_GOAL_NOT_FOUND');
    });

    test('returns 409 for deep nesting', () async {
      await goals.create(id: 'root', title: 'Platform', mission: 'Strengthen the platform.');
      await goals.create(id: 'child', title: 'Release train', mission: 'Keep work aligned.', parentGoalId: 'root');

      final code = await api.expectJsonErrorCode(
        'POST',
        '/api/goals',
        json: {'title': 'Ship 0.8', 'mission': 'Deliver the release safely.', 'parentGoalId': 'child'},
        status: 409,
      );

      expect(code, 'GOAL_HIERARCHY_TOO_DEEP');
    });
  });

  group('GET /api/goals', () {
    test('lists all goals', () async {
      await goals.create(id: 'goal-1', title: 'First', mission: 'First mission.');
      await goals.create(id: 'goal-2', title: 'Second', mission: 'Second mission.');

      final body = await api.expectJsonList('GET', '/api/goals');

      expect(body, hasLength(2));
    });

    test('returns empty array when no goals exist', () async {
      final body = await api.expectJsonList('GET', '/api/goals');

      expect(body, isEmpty);
    });
  });

  group('GET /api/goals/<id>', () {
    test('returns goal detail', () async {
      await goals.create(id: 'goal-1', title: 'Ship 0.8', mission: 'Deliver the release safely.');

      final body = await api.expectJsonObject('GET', '/api/goals/goal-1');

      expect(body['title'], 'Ship 0.8');
    });

    test('returns 404 for missing goal', () async {
      final code = await api.expectJsonErrorCode('GET', '/api/goals/missing', status: 404);

      expect(code, 'GOAL_NOT_FOUND');
    });
  });

  group('DELETE /api/goals/<id>', () {
    test('deletes goal', () async {
      await goals.create(id: 'goal-1', title: 'Ship 0.8', mission: 'Deliver the release safely.');

      await api.expectResponse('DELETE', '/api/goals/goal-1', status: 204);

      expect(await goals.get('goal-1'), isNull);
    });

    test('is silent for missing goal', () async {
      await api.expectResponse('DELETE', '/api/goals/missing', status: 204);
    });
  });
}
