import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  group('FakeCodexProcess', () {
    test('emits JSON-RPC helper lines on stdout', () async {
      final process = FakeCodexProcess();
      final lines = <Map<String, dynamic>>[];
      final sub = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .listen(lines.add);
      addTearDown(sub.cancel);

      process.emitInitializeResponse(id: 10, sessionId: 'sess-1', contextWindow: 16384);
      process.emitThreadStartResponse(id: 11, threadId: 'thread-1');
      process.emitTurnStarted();
      process.emitDelta('hello');
      process.emitItemStarted('command_execution', 'tool-1', {'command': 'pwd'});
      process.emitItemCompleted('command_execution', 'tool-1', {'aggregated_output': '/tmp', 'exit_code': 0});
      process.emitApprovalRequest(requestId: 12, toolUseId: 'tool-1');
      process.emitTurnCompleted(inputTokens: 4, outputTokens: 9, cachedInputTokens: 2);
      process.emitTurnFailed('boom');
      process.exit(0);

      await process.exitCode;
      await sub.asFuture<void>();

      expect(lines, hasLength(9));
      expect(lines[0]['id'], 10);
      expect(lines[0]['result'], containsPair('session_id', 'sess-1'));
      expect(lines[1]['result'], containsPair('thread_id', 'thread-1'));
      expect(lines[2]['method'], 'turn/started');
      expect(lines[3]['params'], containsPair('delta', 'hello'));
      expect((lines[4]['params'] as Map<String, dynamic>)['item'], containsPair('command', 'pwd'));
      expect((lines[5]['params'] as Map<String, dynamic>)['item'], containsPair('aggregated_output', '/tmp'));
      expect(lines[6]['method'], 'control/approval');
      expect((lines[7]['params'] as Map<String, dynamic>)['usage'], containsPair('cached_input_tokens', 2));
      expect(lines[8]['method'], 'turn/failed');
    });

    test('captures stdin JSON messages and records close and kill', () async {
      final process = FakeCodexProcess();

      process.stdin.writeln('{"id":1,"method":"initialize","params":{}}');
      process.stdin.add(utf8.encode('{"method":"turn/start","params":{"content":[]}}\n'));
      await process.stdin.close();

      expect(process.stdinClosed, isTrue);
      expect(process.sentMessages, [
        {'id': 1, 'method': 'initialize', 'params': <String, dynamic>{}},
        {
          'method': 'turn/start',
          'params': {'content': <dynamic>[]},
        },
      ]);

      expect(process.kill(ProcessSignal.sigterm), isTrue);
      expect(process.lastSignal, ProcessSignal.sigterm);
    });

    test('can drive exit code from an injected future', () async {
      final exitCodeCompleter = Completer<int>();
      final process = FakeCodexProcess(exitCodeFuture: exitCodeCompleter.future);

      exitCodeCompleter.complete(23);
      expect(await process.exitCode, 23);
    });
  });
}
