part of 'codex_harness_test.dart';

void registerCodexProviderSessionResumeTests() {
  test('resumes a durable provider thread before starting the turn', () async {
    final (:harness, :fake) = await _startedHarness();
    expect(harness.supportsProviderSessionResume, isTrue);
    final turnFuture = harness.turn(
      sessionId: 'resumed-session',
      messages: const [
        {'role': 'user', 'content': 'continue'},
      ],
      systemPrompt: '',
      providerSessionId: 'thread-durable',
    );
    await waitForSentMessage(fake, 'thread/resume');
    final resume = fake.sentMessages.singleWhere((message) => message['method'] == 'thread/resume');
    expect(resume['params'], {'threadId': 'thread-durable'});
    expect(fake.sentMessages.where((message) => message['method'] == 'thread/start'), isEmpty);
    expect(fake.sentMessages.where((message) => message['method'] == 'turn/start'), isEmpty);
    fake.emitThreadStartResponse(id: resume['id']! as Object, threadId: 'thread-durable');
    await waitForSentMessage(fake, 'turn/start');
    final turnStart = fake.sentMessages.singleWhere((message) => message['method'] == 'turn/start');
    expect((turnStart['params'] as Map<String, dynamic>)['threadId'], 'thread-durable');
    fake.emitTurnCompleted(inputTokens: 2, outputTokens: 3);
    expect((await turnFuture).providerSessionId, 'thread-durable');
  });

  test('surfaces a provider thread/resume failure without starting a replacement', () async {
    final (:harness, :fake) = await _startedHarness();
    final turnFuture = harness.turn(
      sessionId: 'missing-rollout',
      messages: const [
        {'role': 'user', 'content': 'continue'},
      ],
      systemPrompt: '',
      providerSessionId: 'missing-thread',
    );
    await waitForSentMessage(fake, 'thread/resume');
    final resume = fake.sentMessages.singleWhere((message) => message['method'] == 'thread/resume');
    fake.emitLine({
      'id': resume['id'],
      'error': {'code': -32600, 'message': 'no rollout found for thread id missing-thread'},
    });
    await expectLater(
      turnFuture,
      throwsA(isA<StateError>().having((error) => error.message, 'message', contains('no rollout found'))),
    );
    expect(fake.sentMessages.where((message) => message['method'] == 'thread/start'), isEmpty);
    expect(fake.sentMessages.where((message) => message['method'] == 'turn/start'), isEmpty);
  });

  test('refuses a resume response for a different provider thread', () async {
    final (:harness, :fake) = await _startedHarness();
    final turnFuture = harness.turn(
      sessionId: 'mismatched-resume',
      messages: const [
        {'role': 'user', 'content': 'continue'},
      ],
      systemPrompt: '',
      providerSessionId: 'thread-requested',
    );
    await waitForSentMessage(fake, 'thread/resume');
    final resume = fake.sentMessages.singleWhere((message) => message['method'] == 'thread/resume');
    fake.emitThreadStartResponse(id: resume['id']! as Object, threadId: 'thread-other');
    await expectLater(
      turnFuture.timeout(const Duration(milliseconds: 200)),
      throwsA(
        isA<StateError>()
            .having((error) => error.message, 'message', contains('thread-requested'))
            .having((error) => error.message, 'message', contains('thread-other')),
      ),
    );
    expect(fake.sentMessages.where((message) => message['method'] == 'turn/start'), isEmpty);
    expect(fake.sentMessages.where((message) => message['method'] == 'thread/start'), isEmpty);
  });

  test('returns a durable provider thread id when resumability is requested', () async {
    final (:harness, :fake) = await _startedHarness();
    final turnFuture = harness.turn(
      sessionId: 'durable-bootstrap',
      messages: const [
        {'role': 'user', 'content': 'start durable'},
      ],
      systemPrompt: '',
      requestProviderSessionResume: true,
    );
    await waitForSentMessage(fake, 'thread/start');
    final threadStart = fake.sentMessages.singleWhere((message) => message['method'] == 'thread/start');
    fake.emitThreadStartResponse(id: threadStart['id']! as Object, threadId: 'thread-bootstrap');
    await waitForSentMessage(fake, 'turn/start');
    final methods = fake.sentMessages.map((message) => message['method']).toList();
    expect(methods.indexOf('thread/start'), lessThan(methods.indexOf('turn/start')));
    fake.emitTurnCompleted(inputTokens: 2, outputTokens: 3);
    expect((await turnFuture).providerSessionId, 'thread-bootstrap');
  });

  test('refuses durable-session requests on an isolated Codex home', () async {
    final fake = FakeCodexProcess(completeExitOnKill: true);
    final harness = _buildHarness(process: fake, providerOptions: const {'use_system_codex_home': false});
    addTearDown(() async => harness.dispose());
    await startHarness(harness, fake);
    expect(harness.supportsProviderSessionResume, isFalse);
    await expectLater(
      harness.turn(
        sessionId: 'isolated',
        messages: const [
          {'role': 'user', 'content': 'start durable'},
        ],
        systemPrompt: '',
        requestProviderSessionResume: true,
      ),
      throwsA(
        isA<UnsupportedHarnessCapabilityException>()
            .having((error) => error.provider, 'provider', contains('non-durable CODEX_HOME'))
            .having((error) => error.capability, 'capability', AgentHarness.providerSessionResumeCapability),
      ),
    );
    expect(fake.sentMessages.where((message) => message['method'] == 'thread/start'), isEmpty);
  });
}
