@Tags(['integration'])
library;

import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

/// Integration tests for ClaudeCodeHarness against a real claude binary.
///
/// Run with: dart test packages/dartclaw_core/test/integration/ -t integration
/// Requires: `claude` binary in PATH and valid authentication.
void main() {
  late ClaudeCodeHarness harness;

  setUp(() async {
    // Skip if claude binary not available.
    final result = await Process.run('claude', ['--version']);
    if (result.exitCode != 0) {
      markTestSkipped('claude binary not available — skipping integration tests');
      return;
    }
    harness = ClaudeCodeHarness(cwd: Directory.current.path);
  });

  tearDown(() async {
    await harness.dispose();
  });

  test('start and initialize handshake succeeds', () async {
    await harness.start();
    expect(harness.state, WorkerState.idle);
  });

  test('simple turn returns result with text delta events', () async {
    await harness.start();

    final events = <BridgeEvent>[];
    final sub = harness.events.listen(events.add);

    try {
      final result = await harness.turn(
        sessionId: 'integration-test',
        messages: [
          {'role': 'user', 'content': 'Reply with exactly: INTEGRATION_TEST_OK'},
        ],
        systemPrompt: 'You are a test assistant. Follow instructions exactly.',
      );

      expect(result, isNotNull);
      expect(result['stop_reason'], isNotNull);
      expect(events.whereType<DeltaEvent>(), isNotEmpty, reason: 'should receive text deltas');
    } finally {
      await sub.cancel();
    }
  }, timeout: Timeout(Duration(seconds: 60)));

  test('multi-turn conversation preserves context', () async {
    await harness.start();

    // First turn — establish a fact.
    await harness.turn(
      sessionId: 'integration-multi',
      messages: [
        {'role': 'user', 'content': 'Remember: the secret word is FLAMINGO. Just acknowledge.'},
      ],
      systemPrompt: 'You are a test assistant.',
    );

    // Second turn — recall the fact.
    final events = <BridgeEvent>[];
    final sub = harness.events.listen(events.add);

    try {
      await harness.turn(
        sessionId: 'integration-multi',
        messages: [
          {'role': 'user', 'content': 'What was the secret word I told you? Reply with just the word.'},
        ],
        systemPrompt: 'You are a test assistant.',
      );

      final text = events.whereType<DeltaEvent>().map((e) => e.text).join();
      expect(text.toUpperCase(), contains('FLAMINGO'));
    } finally {
      await sub.cancel();
    }
  }, timeout: Timeout(Duration(seconds: 120)));
}
