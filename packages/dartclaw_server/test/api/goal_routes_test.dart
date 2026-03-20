import 'dart:convert';

import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

Future<String> _errorCode(Response res) async {
  final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
  return (body['error'] as Map<String, dynamic>)['code'] as String;
}

Map<String, dynamic> _decodeObject(String body) => jsonDecode(body) as Map<String, dynamic>;

List<dynamic> _decodeList(String body) => jsonDecode(body) as List<dynamic>;

Request _jsonRequest(String method, String path, [Map<String, dynamic>? body]) {
  return Request(
    method,
    Uri.parse('http://localhost$path'),
    body: body == null ? null : jsonEncode(body),
    headers: {'content-type': 'application/json'},
  );
}

void main() {
  late Database db;
  late SqliteTaskRepository taskRepository;
  late GoalService goals;
  late Handler handler;

  setUp(() {
    db = openTaskDbInMemory();
    taskRepository = SqliteTaskRepository(db);
    goals = GoalService(SqliteGoalRepository(db));
    handler = goalRoutes(goals).call;
  });

  tearDown(() async {
    await goals.dispose();
    await taskRepository.dispose();
  });

  group('POST /api/goals', () {
    test('creates goal', () async {
      final response = await handler(
        _jsonRequest('POST', '/api/goals', {'title': 'Ship 0.8', 'mission': 'Deliver the release safely.'}),
      );

      expect(response.statusCode, 201);
      final body = _decodeObject(await response.readAsString());
      expect(body['title'], 'Ship 0.8');
      expect(body['mission'], 'Deliver the release safely.');
      expect(body['id'], isNotEmpty);
    });

    test('creates goal with parent', () async {
      final parent = await goals.create(id: 'goal-root', title: 'Platform', mission: 'Strengthen the platform.');

      final response = await handler(
        _jsonRequest('POST', '/api/goals', {
          'title': 'Ship 0.8',
          'mission': 'Deliver the release safely.',
          'parentGoalId': parent.id,
        }),
      );

      expect(response.statusCode, 201);
      final body = _decodeObject(await response.readAsString());
      expect(body['parentGoalId'], 'goal-root');
    });

    test('returns 400 for missing title', () async {
      final response = await handler(_jsonRequest('POST', '/api/goals', {'mission': 'Deliver the release safely.'}));

      expect(response.statusCode, 400);
      expect(await _errorCode(response), 'INVALID_INPUT');
    });

    test('returns 400 for missing mission', () async {
      final response = await handler(_jsonRequest('POST', '/api/goals', {'title': 'Ship 0.8'}));

      expect(response.statusCode, 400);
      expect(await _errorCode(response), 'INVALID_INPUT');
    });

    test('returns 400 for malformed field types', () async {
      final invalidTitle = await handler(
        _jsonRequest('POST', '/api/goals', {'title': 123, 'mission': 'Deliver the release safely.'}),
      );
      expect(invalidTitle.statusCode, 400);
      expect(await _errorCode(invalidTitle), 'INVALID_INPUT');

      final invalidMission = await handler(_jsonRequest('POST', '/api/goals', {'title': 'Ship 0.8', 'mission': 123}));
      expect(invalidMission.statusCode, 400);
      expect(await _errorCode(invalidMission), 'INVALID_INPUT');
    });

    test('returns 404 for missing parent', () async {
      final response = await handler(
        _jsonRequest('POST', '/api/goals', {
          'title': 'Ship 0.8',
          'mission': 'Deliver the release safely.',
          'parentGoalId': 'missing',
        }),
      );

      expect(response.statusCode, 404);
      expect(await _errorCode(response), 'PARENT_GOAL_NOT_FOUND');
    });

    test('returns 409 for deep nesting', () async {
      await goals.create(id: 'root', title: 'Platform', mission: 'Strengthen the platform.');
      await goals.create(id: 'child', title: 'Release train', mission: 'Keep work aligned.', parentGoalId: 'root');

      final response = await handler(
        _jsonRequest('POST', '/api/goals', {
          'title': 'Ship 0.8',
          'mission': 'Deliver the release safely.',
          'parentGoalId': 'child',
        }),
      );

      expect(response.statusCode, 409);
      expect(await _errorCode(response), 'GOAL_HIERARCHY_TOO_DEEP');
    });
  });

  group('GET /api/goals', () {
    test('lists all goals', () async {
      await goals.create(id: 'goal-1', title: 'First', mission: 'First mission.');
      await goals.create(id: 'goal-2', title: 'Second', mission: 'Second mission.');

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/goals')));

      expect(response.statusCode, 200);
      expect(_decodeList(await response.readAsString()), hasLength(2));
    });

    test('returns empty array when no goals exist', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/goals')));

      expect(response.statusCode, 200);
      expect(_decodeList(await response.readAsString()), isEmpty);
    });
  });

  group('GET /api/goals/<id>', () {
    test('returns goal detail', () async {
      await goals.create(id: 'goal-1', title: 'Ship 0.8', mission: 'Deliver the release safely.');

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/goals/goal-1')));

      expect(response.statusCode, 200);
      final body = _decodeObject(await response.readAsString());
      expect(body['title'], 'Ship 0.8');
    });

    test('returns 404 for missing goal', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/goals/missing')));

      expect(response.statusCode, 404);
      expect(await _errorCode(response), 'GOAL_NOT_FOUND');
    });
  });

  group('DELETE /api/goals/<id>', () {
    test('deletes goal', () async {
      await goals.create(id: 'goal-1', title: 'Ship 0.8', mission: 'Deliver the release safely.');

      final response = await handler(_jsonRequest('DELETE', '/api/goals/goal-1'));

      expect(response.statusCode, 204);
      expect(await goals.get('goal-1'), isNull);
    });

    test('is silent for missing goal', () async {
      final response = await handler(_jsonRequest('DELETE', '/api/goals/missing'));

      expect(response.statusCode, 204);
    });
  });
}
