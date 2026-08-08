import 'dart:convert';

import 'package:test/test.dart';

import 'harness_test_support.dart';

void main() {
  group('ClaudeCodeHarness permission optimization', () {
    test('uses --dangerously-skip-permissions when spawning claude', () async {
      final capturedArgs = await startHarnessAndCaptureArgs();

      expect(capturedArgs, contains('--dangerously-skip-permissions'));
    });

    test('does not pass --permission-prompt-tool stdio when spawning claude', () async {
      final capturedArgs = await startHarnessAndCaptureArgs();

      expect(capturedArgs, isNot(contains('--permission-prompt-tool')));
      expect(capturedArgs, isNot(contains('stdio')));
    });

    test('unexpected can_use_tool while permissions are skipped is denied', () async {
      final fake = makeCapturingClaudeProcess();
      final harness = buildClaudeHarness(processFactory: capturingInitFactory(process: fake));
      addTearDown(() async => harness.dispose());

      await harness.start();
      fake.emitStdout(
        jsonEncode({
          'type': 'control_request',
          'request_id': 'req-can-use-tool',
          'request': {'subtype': 'can_use_tool', 'tool_name': 'Bash', 'tool_use_id': 'tool-123'},
        }),
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      final response = fake.capturedStdinJson.lastWhere(
        (line) => (line['response'] as Map<String, dynamic>)['request_id'] == 'req-can-use-tool',
      );
      expect(response, {
        'type': 'control_response',
        'response': {
          'subtype': 'success',
          'request_id': 'req-can-use-tool',
          'response': {'behavior': 'deny', 'toolUseID': 'tool-123'},
        },
      });
    });
  });
}
