import 'package:dartclaw_core/dartclaw_core.dart' show ToolCallRecord, TurnTrace;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'api_test_helpers.dart';

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
  late ApiRouteTestClient client;

  setUp(() {
    db = openTaskDbInMemory();
    traceService = TurnTraceService(db);
    client = ApiRouteTestClient(traceRoutes(traceService).call);
  });

  tearDown(() async {
    await traceService.dispose();
  });

  group('GET /api/traces', () {
    test('returns empty traces and zero summary when no data', () async {
      final response = await client.expectResponse('GET', '/api/traces', status: 200);
      expect(response.headers['content-type'], contains('application/json'));

      final body = decodeObject(await response.readAsString());
      expect((body['traces'] as List), isEmpty);
      expect(body['summary']['traceCount'], 0);
      expect(body['summary']['totalTokens'], 0);
    });

    test('returns all traces with no filters', () async {
      await traceService.insert(_makeTrace(id: 'trace-1', taskId: 'task-A', inputTokens: 100));
      await traceService.insert(_makeTrace(id: 'trace-2', taskId: 'task-B', inputTokens: 200));

      final body = await client.expectJsonObject('GET', '/api/traces');
      expect((body['traces'] as List), hasLength(2));
      expect(body['summary']['traceCount'], 2);
    });

    test('filters by taskId', () async {
      await traceService.insert(_makeTrace(id: 'trace-1', taskId: 'task-A'));
      await traceService.insert(_makeTrace(id: 'trace-2', taskId: 'task-B'));

      final body = await client.expectJsonObject('GET', '/api/traces?taskId=task-A');
      final traces = body['traces'] as List;
      expect(traces, hasLength(1));
      expect((traces[0] as Map<String, dynamic>)['id'], 'trace-1');
    });

    test('filters by model', () async {
      await traceService.insert(_makeTrace(id: 'trace-1', model: 'claude-4-sonnet'));
      await traceService.insert(_makeTrace(id: 'trace-2', model: 'gpt-4'));

      final body = await client.expectJsonObject('GET', '/api/traces?model=claude-4-sonnet');
      final traces = body['traces'] as List;
      expect(traces, hasLength(1));
      expect((traces[0] as Map<String, dynamic>)['id'], 'trace-1');
    });

    test('filters by since/until date range', () async {
      await traceService.insert(_makeTrace(id: 'trace-early', startedAt: DateTime.utc(2026, 3, 1)));
      await traceService.insert(_makeTrace(id: 'trace-mid', startedAt: DateTime.utc(2026, 3, 15)));
      await traceService.insert(_makeTrace(id: 'trace-late', startedAt: DateTime.utc(2026, 3, 24)));

      final body = await client.expectJsonObject(
        'GET',
        '/api/traces?since=2026-03-10T00:00:00Z&until=2026-03-20T00:00:00Z',
      );
      final traces = body['traces'] as List;
      expect(traces, hasLength(1));
      expect((traces[0] as Map<String, dynamic>)['id'], 'trace-mid');
    });

    test('paginates with limit and offset', () async {
      for (var i = 0; i < 5; i++) {
        await traceService.insert(
          _makeTrace(id: 'trace-$i', taskId: 'task-P', startedAt: DateTime.utc(2026, 3, 24, i, 0, 0)),
        );
      }

      final page1 = await client.expectJsonObject('GET', '/api/traces?taskId=task-P&limit=2&offset=0');
      expect((page1['traces'] as List), hasLength(2));
      // summary reflects full result set
      expect(page1['summary']['traceCount'], 5);

      final page2 = await client.expectJsonObject('GET', '/api/traces?taskId=task-P&limit=2&offset=2');
      expect((page2['traces'] as List), hasLength(2));

      final page3 = await client.expectJsonObject('GET', '/api/traces?taskId=task-P&limit=2&offset=4');
      expect((page3['traces'] as List), hasLength(1));
    });

    test('summary reflects full filtered result, not just current page', () async {
      for (var i = 0; i < 4; i++) {
        await traceService.insert(_makeTrace(id: 'trace-$i', taskId: 'task-S', inputTokens: 100));
      }

      final body = await client.expectJsonObject('GET', '/api/traces?taskId=task-S&limit=1&offset=0');
      expect((body['traces'] as List), hasLength(1));
      expect(body['summary']['traceCount'], 4);
      expect(body['summary']['totalInputTokens'], 400);
    });

    test('returns 400 for invalid since date', () async {
      final body = await client.expectJsonObject('GET', '/api/traces?since=not-a-date', status: 400);
      expect((body['error'] as Map<String, dynamic>)['code'], 'INVALID_PARAM');
    });

    test('returns 400 for invalid until date', () async {
      final body = await client.expectJsonObject('GET', '/api/traces?until=bad', status: 400);
      expect((body['error'] as Map<String, dynamic>)['code'], 'INVALID_PARAM');
    });

    test('returns 400 for negative limit', () async {
      final body = await client.expectJsonObject('GET', '/api/traces?limit=-1', status: 400);
      expect((body['error'] as Map<String, dynamic>)['code'], 'INVALID_PARAM');
    });

    test('returns 400 for non-integer runnerId', () async {
      final body = await client.expectJsonObject('GET', '/api/traces?runnerId=abc', status: 400);
      expect((body['error'] as Map<String, dynamic>)['code'], 'INVALID_PARAM');
    });
  });

  group('GET /api/traces/<id>', () {
    test('returns 200 with the trace payload', () async {
      await traceService.insert(_makeTrace(id: 'trace-detail', taskId: 'task-1', provider: 'claude'));

      final body = await client.expectJsonObject('GET', '/api/traces/trace-detail');
      expect(body['id'], 'trace-detail');
      expect(body['taskId'], 'task-1');
      expect(body['provider'], 'claude');
    });

    test('returns 404 when the trace does not exist', () async {
      final body = await client.expectJsonObject('GET', '/api/traces/missing', status: 404);
      expect((body['error'] as Map<String, dynamic>)['code'], 'TRACE_NOT_FOUND');
    });
  });
}
