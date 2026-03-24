import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

Map<String, dynamic> _decodeObject(String body) => jsonDecode(body) as Map<String, dynamic>;

Future<Map<String, dynamic>> _getTraces(Handler handler, String query) async {
  final response = await handler(Request('GET', Uri.parse('http://localhost/api/traces$query')));
  return _decodeObject(await response.readAsString());
}

TurnTrace _makeTrace({
  required String id,
  String sessionId = 'sess-1',
  String? taskId,
  String? model,
  String? provider,
  DateTime? startedAt,
  int inputTokens = 0,
  int outputTokens = 0,
  List<ToolCallRecord> toolCalls = const [],
}) {
  final start = startedAt ?? DateTime.utc(2026, 3, 24, 10, 0, 0);
  return TurnTrace(
    id: id,
    sessionId: sessionId,
    taskId: taskId,
    model: model,
    provider: provider,
    startedAt: start,
    endedAt: start.add(const Duration(seconds: 5)),
    inputTokens: inputTokens,
    outputTokens: outputTokens,
    toolCalls: toolCalls,
  );
}

void main() {
  late Database db;
  late TurnTraceService traceService;
  late Handler handler;

  setUp(() {
    db = openTaskDbInMemory();
    traceService = TurnTraceService(db);
    handler = traceRoutes(traceService).call;
  });

  tearDown(() async {
    await traceService.dispose();
  });

  group('GET /api/traces', () {
    test('returns empty traces and zero summary when no data', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/traces')));
      expect(response.statusCode, 200);
      expect(response.headers['content-type'], contains('application/json'));

      final body = _decodeObject(await response.readAsString());
      expect((body['traces'] as List), isEmpty);
      expect(body['summary']['traceCount'], 0);
      expect(body['summary']['totalTokens'], 0);
    });

    test('returns all traces with no filters', () async {
      await traceService.insert(_makeTrace(id: 'trace-1', taskId: 'task-A', inputTokens: 100));
      await traceService.insert(_makeTrace(id: 'trace-2', taskId: 'task-B', inputTokens: 200));

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/traces')));
      expect(response.statusCode, 200);

      final body = _decodeObject(await response.readAsString());
      expect((body['traces'] as List), hasLength(2));
      expect(body['summary']['traceCount'], 2);
    });

    test('filters by taskId', () async {
      await traceService.insert(_makeTrace(id: 'trace-1', taskId: 'task-A'));
      await traceService.insert(_makeTrace(id: 'trace-2', taskId: 'task-B'));

      final body = await _getTraces(handler, '?taskId=task-A');
      final traces = body['traces'] as List;
      expect(traces, hasLength(1));
      expect((traces[0] as Map<String, dynamic>)['id'], 'trace-1');
    });

    test('filters by model', () async {
      await traceService.insert(_makeTrace(id: 'trace-1', model: 'claude-4-sonnet'));
      await traceService.insert(_makeTrace(id: 'trace-2', model: 'gpt-4'));

      final body = await _getTraces(handler, '?model=claude-4-sonnet');
      final traces = body['traces'] as List;
      expect(traces, hasLength(1));
      expect((traces[0] as Map<String, dynamic>)['id'], 'trace-1');
    });

    test('filters by since/until date range', () async {
      await traceService.insert(_makeTrace(
        id: 'trace-early',
        startedAt: DateTime.utc(2026, 3, 1),
      ));
      await traceService.insert(_makeTrace(
        id: 'trace-mid',
        startedAt: DateTime.utc(2026, 3, 15),
      ));
      await traceService.insert(_makeTrace(
        id: 'trace-late',
        startedAt: DateTime.utc(2026, 3, 24),
      ));

      final body = await _getTraces(handler, '?since=2026-03-10T00:00:00Z&until=2026-03-20T00:00:00Z');
      final traces = body['traces'] as List;
      expect(traces, hasLength(1));
      expect((traces[0] as Map<String, dynamic>)['id'], 'trace-mid');
    });

    test('paginates with limit and offset', () async {
      for (var i = 0; i < 5; i++) {
        await traceService.insert(_makeTrace(
          id: 'trace-$i',
          taskId: 'task-P',
          startedAt: DateTime.utc(2026, 3, 24, i, 0, 0),
        ));
      }

      final page1 = await _getTraces(handler, '?taskId=task-P&limit=2&offset=0');
      expect((page1['traces'] as List), hasLength(2));
      // summary reflects full result set
      expect(page1['summary']['traceCount'], 5);

      final page2 = await _getTraces(handler, '?taskId=task-P&limit=2&offset=2');
      expect((page2['traces'] as List), hasLength(2));

      final page3 = await _getTraces(handler, '?taskId=task-P&limit=2&offset=4');
      expect((page3['traces'] as List), hasLength(1));
    });

    test('summary reflects full filtered result, not just current page', () async {
      for (var i = 0; i < 4; i++) {
        await traceService.insert(_makeTrace(
          id: 'trace-$i',
          taskId: 'task-S',
          inputTokens: 100,
        ));
      }

      final body = await _getTraces(handler, '?taskId=task-S&limit=1&offset=0');
      expect((body['traces'] as List), hasLength(1));
      expect(body['summary']['traceCount'], 4);
      expect(body['summary']['totalInputTokens'], 400);
    });

    test('returns 400 for invalid since date', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/traces?since=not-a-date')));
      expect(response.statusCode, 400);

      final body = _decodeObject(await response.readAsString());
      expect((body['error'] as Map<String, dynamic>)['code'], 'INVALID_PARAM');
    });

    test('returns 400 for invalid until date', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/traces?until=bad')));
      expect(response.statusCode, 400);

      final body = _decodeObject(await response.readAsString());
      expect((body['error'] as Map<String, dynamic>)['code'], 'INVALID_PARAM');
    });

    test('returns 400 for negative limit', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/traces?limit=-1')));
      expect(response.statusCode, 400);

      final body = _decodeObject(await response.readAsString());
      expect((body['error'] as Map<String, dynamic>)['code'], 'INVALID_PARAM');
    });

    test('returns 400 for non-integer runnerId', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/traces?runnerId=abc')));
      expect(response.statusCode, 400);

      final body = _decodeObject(await response.readAsString());
      expect((body['error'] as Map<String, dynamic>)['code'], 'INVALID_PARAM');
    });
  });
}
