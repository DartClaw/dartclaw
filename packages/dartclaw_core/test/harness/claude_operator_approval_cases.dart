part of 'claude_code_harness_test.dart';

void registerClaudeOperatorApprovalTests() {
  test('native Claude permission waits only for an ordinary web operator', () async {
    final fake = makeCapturingClaudeProcess();
    final h = buildClaudeHarness(
      providerOptions: const {'permissionMode': 'acceptEdits'},
      processFactory: capturingInitFactory(process: fake),
    );
    addTeardownAsync(() => h.dispose());
    final events = <BridgeEvent>[];
    final subscription = h.events.listen(events.add);
    addTeardownAsync(subscription.cancel);

    await h.start();
    h.setTurnContext(
      const HarnessTurnContext(
        sessionId: 'web-session',
        turnId: 'web-turn',
        source: 'web',
        agentName: 'main',
        allowOperatorApproval: true,
      ),
    );
    fake.emitStdout(
      jsonEncode({
        'type': 'control_request',
        'request_id': 'req-operator',
        'request': {
          'subtype': 'can_use_tool',
          'tool_name': 'Bash',
          'tool_use_id': 'tool-operator',
          'input': {'command': 'git status'},
        },
      }),
    );
    await Future<void>.delayed(Duration.zero);

    expect(
      fake.capturedStdinJson.where(
        (line) => (line['response'] as Map<String, dynamic>?)?['request_id'] == 'req-operator',
      ),
      isEmpty,
    );
    expect(
      events,
      contains(
        isA<ToolApprovalWaitEvent>()
            .having((event) => event.requestId, 'requestId', 'req-operator')
            .having((event) => event.operatorActionable, 'operatorActionable', isTrue),
      ),
    );
    expect(h.canResolveToolApproval(turnId: 'web-turn', requestId: 'req-operator'), isTrue);
    expect(h.canResolveToolApproval(turnId: 'wrong-turn', requestId: 'req-operator'), isFalse);
    await h.resolveToolApproval(turnId: 'web-turn', requestId: 'req-operator', approved: true);
    final operatorResponse = fake.capturedStdinJson.singleWhere(
      (line) => (line['response'] as Map<String, dynamic>?)?['request_id'] == 'req-operator',
    );
    expect((operatorResponse['response'] as Map<String, dynamic>)['response'], {
      'behavior': 'allow',
      'toolUseID': 'tool-operator',
    });

    h.setTurnContext(
      const HarnessTurnContext(sessionId: 'cron-session', turnId: 'cron-turn', source: 'cron', agentName: 'main'),
    );
    fake.emitStdout(
      jsonEncode({
        'type': 'control_request',
        'request_id': 'req-background',
        'request': {'subtype': 'can_use_tool', 'tool_name': 'Bash', 'tool_use_id': 'tool-background'},
      }),
    );
    await Future<void>.delayed(Duration.zero);
    final backgroundResponse = fake.capturedStdinJson.singleWhere(
      (line) => (line['response'] as Map<String, dynamic>?)?['request_id'] == 'req-background',
    );
    expect((backgroundResponse['response'] as Map<String, dynamic>)['response'], {
      'behavior': 'allow',
      'toolUseID': 'tool-background',
    });
  });
}
