import 'package:dartclaw_core/dartclaw_core.dart' show computeEffectiveTokens;
import 'package:test/test.dart';

/// Focused unit coverage for the billing-weighted `effective_tokens` arithmetic
/// that `WorkflowOneShotRunner` accumulates into `session_cost` KV entries via
/// `computeEffectiveTokens`. The integration suites
/// (`task_executor_workflow_oneshot_test.dart`) prove the executor mirrors
/// these values end-to-end; this suite pins the pure math with the SAME
/// expected values so a weighting regression surfaces here, fast, without a
/// `/bin/sh` subprocess.
void main() {
  group('computeEffectiveTokens', () {
    test('fresh input + output, cache reads weighted at 0.1x (session_cost shape parity)', () {
      // Transcribed from the executor integration assertion: input 120,
      // output 100, cache_read 160, cache_write 0 -> effective 236.
      expect(
        computeEffectiveTokens(inputTokens: 120, outputTokens: 100, cacheReadTokens: 160, cacheWriteTokens: 0),
        236,
      );
    });

    test('cumulative-delta session totals weight cache reads at 0.1x', () {
      // Transcribed from the cumulative-Codex / baseline-subtraction integration
      // assertions: input 50, output 25, cache_read 120, cache_write 0 ->
      // effective 87.
      expect(computeEffectiveTokens(inputTokens: 50, outputTokens: 25, cacheReadTokens: 120, cacheWriteTokens: 0), 87);
    });

    test('pre-existing session baseline value weights cache reads at 0.1x', () {
      // Transcribed from the seeded continued-session baseline: input 20,
      // output 10, cache_read 80, cache_write 0 -> effective 38.
      expect(computeEffectiveTokens(inputTokens: 20, outputTokens: 10, cacheReadTokens: 80, cacheWriteTokens: 0), 38);
    });

    test('cache writes weighted at 1.25x (truncating integer division)', () {
      expect(computeEffectiveTokens(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 100), 125);
      // Truncation: 4 * 125 // 100 = 5; 7 * 125 // 100 = 8.
      expect(computeEffectiveTokens(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 4), 5);
    });

    test('zero usage yields zero effective tokens', () {
      expect(computeEffectiveTokens(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0), 0);
    });
  });
}
