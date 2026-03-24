import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

TurnTrace _makeTrace({
  required String id,
  String sessionId = 'sess-1',
  String? taskId,
  int? runnerId,
  String? model,
  String? provider,
  DateTime? startedAt,
  DateTime? endedAt,
  int inputTokens = 0,
  int outputTokens = 0,
  int cacheReadTokens = 0,
  int cacheWriteTokens = 0,
  bool isError = false,
  String? errorType,
  List<ToolCallRecord> toolCalls = const [],
}) {
  final start = startedAt ?? DateTime.utc(2026, 3, 24, 10, 0, 0);
  final end = endedAt ?? start.add(const Duration(seconds: 5));
  return TurnTrace(
    id: id,
    sessionId: sessionId,
    taskId: taskId,
    runnerId: runnerId,
    model: model,
    provider: provider,
    startedAt: start,
    endedAt: end,
    inputTokens: inputTokens,
    outputTokens: outputTokens,
    cacheReadTokens: cacheReadTokens,
    cacheWriteTokens: cacheWriteTokens,
    isError: isError,
    errorType: errorType,
    toolCalls: toolCalls,
  );
}

void main() {
  late Database db;
  late TurnTraceService service;

  setUp(() {
    db = openTaskDbInMemory();
    service = TurnTraceService(db);
  });

  tearDown(() async {
    await service.dispose();
  });

  test('creates turns table and indexes', () {
    final names =
        db
            .select("SELECT name FROM sqlite_master WHERE type IN ('table', 'index') ORDER BY name")
            .map((row) => row['name'])
            .toList();
    expect(names, contains('turns'));
    expect(names, contains('idx_turns_session'));
    expect(names, contains('idx_turns_task'));
    expect(names, contains('idx_turns_started'));
    expect(names, contains('idx_turns_model'));
    expect(names, contains('idx_turns_provider'));
  });

  test('insert and retrieve by taskId', () async {
    final trace = _makeTrace(id: 'trace-1', taskId: 'task-A', inputTokens: 100, outputTokens: 50);
    await service.insert(trace);

    final result = await service.query(taskId: 'task-A');
    expect(result.traces, hasLength(1));
    expect(result.traces[0].id, 'trace-1');
    expect(result.traces[0].inputTokens, 100);
    expect(result.traces[0].outputTokens, 50);
    expect(result.summary.traceCount, 1);
  });

  test('insert multiple traces and verify count', () async {
    await service.insert(_makeTrace(id: 'trace-1', taskId: 'task-B'));
    await service.insert(_makeTrace(id: 'trace-2', taskId: 'task-B'));
    await service.insert(_makeTrace(id: 'trace-3', taskId: 'task-C'));

    final resultB = await service.query(taskId: 'task-B');
    expect(resultB.traces, hasLength(2));
    expect(resultB.summary.traceCount, 2);

    final all = await service.query();
    expect(all.traces, hasLength(3));
  });

  test('query with sessionId filter', () async {
    await service.insert(_makeTrace(id: 'trace-1', sessionId: 'sess-A', taskId: 'task-1'));
    await service.insert(_makeTrace(id: 'trace-2', sessionId: 'sess-B', taskId: 'task-2'));

    final result = await service.query(sessionId: 'sess-A');
    expect(result.traces, hasLength(1));
    expect(result.traces[0].id, 'trace-1');
  });

  test('query with model filter', () async {
    await service.insert(_makeTrace(id: 'trace-1', model: 'claude-4-sonnet'));
    await service.insert(_makeTrace(id: 'trace-2', model: 'gpt-4'));

    final result = await service.query(model: 'claude-4-sonnet');
    expect(result.traces, hasLength(1));
    expect(result.traces[0].id, 'trace-1');
  });

  test('query with provider filter', () async {
    await service.insert(_makeTrace(id: 'trace-1', provider: 'anthropic'));
    await service.insert(_makeTrace(id: 'trace-2', provider: 'openai'));

    final result = await service.query(provider: 'anthropic');
    expect(result.traces, hasLength(1));
    expect(result.traces[0].id, 'trace-1');
  });

  test('query with since/until date range', () async {
    await service.insert(
      _makeTrace(id: 'trace-early', startedAt: DateTime.utc(2026, 3, 1, 10, 0, 0)),
    );
    await service.insert(
      _makeTrace(id: 'trace-mid', startedAt: DateTime.utc(2026, 3, 15, 10, 0, 0)),
    );
    await service.insert(
      _makeTrace(id: 'trace-late', startedAt: DateTime.utc(2026, 3, 24, 10, 0, 0)),
    );

    final result = await service.query(
      since: DateTime.utc(2026, 3, 10),
      until: DateTime.utc(2026, 3, 20),
    );
    expect(result.traces, hasLength(1));
    expect(result.traces[0].id, 'trace-mid');
  });

  test('query with limit/offset paginates correctly', () async {
    for (var i = 0; i < 5; i++) {
      await service.insert(
        _makeTrace(
          id: 'trace-$i',
          taskId: 'task-P',
          startedAt: DateTime.utc(2026, 3, 24, i, 0, 0),
        ),
      );
    }

    final page1 = await service.query(taskId: 'task-P', limit: 2, offset: 0);
    expect(page1.traces, hasLength(2));
    expect(page1.summary.traceCount, 5); // summary = full result

    final page2 = await service.query(taskId: 'task-P', limit: 2, offset: 2);
    expect(page2.traces, hasLength(2));

    final page3 = await service.query(taskId: 'task-P', limit: 2, offset: 4);
    expect(page3.traces, hasLength(1));
  });

  test('summary aggregates token sums, duration, tool call count, trace count', () async {
    final toolCalls = [
      ToolCallRecord(name: 'bash', success: true, durationMs: 100),
      ToolCallRecord(name: 'read', success: false, durationMs: 50, errorType: 'tool_error'),
    ];
    await service.insert(
      _makeTrace(
        id: 'trace-1',
        taskId: 'task-S',
        inputTokens: 100,
        outputTokens: 50,
        cacheReadTokens: 200,
        cacheWriteTokens: 10,
        startedAt: DateTime.utc(2026, 3, 24, 10, 0, 0),
        endedAt: DateTime.utc(2026, 3, 24, 10, 0, 5), // 5s = 5000ms
        toolCalls: toolCalls,
      ),
    );
    await service.insert(
      _makeTrace(
        id: 'trace-2',
        taskId: 'task-S',
        inputTokens: 200,
        outputTokens: 80,
        cacheReadTokens: 50,
        cacheWriteTokens: 0,
        startedAt: DateTime.utc(2026, 3, 24, 11, 0, 0),
        endedAt: DateTime.utc(2026, 3, 24, 11, 0, 3), // 3s = 3000ms
        toolCalls: [ToolCallRecord(name: 'write', success: true, durationMs: 80)],
      ),
    );

    final summary = await service.summaryForTask('task-S');
    expect(summary.totalInputTokens, 300);
    expect(summary.totalOutputTokens, 130);
    expect(summary.totalCacheReadTokens, 250);
    expect(summary.totalCacheWriteTokens, 10);
    expect(summary.totalDurationMs, 8000);
    expect(summary.totalToolCalls, 3);
    expect(summary.traceCount, 2);
    expect(summary.totalTokens, 430);
  });

  test('insert with null taskId (session-only trace) succeeds', () async {
    final trace = _makeTrace(id: 'trace-no-task', sessionId: 'sess-only');
    await service.insert(trace);

    final result = await service.query(sessionId: 'sess-only');
    expect(result.traces, hasLength(1));
    expect(result.traces[0].taskId, isNull);
  });

  test('insert with empty toolCalls stores and reads back as empty list', () async {
    final trace = _makeTrace(id: 'trace-no-tools', taskId: 'task-T', toolCalls: const []);
    await service.insert(trace);

    final result = await service.query(taskId: 'task-T');
    expect(result.traces[0].toolCalls, isEmpty);
  });

  test('is_error stored as 0/1 and read back as bool', () async {
    await service.insert(_makeTrace(id: 'trace-ok', taskId: 'task-E', isError: false));
    await service.insert(_makeTrace(id: 'trace-err', taskId: 'task-E', isError: true, errorType: 'crash'));

    final result = await service.query(taskId: 'task-E');
    expect(result.traces, hasLength(2));
    final ok = result.traces.firstWhere((t) => t.id == 'trace-ok');
    final err = result.traces.firstWhere((t) => t.id == 'trace-err');
    expect(ok.isError, isFalse);
    expect(err.isError, isTrue);
    expect(err.errorType, 'crash');
  });

  test('tool_calls JSON round-trips through insert + query', () async {
    final toolCalls = [
      ToolCallRecord(name: 'bash', success: true, durationMs: 120),
      ToolCallRecord(name: 'edit', success: false, durationMs: 30, errorType: 'tool_error'),
    ];
    final trace = _makeTrace(id: 'trace-tc', taskId: 'task-TC', toolCalls: toolCalls);
    await service.insert(trace);

    final result = await service.query(taskId: 'task-TC');
    final restored = result.traces[0];
    expect(restored.toolCalls, hasLength(2));
    expect(restored.toolCalls[0].name, 'bash');
    expect(restored.toolCalls[0].success, isTrue);
    expect(restored.toolCalls[1].name, 'edit');
    expect(restored.toolCalls[1].errorType, 'tool_error');
  });

  test('summaryForTask with no traces returns zero-initialized summary', () async {
    final summary = await service.summaryForTask('no-such-task');
    expect(summary.traceCount, 0);
    expect(summary.totalTokens, 0);
    expect(summary.totalDurationMs, 0);
  });

  test('query with no matching filters returns empty traces and zero summary', () async {
    final result = await service.query(taskId: 'non-existent');
    expect(result.traces, isEmpty);
    expect(result.summary.traceCount, 0);
  });
}
