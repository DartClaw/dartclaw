import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

import 'acp_test_support.dart';

void main() {
  group('ACP harness S04 event routing', () {
    test('emits ordered DeltaEvent, ToolUseEvent, and ToolResultEvent without thought response pollution', () async {
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
      await process.waitForRequest('session/prompt');
      process.emitLine({
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': {'type': 'agent_message_chunk', 'text': 'visible one '},
      });
      process.emitLine({
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': {'type': 'agent_thought_chunk', 'text': 'private thought'},
      });
      process.emitLine({
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': {'type': 'tool_call', 'id': 'tool-1', 'title': 'Read config'},
      });
      process.emitLine({
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': {'type': 'tool_result', 'id': 'tool-1', 'output': 'ok'},
      });
      await process.respondTo('session/prompt', {'text': 'visible two'});
      await process.respondTo('session/close', {});

      final result = await turnFuture;
      await sub.cancel();

      expect(result['response'], 'visible two');
      expect(events, [
        isA<DeltaEvent>().having((event) => event.text, 'text', 'visible one '),
        isA<ProviderProgressBridgeEvent>()
            .having((event) => event.kind, 'kind', 'agent_thought_chunk')
            .having((event) => event.text, 'text', 'private thought'),
        isA<ToolUseEvent>()
            .having((event) => event.toolId, 'toolId', 'tool-1')
            .having((event) => event.toolName, 'toolName', 'Read config'),
        isA<ToolResultEvent>()
            .having((event) => event.toolId, 'toolId', 'tool-1')
            .having((event) => event.output, 'output', 'ok'),
        isA<DeltaEvent>().having((event) => event.text, 'text', 'visible two'),
      ]);
      expect(events.whereType<DeltaEvent>().map((event) => event.text).join(), isNot(contains('private thought')));
    });

    test('completed and cancelled ACP responses return normalized result maps', () async {
      final process = FakeAcpProcess();
      final harness = _harnessFor(process);
      addTearDown(harness.dispose);

      final startFuture = harness.start();
      await process.respondTo('initialize', {'protocolVersion': 1});
      await startFuture;

      final turnFuture = harness.turn(
        sessionId: 'session-1',
        messages: const [
          {'role': 'user', 'content': 'hello'},
        ],
        systemPrompt: '',
      );
      await process.respondTo('session/new', {'sessionId': 'acp-session-1'});
      await process.respondTo('session/prompt', {
        'text': 'done',
        'stopReason': 'end_turn',
        'inputTokens': 3,
        'outputTokens': 5,
        'cacheReadTokens': 7,
        'cacheWriteTokens': 11,
        'title': 'Plan cleanup',
      });
      await process.respondTo('session/close', {});

      final completed = await turnFuture;

      expect(completed['stop_reason'], 'end_turn');
      expect(completed['input_tokens'], 3);
      expect(completed['output_tokens'], 5);
      expect(completed['cache_read_tokens'], 7);
      expect(completed['cache_write_tokens'], 11);
      expect(completed['session_title'], 'Plan cleanup');
      expect(harness.supportsCachedTokens, isTrue);
    });

    test('malformed raw JSON-RPC stdout is skipped and later valid session/update still streams', () async {
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
      await process.waitForRequest('session/prompt');
      process.emitStdout('{not json');
      process.emitLine({
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': {'type': 'agent_message_chunk', 'text': 'still streams'},
      });
      await process.respondTo('session/prompt', {'text': ''});
      await process.respondTo('session/close', {});

      await turnFuture;
      await sub.cancel();

      expect(events.whereType<DeltaEvent>().map((event) => event.text), contains('still streams'));
    });

    test('stale post-cancel session/update is ignored after cancelled response wins', () async {
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
          {'role': 'user', 'content': 'slow'},
        ],
        systemPrompt: '',
      );
      await process.respondTo('session/new', {'sessionId': 'acp-session-1'});
      await process.waitForRequest('session/prompt');
      final cancelFuture = harness.cancel();
      await process.respondTo('session/cancel', {});
      await cancelFuture;
      process.emitLine({
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': {'type': 'agent_message_chunk', 'text': 'late stale text'},
      });
      await process.respondTo('session/close', {});

      final result = await turnFuture;
      await sub.cancel();

      expect(result['stop_reason'], 'cancelled');
      expect(events.whereType<DeltaEvent>().map((event) => event.text), isNot(contains('late stale text')));
    });

    test('cancel without ACP peer response still settles as cancelled and stops the harness', () async {
      final process = FakeAcpProcess();
      final harness = _harnessFor(process);
      addTearDown(harness.dispose);

      final startFuture = harness.start();
      await process.respondTo('initialize', {'protocolVersion': 1});
      await startFuture;

      final turnFuture = harness.turn(
        sessionId: 'session-1',
        messages: const [
          {'role': 'user', 'content': 'slow'},
        ],
        systemPrompt: '',
      );
      await process.respondTo('session/new', {'sessionId': 'acp-session-1'});
      await process.waitForRequest('session/prompt');

      await harness.cancel();
      await process.respondTo('session/close', {});

      final result = await turnFuture;

      expect(result['stop_reason'], 'cancelled');
      expect(process.capturedStdinJson.map((message) => message['method']), contains('session/cancel'));
      expect(process.killCalled, isTrue);
      expect(harness.state, WorkerState.stopped);
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
