import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

import 'acp_test_support.dart';

void main() {
  group('ACP S03 minimal protocol events', () {
    test('adapter maps a prompt result to TextDelta and TurnComplete only', () {
      final messages = AcpProtocolAdapter().messagesForPromptResult(
        const AcpPromptResult(text: 'minimal response', inputTokens: 1, outputTokens: 2, stopReason: 'completed'),
      );

      expect(messages, [
        isA<TextDelta>().having((message) => message.text, 'text', 'minimal response'),
        isA<TurnComplete>()
            .having((message) => message.stopReason, 'stopReason', 'completed')
            .having((message) => message.outputTokens, 'outputTokens', 2),
      ]);
    });

    test('simple response emits TextDelta-equivalent bridge delta and no file or terminal effects', () async {
      final process = FakeAcpProcess();
      final harness = _harnessFor(process);
      addTearDown(harness.dispose);

      final startFuture = harness.start();
      await process.respondTo('initialize', {'protocolVersion': 1});
      await startFuture;

      final events = <BridgeEvent>[];
      final sub = harness.events.listen(events.add);
      final turnFuture = harness.turn(
        sessionId: 'session-1',
        messages: const [
          {'role': 'user', 'content': 'hello'},
        ],
        systemPrompt: '',
      );
      await process.respondTo('session/new', {'sessionId': 'acp-session-1'});
      await process.respondTo('session/prompt', {'text': 'minimal response'});
      await process.respondTo('session/close', {});
      await turnFuture;
      await sub.cancel();

      expect(events, contains(isA<DeltaEvent>().having((event) => event.text, 'text', 'minimal response')));
      expect(process.capturedStdinJson.map((message) => message['method']), isNot(contains('fs/read_text_file')));
      expect(process.capturedStdinJson.map((message) => message['method']), isNot(contains('fs/write_text_file')));
      expect(process.capturedStdinJson.map((message) => message['method']), isNot(contains('terminal/create')));
    });
  });
}

AcpHarness _harnessFor(FakeAcpProcess process) {
  return AcpHarness(
    cwd: '/',
    processFactory: (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async =>
        process,
  );
}
