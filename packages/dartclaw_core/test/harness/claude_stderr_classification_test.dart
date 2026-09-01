import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'harness_test_support.dart';

void main() {
  test('structured terminal results classify turns independently of provider stderr', () async {
    final records = <LogRecord>[];
    final oldLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(() async {
      Logger.root.level = oldLevel;
      await subscription.cancel();
    });

    for (final terminalCase in [
      (
        name: 'success',
        payload: const {'type': 'result', 'is_error': false, 'stop_reason': 'end_turn', 'result': 'ok'},
        isError: false,
        stopReason: 'end_turn',
      ),
      (
        name: 'error',
        payload: const {
          'type': 'result',
          'is_error': true,
          'stop_reason': 'stop_sequence',
          'result': 'provider failed',
        },
        isError: true,
        stopReason: 'error',
      ),
    ]) {
      for (final diagnostic in ['permission mode warning', 'Failed to authenticate: stderr-only noise']) {
        final fake = makeClaudeFakeProcess();
        final harness = buildClaudeHarness(processFactory: capturingInitFactory(process: fake));
        await harness.start();

        final turn = harness.turn(
          sessionId: '${terminalCase.name}-${diagnostic.length}',
          messages: const [
            {'role': 'user', 'content': 'continue'},
          ],
          systemPrompt: '',
        );
        await pumpEventQueue();
        records.clear();
        fake.emitStderr(diagnostic);
        fake.emitStdout(jsonEncode(terminalCase.payload));

        final result = await turn;
        await pumpEventQueue();
        expect(result.isError, terminalCase.isError, reason: diagnostic);
        expect(result.stopReason, terminalCase.stopReason, reason: diagnostic);
        expect(
          records.any((record) => record.loggerName == 'ClaudeCodeHarness' && record.message.contains(diagnostic)),
          isTrue,
        );
        await harness.dispose();
      }
    }
  });
}
