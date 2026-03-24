import 'package:dartclaw_models/dartclaw_models.dart';
import 'package:test/test.dart';

void main() {
  test('constructs with all defaults', () {
    const summary = TurnTraceSummary();
    expect(summary.totalInputTokens, 0);
    expect(summary.totalOutputTokens, 0);
    expect(summary.totalCacheReadTokens, 0);
    expect(summary.totalCacheWriteTokens, 0);
    expect(summary.totalDurationMs, 0);
    expect(summary.totalToolCalls, 0);
    expect(summary.traceCount, 0);
    expect(summary.totalTokens, 0);
  });

  test('totalTokens computed correctly', () {
    const summary = TurnTraceSummary(totalInputTokens: 12000, totalOutputTokens: 3500);
    expect(summary.totalTokens, 15500);
  });

  test('toJson output shape correct', () {
    const summary = TurnTraceSummary(
      totalInputTokens: 100,
      totalOutputTokens: 50,
      totalCacheReadTokens: 200,
      totalCacheWriteTokens: 10,
      totalDurationMs: 5000,
      totalToolCalls: 3,
      traceCount: 2,
    );
    final json = summary.toJson();
    expect(json['totalInputTokens'], 100);
    expect(json['totalOutputTokens'], 50);
    expect(json['totalCacheReadTokens'], 200);
    expect(json['totalCacheWriteTokens'], 10);
    expect(json['totalTokens'], 150);
    expect(json['totalDurationMs'], 5000);
    expect(json['totalToolCalls'], 3);
    expect(json['traceCount'], 2);
  });

  test('fromJson round-trip', () {
    const original = TurnTraceSummary(
      totalInputTokens: 500,
      totalOutputTokens: 200,
      totalCacheReadTokens: 300,
      totalCacheWriteTokens: 0,
      totalDurationMs: 8000,
      totalToolCalls: 5,
      traceCount: 3,
    );
    final restored = TurnTraceSummary.fromJson(original.toJson());
    expect(restored.totalInputTokens, original.totalInputTokens);
    expect(restored.totalOutputTokens, original.totalOutputTokens);
    expect(restored.totalCacheReadTokens, original.totalCacheReadTokens);
    expect(restored.totalCacheWriteTokens, original.totalCacheWriteTokens);
    expect(restored.totalDurationMs, original.totalDurationMs);
    expect(restored.totalToolCalls, original.totalToolCalls);
    expect(restored.traceCount, original.traceCount);
  });

  test('equality and hashCode', () {
    const a = TurnTraceSummary(totalInputTokens: 100, traceCount: 2);
    const b = TurnTraceSummary(totalInputTokens: 100, traceCount: 2);
    const c = TurnTraceSummary(totalInputTokens: 200, traceCount: 2);
    expect(a, equals(b));
    expect(a.hashCode, equals(b.hashCode));
    expect(a, isNot(equals(c)));
  });
}
