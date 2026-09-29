part of 'codex_harness_test.dart';

void registerCodexModelCatalogueTests() {
  group('model catalogue', () {
    test('every non-hidden model/list entry is offered by name, and thread/start resolves Default', () async {
      final fake = FakeCodexProcess(completeExitOnKill: true);
      final harness = _buildHarness(process: fake);
      addTearDown(() async => harness.dispose());

      final discovery = harness.discoverModelCatalogue();
      await _serveModelDiscovery(fake, threadStartResult: _codexThreadStartGpt55);
      final catalogue = await discovery;

      expect(catalogue.entries.map((entry) => (entry.id, entry.label)), [
        ('gpt-5.5', 'GPT-5.5'),
        ('gpt-5.4', 'GPT-5.4'),
      ]);
      // Efforts are the provider's own list per model, `max` and `ultra` included.
      expect(catalogue.entryFor('gpt-5.5')!.efforts, ['low', 'medium', 'high', 'xhigh', 'max', 'ultra']);
      expect(catalogue.entryFor('gpt-5.4')!.efforts, ['low', 'medium', 'high', 'xhigh']);
      expect(catalogue.defaultId, 'gpt-5.5');

      expect(fake.sentMessages.map((message) => message['method']), [
        'initialize',
        'initialized',
        'model/list',
        'model/list',
        'thread/start',
      ]);
      final pages = fake.sentMessages.where((message) => message['method'] == 'model/list').toList();
      expect(pages.first['params'], isEmpty);
      expect(pages.last['params'], {'cursor': '2'});
      final threadStart = fake.sentMessages.singleWhere((message) => message['method'] == 'thread/start');
      expect(threadStart['params'], {'ephemeral': true});
      expect(fake.sentMessages.where((message) => message['method'] == 'turn/start'), isEmpty);
      expect(harness.state, WorkerState.stopped);
      expect(fake.killCalled, isTrue);
    });

    test('a resolved model that is not offered leaves Default unresolved', () async {
      final fake = FakeCodexProcess(completeExitOnKill: true);
      final harness = _buildHarness(process: fake);
      addTearDown(() async => harness.dispose());

      final discovery = harness.discoverModelCatalogue();
      // The hidden entry is what the thread resolves to; it is not selectable.
      await _serveModelDiscovery(
        fake,
        threadStartResult: r'{"thread":{"id":"thr_1"},"model":"gpt-5.5-codex-max","modelProvider":"openai","reasoningEffort":"medium"}',
      );
      final catalogue = await discovery;

      expect(catalogue.entries.map((entry) => entry.id), ['gpt-5.5', 'gpt-5.4']);
      expect(catalogue.defaultId, isNull);
    });

    test('the configured model is what the ephemeral thread resolves', () async {
      final fake = FakeCodexProcess(completeExitOnKill: true);
      final harness = _buildHarness(
        process: fake,
        harnessConfig: const HarnessLaunchOptions(model: 'gpt-5.4'),
      );
      addTearDown(() async => harness.dispose());

      final discovery = harness.discoverModelCatalogue();
      await _serveModelDiscovery(
        fake,
        threadStartResult:
            r'{"thread":{"id":"thr_1"},"model":"gpt-5.4","modelProvider":"openai","reasoningEffort":"medium"}',
      );
      final catalogue = await discovery;

      final threadStart = fake.sentMessages.singleWhere((message) => message['method'] == 'thread/start');
      expect(threadStart['params'], {'ephemeral': true, 'model': 'gpt-5.4'});
      expect(catalogue.defaultId, 'gpt-5.4');
    });

    // The dedicated home is shared by every host worker and Codex re-reads its
    // config.toml on each thread start: a probe that rewrote it would strip the
    // workers' developer instructions and DartClaw MCP server.
    test('discovery leaves a dedicated subscription home byte-identical', () async {
      final home = Directory.systemTemp.createTempSync('codex_catalogue_home_');
      addTearDown(() => home.deleteSync(recursive: true));
      const config =
          'developer_instructions = "worker prompt"\n\n'
          '[mcp_servers.dartclaw]\nurl = "http://localhost:3333/mcp"\n'
          'bearer_token_env_var = "DARTCLAW_MCP_TOKEN"\n\n'
          '[plugins."andthen@local"]\nenabled = true\n';
      final configFile = File(p.join(home.path, 'config.toml'))..writeAsStringSync(config);
      final fake = FakeCodexProcess(completeExitOnKill: true);
      Map<String, String>? spawnEnvironment;
      final harness = _buildHarness(
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          spawnEnvironment = environment;
          return fake;
        },
        prepareSubscriptionHome: () async => home.path,
      );
      addTearDown(() async => harness.dispose());

      final discovery = harness.discoverModelCatalogue();
      await _serveModelDiscovery(fake, threadStartResult: _codexThreadStartGpt55);
      await discovery;

      expect(spawnEnvironment!['CODEX_HOME'], home.path);
      expect(configFile.readAsStringSync(), config);
      expect(File(p.join(home.path, 'AGENTS.md')).existsSync(), isFalse);
    });

    test('an entry without displayName fails discovery instead of a partial list', () async {
      final fake = FakeCodexProcess(completeExitOnKill: true);
      final harness = _buildHarness(process: fake);
      addTearDown(() async => harness.dispose());

      final discovery = harness.discoverModelCatalogue();
      final failure = expectLater(discovery, throwsFormatException);
      await waitForSentMessage(fake, 'initialize');
      fake.emitInitializeResponse(id: latestRequestId(fake, 'initialize'));
      await waitForSentMessage(fake, 'model/list');
      _respond(
        fake,
        'model/list',
        r'{"data":[{"id":"gpt-5.5","model":"gpt-5.5","description":"Frontier agentic coding model.","hidden":false,"isDefault":true,"defaultReasoningEffort":"medium","supportedReasoningEfforts":[{"reasoningEffort":"low","description":"Fast responses"}]}],"nextCursor":null}',
      );
      await waitForSentMessage(fake, 'thread/start');
      _respond(fake, 'thread/start', _codexThreadStartGpt55);
      await failure;
      expect(harness.state, WorkerState.stopped);
    });
  });
}

/// Answers the handshake, two `model/list` pages (the first with a hidden
/// entry) and the ephemeral `thread/start` with [threadStartResult].
Future<void> _serveModelDiscovery(FakeCodexProcess fake, {required String threadStartResult}) async {
  await waitForSentMessage(fake, 'initialize');
  fake.emitInitializeResponse(id: latestRequestId(fake, 'initialize'));
  await waitForSentMessage(fake, 'model/list');
  _respond(fake, 'model/list', _codexModelListPage1);
  await _pumpUntilSentMessageCount(fake, 'model/list', 2);
  _respond(fake, 'model/list', _codexModelListPage2);
  await waitForSentMessage(fake, 'thread/start');
  _respond(fake, 'thread/start', threadStartResult);
}

void _respond(FakeCodexProcess fake, String method, String rawResult) =>
    fake.emitStdout('{"id":${latestRequestId(fake, method)},"result":$rawResult}');

/// `model/list` pages in the codex-cli 0.155.1 `Model` shape.
const _codexModelListPage1 =
    r'{"data":['
    r'{"id":"gpt-5.5","model":"gpt-5.5","displayName":"GPT-5.5","description":"Frontier agentic coding model.","hidden":false,"isDefault":true,"defaultReasoningEffort":"medium","supportedReasoningEfforts":[{"reasoningEffort":"low","description":"Fast responses"},{"reasoningEffort":"medium","description":"Balanced"},{"reasoningEffort":"high","description":"Deeper reasoning"},{"reasoningEffort":"xhigh","description":"Extra high"},{"reasoningEffort":"max","description":"Maximum"},{"reasoningEffort":"ultra","description":"Ultra"}]},'
    r'{"id":"gpt-5.5-codex-max","model":"gpt-5.5-codex-max","displayName":"GPT-5.5-Codex-Max","description":"Hidden preview.","hidden":true,"isDefault":false,"defaultReasoningEffort":"medium","supportedReasoningEfforts":[{"reasoningEffort":"medium","description":"Balanced"}]}'
    r'],"nextCursor":"2"}';

const _codexModelListPage2 =
    r'{"data":['
    r'{"id":"gpt-5.4","model":"gpt-5.4","displayName":"GPT-5.4","description":"Previous frontier model.","hidden":false,"isDefault":false,"defaultReasoningEffort":"medium","supportedReasoningEfforts":[{"reasoningEffort":"low","description":"Fast responses"},{"reasoningEffort":"medium","description":"Balanced"},{"reasoningEffort":"high","description":"Deeper reasoning"},{"reasoningEffort":"xhigh","description":"Extra high"}]}'
    r'],"nextCursor":null}';

/// Ephemeral `thread/start` result: the resolved model, no turn started.
const _codexThreadStartGpt55 =
    r'{"thread":{"id":"thr_1"},"model":"gpt-5.5","modelProvider":"openai","reasoningEffort":"medium"}';
