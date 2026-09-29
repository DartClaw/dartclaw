part of 'codex_harness_test.dart';

void registerCodexSkillRootTests() {
  test('configures the pinned workspace skill root before any thread opens', () async {
    final fake = FakeCodexProcess(completeExitOnKill: true);
    final harness = _buildHarness(process: fake, skillWorkspaceDir: '/tmp/agents/a');
    addTearDown(() async => harness.dispose());

    final start = harness.start();
    await waitForSentMessage(fake, 'initialize');
    fake.emitInitializeResponse(id: latestRequestId(fake, 'initialize'));
    await waitForSentMessage(fake, 'skills/extraRoots/set');
    final request = fake.sentMessages.singleWhere((message) => message['method'] == 'skills/extraRoots/set');
    expect(request['params'], {
      'extraRoots': ['/tmp/agents/a/.agents/skills'],
    });
    expect(fake.sentMessages.map((message) => message['method']), [
      'initialize',
      'initialized',
      'skills/extraRoots/set',
    ]);
    expect(fake.sentMessages.where((message) => message['method'] == 'thread/start'), isEmpty);
    fake.emitLine({'id': request['id'], 'result': {}});

    await start;
    expect(harness.state, WorkerState.idle);
  });
}
