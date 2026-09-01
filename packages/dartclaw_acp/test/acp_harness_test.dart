import 'package:dartclaw_acp/dartclaw_acp.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

import 'acp_test_support.dart';

void main() {
  test('ACP refuses provider-session resume before creating a provider session', () async {
    final process = FakeAcpProcess();
    final harness = _harnessFor(process);
    addTearDown(harness.dispose);

    final startFuture = harness.start();
    await process.respondTo('initialize', {'protocolVersion': 1});
    await startFuture;
    final sentBeforeTurn = process.capturedStdinJson.length;

    for (final input in [
      (providerSessionId: 'acp-1', requestProviderSessionResume: false),
      (providerSessionId: null, requestProviderSessionResume: true),
    ]) {
      await expectLater(
        harness.turn(
          sessionId: 'resume-refused',
          messages: const [
            {'role': 'user', 'content': 'continue'},
          ],
          systemPrompt: '',
          providerSessionId: input.providerSessionId,
          requestProviderSessionResume: input.requestProviderSessionResume,
        ),
        throwsA(
          isA<AcpHarnessException>()
              .having((error) => error.code, 'code', 'ACP_UNSUPPORTED_CAPABILITY')
              .having((error) => error.message, 'message', contains('ACP'))
              .having((error) => error.message, 'message', contains('provider session resume')),
        ),
      );
      expect(harness.state, WorkerState.idle);
    }

    expect(harness.supportsProviderSessionResume, isFalse);
    expect(process.capturedStdinJson.length, sentBeforeTurn);
    expect(process.capturedStdinJson.where((message) => message['method'] == 'session/new'), isEmpty);
  });

  test('ACP refuses structured output before creating a provider session', () async {
    final process = FakeAcpProcess();
    final harness = _harnessFor(process);
    addTearDown(harness.dispose);

    final startFuture = harness.start();
    await process.respondTo('initialize', {'protocolVersion': 1});
    await startFuture;
    final sentBeforeTurn = process.capturedStdinJson.length;

    await expectLater(
      harness.turn(
        sessionId: 'structured-output',
        messages: const [
          {'role': 'user', 'content': 'classify this'},
        ],
        systemPrompt: '',
        outputSchema: const {
          'type': 'object',
          'properties': {
            'verdict': {'type': 'string'},
          },
          'required': ['verdict'],
        },
      ),
      throwsA(
        isA<UnsupportedHarnessCapabilityException>()
            .having((error) => error.provider, 'provider', 'AcpHarness')
            .having((error) => error.capability, 'capability', AgentHarness.structuredOutputCapability),
      ),
    );

    expect(harness.supportsStructuredOutput, isFalse);
    expect(process.capturedStdinJson.length, sentBeforeTurn);
    expect(process.capturedStdinJson.where((message) => message['method'] == 'session/new'), isEmpty);
    expect(process.capturedStdinJson.where((message) => message['method'] == 'session/prompt'), isEmpty);
  });

  test('ACP prepends scoped instructions before user content', () async {
    final process = FakeAcpProcess();
    final harness = _harnessFor(process);
    addTearDown(harness.dispose);

    final startFuture = harness.start();
    await process.respondTo('initialize', {'protocolVersion': 1});
    await startFuture;

    final turnFuture = harness.turn(
      sessionId: 'logical-agent',
      messages: const [
        {'role': 'user', 'content': 'find it'},
      ],
      systemPrompt: 'SEARCH PERSONA',
    );
    await process.respondTo('session/new', {'sessionId': 'acp-logical-agent'});
    final request = await process.waitForRequest('session/prompt');
    expect((request['params'] as Map<String, dynamic>)['prompt'], 'SEARCH PERSONA\n\nfind it');
    await process.respondTo('session/prompt', {'text': 'found'});
    await process.respondTo('session/close', {});
    await turnFuture;
  });

  test('ACP fresh sessions receive the current scoped revision after DartClaw base instructions', () async {
    final process = FakeAcpProcess();
    final harness = _harnessFor(process);
    addTearDown(harness.dispose);

    final startFuture = harness.start();
    await process.respondTo('initialize', {'protocolVersion': 1});
    await startFuture;

    final prompts = <String>[];
    final requestCounts = <String, int>{};
    Future<Map<String, dynamic>> nextRequest(String method) async {
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (DateTime.now().isBefore(deadline)) {
        final requests = process.capturedStdinJson.where((message) => message['method'] == method).toList();
        final requestCount = requestCounts[method] ?? 0;
        if (requests.length > requestCount) {
          requestCounts[method] = requestCount + 1;
          return requests.last;
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      fail('Timed out waiting for ACP request $method');
    }

    for (final revision in [41, 42]) {
      final turnFuture = harness.turn(
        sessionId: 'primary',
        messages: [
          {'role': 'user', 'content': 'question $revision'},
        ],
        systemPrompt: 'SAFE DARTCLAW BASE\n\nCollection revision: $revision',
      );
      final sessionRequest = await nextRequest('session/new');
      process.emitLine({
        'jsonrpc': '2.0',
        'id': sessionRequest['id'],
        'result': {'sessionId': 'acp-primary-$revision'},
      });
      final request = await nextRequest('session/prompt');
      prompts.add((request['params'] as Map<String, dynamic>)['prompt'] as String);
      process.emitLine({
        'jsonrpc': '2.0',
        'id': request['id'],
        'result': {'text': 'answer'},
      });
      final closeRequest = await nextRequest('session/close');
      process.emitLine({'jsonrpc': '2.0', 'id': closeRequest['id'], 'result': {}});
      await turnFuture;
    }

    expect(prompts[0], startsWith('SAFE DARTCLAW BASE\n\nCollection revision: 41\n\nquestion 41'));
    expect(prompts[1], startsWith('SAFE DARTCLAW BASE\n\nCollection revision: 42\n\nquestion 42'));
    expect(prompts[1], isNot(contains('Collection revision: 41')));
  });

  test('ACP replays persisted history into each fresh provider session', () async {
    final process = FakeAcpProcess();
    final harness = _harnessFor(process);
    addTearDown(harness.dispose);

    final startFuture = harness.start();
    await process.respondTo('initialize', {'protocolVersion': 1});
    await startFuture;

    final turnFuture = harness.turn(
      sessionId: 'logical-agent',
      messages: const [
        {'role': 'user', 'content': 'remember amber'},
        {'role': 'assistant', 'content': 'I will remember amber'},
        {'role': 'user', 'content': 'what color?'},
      ],
      systemPrompt: 'SEARCH PERSONA',
    );
    await process.respondTo('session/new', {'sessionId': 'acp-logical-agent'});
    final request = await process.waitForRequest('session/prompt');
    final prompt = (request['params'] as Map<String, dynamic>)['prompt'] as String;
    expect(prompt, startsWith('SEARCH PERSONA\n\n<conversation_history>'));
    expect(prompt, contains('[user]: remember amber'));
    expect(prompt, contains('[assistant]: I will remember amber'));
    expect(prompt, endsWith('</conversation_history>\n\nwhat color?'));
    await process.respondTo('session/prompt', {'text': 'amber'});
    await process.respondTo('session/close', {});
    await turnFuture;
  });

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
        'params': _textUpdate('agent_message_chunk', 'visible one '),
      });
      process.emitLine({
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': _textUpdate('agent_thought_chunk', 'private thought'),
      });
      process.emitLine({
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': _update('tool_call', {'toolCallId': 'tool-1', 'title': 'Read config'}),
      });
      process.emitLine({
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': _update('tool_call_update', {
          'toolCallId': 'tool-1',
          'status': 'completed',
          'rawOutput': {'result': 'ok'},
        }),
      });
      await process.respondTo('session/prompt', {'text': 'visible two'});
      await process.respondTo('session/close', {});

      await turnFuture;
      await sub.cancel();

      // Assistant text reaches the caller as bridge events, not as a result field.
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
            .having((event) => event.output, 'output', '{"result":"ok"}'),
        isA<DeltaEvent>().having((event) => event.text, 'text', 'visible two'),
      ]);
      expect(events.whereType<DeltaEvent>().map((event) => event.text).join(), isNot(contains('private thought')));
    });

    test('completed and cancelled ACP responses return normalized typed results', () async {
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

      expect(completed.stopReason, 'end_turn');
      expect(completed.inputTokens, 3);
      expect(completed.outputTokens, 5);
      expect(completed.cacheReadTokens, 7);
      expect(completed.cacheWriteTokens, 11);
      expect(completed.sessionTitle, 'Plan cleanup');
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
        'params': _textUpdate('agent_message_chunk', 'still streams'),
      });
      await process.respondTo('session/prompt', {'text': ''});
      await process.respondTo('session/close', {});

      await turnFuture;
      await sub.cancel();

      expect(events.whereType<DeltaEvent>().map((event) => event.text), contains('still streams'));
    });

    test('malformed session/update fails the turn with ACP_PROTOCOL_VIOLATION', () async {
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
      await process.waitForRequest('session/prompt');
      process.emitLine({
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': const {'update': <String, dynamic>{}},
      });
      await process.respondTo('session/close', {});

      await expectLater(
        turnFuture,
        throwsA(isA<AcpHarnessException>().having((error) => error.code, 'code', 'ACP_PROTOCOL_VIOLATION')),
      );
    });

    test('unknown well-shaped update is skipped and the turn completes', () async {
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
      await process.waitForRequest('session/prompt');
      process.emitLine({'jsonrpc': '2.0', 'method': 'session/update', 'params': _update('future_update')});
      await process.respondTo('session/prompt', {'text': 'done'});
      await process.respondTo('session/close', {});

      expect((await turnFuture).stopReason, 'completed');
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
        'params': _textUpdate('agent_message_chunk', 'late stale text'),
      });
      await process.respondTo('session/close', {});

      final result = await turnFuture;
      await sub.cancel();

      expect(result.isCancelled, isTrue);
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

      expect(result.isCancelled, isTrue);
      expect(process.capturedStdinJson.map((message) => message['method']), contains('session/cancel'));
      expect(process.killCalled, isTrue);
      expect(harness.state, WorkerState.stopped);
    });
  });
}

Map<String, dynamic> _update(String type, [Map<String, dynamic> fields = const {}]) => {
  'update': {'sessionUpdate': type, ...fields},
};

Map<String, dynamic> _textUpdate(String type, String text) => _update(type, {
  'content': {
    'content': {'type': 'text', 'text': text},
  },
});

AcpHarness _harnessFor(FakeAcpProcess process) {
  return AcpHarness(
    cwd: '/',
    processFactory: (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async =>
        process,
  );
}
