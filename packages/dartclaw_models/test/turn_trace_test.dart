import 'package:dartclaw_models/dartclaw_models.dart';
import 'package:test/test.dart';

void main() {
  final start = DateTime.utc(2026, 3, 24, 10, 0, 0);
  final end = DateTime.utc(2026, 3, 24, 10, 0, 5);

  test('constructs with all required fields', () {
    final trace = TurnTrace(id: 'id-1', sessionId: 'sess-1', startedAt: start, endedAt: end);
    expect(trace.id, 'id-1');
    expect(trace.sessionId, 'sess-1');
    expect(trace.taskId, isNull);
    expect(trace.runnerId, isNull);
    expect(trace.model, isNull);
    expect(trace.provider, isNull);
    expect(trace.inputTokens, 0);
    expect(trace.outputTokens, 0);
    expect(trace.cacheReadTokens, 0);
    expect(trace.cacheWriteTokens, 0);
    expect(trace.isError, isFalse);
    expect(trace.errorType, isNull);
    expect(trace.toolCalls, isEmpty);
  });

  test('constructs with all optional fields', () {
    final toolCalls = [ToolCallRecord(name: 'bash', success: true, durationMs: 100, context: 'dart test')];
    final trace = TurnTrace(
      id: 'id-2',
      sessionId: 'sess-2',
      taskId: 'task-1',
      runnerId: 1,
      model: 'claude-4-sonnet',
      provider: 'anthropic',
      startedAt: start,
      endedAt: end,
      inputTokens: 1200,
      outputTokens: 350,
      cacheReadTokens: 800,
      cacheWriteTokens: 50,
      isError: true,
      errorType: 'timeout',
      toolCalls: toolCalls,
    );
    expect(trace.taskId, 'task-1');
    expect(trace.runnerId, 1);
    expect(trace.model, 'claude-4-sonnet');
    expect(trace.provider, 'anthropic');
    expect(trace.inputTokens, 1200);
    expect(trace.outputTokens, 350);
    expect(trace.cacheReadTokens, 800);
    expect(trace.cacheWriteTokens, 50);
    expect(trace.isError, isTrue);
    expect(trace.errorType, 'timeout');
    expect(trace.toolCalls, hasLength(1));
  });

  test('totalTokens computed correctly', () {
    final trace = TurnTrace(
      id: 'id-3',
      sessionId: 'sess-3',
      startedAt: start,
      endedAt: end,
      inputTokens: 1000,
      outputTokens: 300,
    );
    expect(trace.totalTokens, 1300);
  });

  test('durationMs computed correctly', () {
    final trace = TurnTrace(id: 'id-4', sessionId: 'sess-4', startedAt: start, endedAt: end);
    expect(trace.durationMs, 5000);
  });

  test('toJson includes all fields', () {
    final toolCalls = [ToolCallRecord(name: 'read', success: true, durationMs: 50, context: 'README.md')];
    final trace = TurnTrace(
      id: 'id-5',
      sessionId: 'sess-5',
      taskId: 'task-2',
      runnerId: 0,
      model: 'claude-opus-4',
      provider: 'anthropic',
      startedAt: start,
      endedAt: end,
      inputTokens: 100,
      outputTokens: 50,
      cacheReadTokens: 200,
      cacheWriteTokens: 10,
      isError: false,
      toolCalls: toolCalls,
    );
    final json = trace.toJson();
    expect(json['id'], 'id-5');
    expect(json['sessionId'], 'sess-5');
    expect(json['taskId'], 'task-2');
    expect(json['runnerId'], 0);
    expect(json['model'], 'claude-opus-4');
    expect(json['provider'], 'anthropic');
    expect(json['inputTokens'], 100);
    expect(json['outputTokens'], 50);
    expect(json['cacheReadTokens'], 200);
    expect(json['cacheWriteTokens'], 10);
    expect(json['isError'], false);
    expect(json['totalTokens'], 150);
    expect(json['durationMs'], 5000);
    expect((json['toolCalls'] as List), hasLength(1));
    expect(json.containsKey('errorType'), isFalse);
  });

  test('optional fields omitted from toJson when null', () {
    final trace = TurnTrace(id: 'id-6', sessionId: 'sess-6', startedAt: start, endedAt: end);
    final json = trace.toJson();
    expect(json.containsKey('taskId'), isFalse);
    expect(json.containsKey('runnerId'), isFalse);
    expect(json.containsKey('model'), isFalse);
    expect(json.containsKey('provider'), isFalse);
    expect(json.containsKey('errorType'), isFalse);
  });

  test('fromJson round-trip with all fields', () {
    final toolCalls = [
      ToolCallRecord(name: 'bash', success: false, durationMs: 30, errorType: 'tool_error', context: 'dart test'),
    ];
    final original = TurnTrace(
      id: 'id-7',
      sessionId: 'sess-7',
      taskId: 'task-3',
      runnerId: 2,
      model: 'gpt-4',
      provider: 'openai',
      startedAt: start,
      endedAt: end,
      inputTokens: 500,
      outputTokens: 200,
      cacheReadTokens: 100,
      cacheWriteTokens: 20,
      isError: true,
      errorType: 'model_error',
      toolCalls: toolCalls,
    );
    final restored = TurnTrace.fromJson(original.toJson());
    expect(restored.id, original.id);
    expect(restored.sessionId, original.sessionId);
    expect(restored.taskId, original.taskId);
    expect(restored.runnerId, original.runnerId);
    expect(restored.model, original.model);
    expect(restored.provider, original.provider);
    expect(restored.startedAt.toIso8601String(), original.startedAt.toIso8601String());
    expect(restored.endedAt.toIso8601String(), original.endedAt.toIso8601String());
    expect(restored.inputTokens, original.inputTokens);
    expect(restored.outputTokens, original.outputTokens);
    expect(restored.cacheReadTokens, original.cacheReadTokens);
    expect(restored.cacheWriteTokens, original.cacheWriteTokens);
    expect(restored.isError, original.isError);
    expect(restored.errorType, original.errorType);
    expect(restored.toolCalls.length, 1);
    expect(restored.toolCalls[0].name, 'bash');
    expect(restored.toolCalls[0].context, 'dart test');
  });

  test('toolCalls empty list round-trips correctly', () {
    final trace = TurnTrace(id: 'id-8', sessionId: 'sess-8', startedAt: start, endedAt: end, toolCalls: const []);
    final restored = TurnTrace.fromJson(trace.toJson());
    expect(restored.toolCalls, isEmpty);
  });

  test('equality and hashCode based on identity fields', () {
    final a = TurnTrace(id: 'id-9', sessionId: 'sess-9', startedAt: start, endedAt: end);
    final b = TurnTrace(id: 'id-9', sessionId: 'sess-9', startedAt: start, endedAt: end);
    final c = TurnTrace(id: 'id-X', sessionId: 'sess-9', startedAt: start, endedAt: end);
    expect(a, equals(b));
    expect(a.hashCode, equals(b.hashCode));
    expect(a, isNot(equals(c)));
  });
}
