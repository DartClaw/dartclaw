import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';
import 'dart:io';

import 'package:dartclaw_runtime/dartclaw_runtime.dart' show HealthService, SseBroadcast;
import 'package:dartclaw_runtime/src/behavior/behavior_file_service.dart';
import 'package:dartclaw_runtime/src/concurrency/session_lock_manager.dart';
import 'package:dartclaw_runtime/src/config/config_load.dart';
import 'package:dartclaw_runtime/src/execution_policy_resolver.dart';
import 'package:dartclaw_runtime/src/governance/pause_controller.dart';
import 'package:dartclaw_runtime/src/runtime/channel_agent_binding.dart';
import 'package:dartclaw_runtime/src/runtime/channel_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/feedback_observer_factory.dart';
import 'package:dartclaw_runtime/src/runtime/reserved_command_handler.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart' show StorageWiring;
import 'package:dartclaw_runtime/src/runtime/task_wiring.dart';
import 'package:dartclaw_runtime/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_google_chat/testing.dart';
import 'package:dartclaw_slack/dartclaw_slack.dart';
import 'package:dartclaw_slack/testing.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

import '../turn_manager_test_support.dart';
import 'channel_wiring_test_support.dart';
import 'harness_wiring_fixture.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw-channel-wiring-test-');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('channel dispatch selects the conversational prompt scope', () async {
    final turns = RecordingChannelTurnManager();
    addTearDown(turns.executions.dispose);

    final response = await dispatchChannelTurn(
      sessions: SessionService(baseDir: tempDir.path),
      messages: MessageService(baseDir: tempDir.path),
      turnManagerGetter: () => turns,
      sessionKey: 'signal:dm:alice',
      message: 'hello',
      channelType: ChannelType.signal,
      senderJid: '+46701234567',
      senderDisplayName: 'Alice',
      provenance: _signalProvenance,
    );

    expect(response, 'reply');
    expect(turns.started, hasLength(1));
    final turn = turns.started.single;
    expect(turn.source, 'channel');
    expect(turn.isHumanInput, isTrue);
    expect(turn.promptScope, PromptScope.primary);
    expect(turn.origin, (channel: 'signal', contact: 'Alice', group: false));
  });

  group('global turn cap', () {
    const sessionKey = 'agent:main:signal:dm:alice';
    late SessionService sessions;
    late MessageService messages;

    setUp(() {
      sessions = SessionService(baseDir: tempDir.path);
      messages = MessageService(baseDir: tempDir.path);
    });

    Future<String> dispatch(TurnManager turns) => dispatchChannelTurn(
      sessions: sessions,
      messages: messages,
      turnManagerGetter: () => turns,
      sessionKey: sessionKey,
      message: 'hello',
      channelType: ChannelType.signal,
      senderJid: '+46701234567',
      senderDisplayName: 'Alice',
      provenance: _signalProvenance,
    );

    Future<List<String>> userMessages() async {
      final session = await sessions.getByKey(sessionKey);
      final history = await messages.getMessages(session!.id);
      return [
        for (final message in history)
          if (message.role == 'user') message.content,
      ];
    }

    test('a message deferred on the full cap waits for a slot and persists once', () async {
      final lockManager = SessionLockManager(maxParallel: 1);
      final worker = FakeWorkerService();
      final turns = TurnManager(
        turnLimits: const TurnLimitsConfig.defaults(),
        messages: messages,
        sessions: sessions,
        worker: worker,
        behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
        lockManager: lockManager,
      );
      addTearDown(turns.executions.dispose);
      await lockManager.acquire('another-session');

      var settled = false;
      final dispatched = dispatch(turns).then<Object?>((response) => response, onError: (Object error) => error);
      unawaited(dispatched.whenComplete(() => settled = true));
      while ((await userMessages().catchError((_) => const <String>[])).isEmpty) {
        await pumpEventQueue();
      }
      await pumpEventQueue(times: 200);

      expect(settled, isFalse, reason: 'a full global cap defers the turn instead of failing the dispatch');

      lockManager.release('another-session');
      await worker.turnInvoked;
      worker.emit(DeltaEvent('Pong'));
      worker.completeSuccess();

      expect(await dispatched, 'Pong');
      expect(await userMessages(), ['hello']);
    });

    test('a bound turn deferred on the cap re-reserves once capacity frees', () async {
      final turns = RecordingChannelTurnManager();
      addTearDown(turns.executions.dispose);
      final binding = ChannelAgentBinder(
        agents: const {
          'ana': AgentDefinition(id: 'ana', description: 'Ana', prompt: 'You are Ana.', provider: 'claude'),
        },
        policyResolver: ExecutionPolicyResolver(
          config: DartclawConfig.defaults(),
          availableContainerProfiles: const {},
        ),
        defaultProviderId: 'claude',
        behavior: BehaviorFileService(workspaceDir: tempDir.path),
      ).bind(const GroupEntry(id: 'alice', agent: 'ana'))!;
      turns.busyOnReserve.addAll([
        BusyTurnException('Global concurrency limit reached (1)', isSameSession: false),
        BusyTurnException('Global concurrency limit reached (1)', isSameSession: false),
      ]);

      final response = await dispatchChannelTurn(
        sessions: sessions,
        messages: messages,
        turnManagerGetter: () => turns,
        sessionKey: SessionKey.dmPerChannelContact(agentId: 'ana', channelType: 'signal', peerId: 'alice'),
        message: 'hello',
        channelType: ChannelType.signal,
        senderJid: 'alice',
        binding: binding,
        provenance: _signalProvenance,
      );

      expect(response, 'reply');
      expect(turns.capacityWaits, 2);
      expect(turns.reserved, hasLength(1));
      expect(turns.executed, hasLength(1));
    });

    test('a same-session busy is not a capacity wait and still propagates', () async {
      final turns = RecordingChannelTurnManager();
      addTearDown(turns.executions.dispose);
      turns.busyOnStart.add(BusyTurnException('Session is busy', isSameSession: true));

      await expectLater(dispatch(turns), throwsA(isA<BusyTurnException>()));

      expect(turns.capacityWaits, 0);
    });
  });

  group('bound channel turn', () {
    const origin = (channel: 'signal', contact: 'Alice', group: false);
    late SessionService sessions;
    late MessageService messages;
    late BehaviorFileService behavior;
    late RecordingChannelTurnManager turns;

    setUp(() {
      sessions = SessionService(baseDir: tempDir.path);
      messages = MessageService(baseDir: tempDir.path);
      final ownerWorkspace = Directory(p.join(tempDir.path, 'workspace'))..createSync();
      File(p.join(ownerWorkspace.path, 'SOUL.md')).writeAsStringSync('OWNER SOUL MARKER');
      File(p.join(ownerWorkspace.path, 'USER.md')).writeAsStringSync('OWNER USER MARKER');
      File(p.join(ownerWorkspace.path, 'TOOLS.md')).writeAsStringSync('OWNER TOOLS MARKER');
      File(p.join(ownerWorkspace.path, 'MEMORY.md')).writeAsStringSync('OWNER MEMORY MARKER');
      behavior = BehaviorFileService(workspaceDir: ownerWorkspace.path);
      turns = RecordingChannelTurnManager();
      addTearDown(turns.executions.dispose);
    });

    ChannelAgentBinder binderFor(AgentDefinition agent) => ChannelAgentBinder(
      agents: {agent.id: agent},
      policyResolver: ExecutionPolicyResolver(
        config: DartclawConfig.defaults().copyWith(container: const ContainerConfig(enabled: true)),
        availableContainerProfiles: const {'workspace', 'restricted'},
      ),
      defaultProviderId: 'claude',
      behavior: behavior,
    );

    Future<String> dispatch({ChannelAgentBinding? binding, String? model, String? effort}) => dispatchChannelTurn(
      sessions: sessions,
      messages: messages,
      turnManagerGetter: () => turns,
      sessionKey: SessionKey.dmPerChannelContact(
        agentId: binding?.definition.id ?? 'main',
        channelType: 'signal',
        peerId: '+1',
      ),
      message: 'hello',
      channelType: ChannelType.signal,
      senderJid: '+1',
      senderDisplayName: 'Alice',
      model: model,
      effort: effort,
      binding: binding,
      provenance: _signalProvenance,
    );

    test('a reserved owner workspace binding is refused before channel dispatch', () {
      final owner = Directory(p.join(tempDir.path, 'workspace'))..createSync();
      final configured = AgentDefinition.fromYaml(
        'main',
        const {
          'tools': ['Read'],
        },
        <String>[],
        dataDir: tempDir.path,
        ownerWorkspaceDir: owner.path,
      );

      expect(
        () => binderFor(configured).bind(const GroupEntry(id: '+1', agent: 'main')),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(contains(p.join('agents', 'main', 'workspace')), contains('reserved for the owner workspace')),
          ),
        ),
      );
      expect(turns.reserved, isEmpty);
      expect(turns.executed, isEmpty);
    });

    test(
      "the session is pinned to the agent's provider, profile and mode; the turn carries its name and persona",
      () async {
        const ana = AgentDefinition(
          id: 'ana',
          description: 'Ana',
          prompt: 'You are Ana.',
          provider: ' Codex ',
          execution: ExecutionMode.host,
          model: 'sonnet',
          effort: ' high ',
        );
        final binding = binderFor(ana).bind(const GroupEntry(id: '+1', agent: 'ana'));

        // The row's model arrives already resolved through the channel chain; the agent supplies what it left null.
        final response = await dispatch(binding: binding, model: 'opus');

        expect(response, 'reply');
        final session = (await sessions.listSessions(type: SessionType.channel)).single;
        expect(session.provider, 'codex');
        expect(session.executionMode, ExecutionMode.host);
        expect(session.securityProfile, isNull);

        expect(turns.started, isEmpty);
        final reservedTurn = turns.reserved.single;
        expect(reservedTurn.sessionId, session.id);
        expect(reservedTurn.agentName, 'ana');
        expect(reservedTurn.model, 'opus');
        expect(reservedTurn.effort, 'high');
        expect(reservedTurn.isHumanInput, isTrue);
        expect(reservedTurn.promptScope, PromptScope.task);
        expect(reservedTurn.origin, origin);
        expect(reservedTurn.systemPromptOverride, isNull);
        expect(reservedTurn.workerPolicy, isNull, reason: 'the pinned session supplies its own policy');
        expect(reservedTurn.behaviorOverride?.soulOverride, 'You are Ana.');
        expect(reservedTurn.behaviorOverride?.workspaceDir, behavior.workspaceDir);

        final executedTurn = turns.executed.single;
        expect(executedTurn.agentName, 'ana');
        expect(executedTurn.source, 'channel');
        expect(executedTurn.messageCount, 1);
      },
    );

    test('a restricted agent gets its scoped persona without owner workspace content', () async {
      const sandboxed = AgentDefinition(
        id: 'sandboxed',
        description: 'Sandboxed',
        prompt: 'You are sandboxed.',
        securityProfile: 'restricted',
        profileIsOperatorConfigured: true,
        execution: ExecutionMode.container,
      );
      final binding = binderFor(sandboxed).bind(const GroupEntry(id: '+1', agent: 'sandboxed'));

      await dispatch(binding: binding);

      final session = (await sessions.listSessions(type: SessionType.channel)).single;
      expect(session.provider, 'claude');
      expect(session.executionMode, ExecutionMode.container);
      expect(session.securityProfile, 'restricted');
      final reservedTurn = turns.reserved.single;
      expect(reservedTurn.promptScope, PromptScope.restricted);
      final prompt = await reservedTurn.behaviorOverride!.composeSystemPrompt(scope: reservedTurn.promptScope!);
      expect(prompt, contains('You are sandboxed.'));
      expect(prompt, isNot(contains('OWNER SOUL MARKER')));
      expect(prompt, isNot(contains('OWNER USER MARKER')));
      expect(prompt, isNot(contains('OWNER TOOLS MARKER')));
      expect(prompt, isNot(contains('OWNER MEMORY MARKER')));
      expect(reservedTurn.agentName, 'sandboxed');
    });

    test('an unconfigured blank-prompt agent gets the default prompt without owner workspace content', () async {
      const quiet = AgentDefinition(id: 'quiet', description: 'Quiet', prompt: '  ', execution: ExecutionMode.host);
      final binding = binderFor(quiet).bind(const GroupEntry(id: '+1', agent: 'quiet'));

      await dispatch(binding: binding);

      final reservedTurn = turns.reserved.single;
      final prompt = await reservedTurn.behaviorOverride!.composeSystemPrompt(scope: reservedTurn.promptScope!);
      expect(reservedTurn.promptScope, PromptScope.task);
      expect(prompt, contains(BehaviorFileService.defaultPrompt));
      expect(prompt, isNot(contains('OWNER SOUL MARKER')));
      expect(prompt, isNot(contains('OWNER USER MARKER')));
      expect(prompt, isNot(contains('OWNER TOOLS MARKER')));
      expect(prompt, isNot(contains('OWNER MEMORY MARKER')));
    });

    test('an unbound row takes the pre-change call: an unpinned session and startTurn', () async {
      final binder = binderFor(const AgentDefinition(id: 'ana', description: 'Ana', prompt: 'x'));

      await dispatch(
        binding: binder.bind(const GroupEntry(id: '+1', model: 'haiku')),
        model: 'haiku',
        effort: 'low',
      );

      final session = (await sessions.listSessions(type: SessionType.channel)).single;
      expect(session.provider, isNull);
      expect(session.executionMode, isNull);
      expect(turns.reserved, isEmpty);
      expect(turns.started.single, (
        sessionId: session.id,
        source: 'channel',
        isHumanInput: true,
        model: 'haiku',
        effort: 'low',
        promptScope: PromptScope.primary,
        origin: origin,
        provenance: _signalProvenance,
      ));
    });

    test('an undeclared agent is a wiring defect, never a fallback to the primary lane', () {
      final binder = binderFor(const AgentDefinition(id: 'ana', description: 'Ana', prompt: 'x'));

      expect(() => binder.bind(const GroupEntry(id: '+1', agent: 'nope')), throwsStateError);
    });

    test('Google Chat feedback cannot clear a bound session policy before reservation', () async {
      const agent = AgentDefinition(
        id: 'ana',
        description: 'Ana',
        prompt: 'You are Ana.',
        provider: 'codex',
        securityProfile: 'restricted',
        profileIsOperatorConfigured: true,
        execution: ExecutionMode.container,
      );
      final binding = binderFor(agent).bind(const GroupEntry(id: 'users/alice', agent: 'ana'));
      final channel = GoogleChatChannel(
        config: const GoogleChatConfig(
          typingIndicatorMode: TypingIndicatorMode.disabled,
          feedback: GoogleChatFeedbackConfig(enabled: true, statusStyle: GoogleChatFeedbackStatusStyle.silent),
        ),
        restClient: GoogleChatRestClient(authClient: MockClient((_) async => http.Response('{}', 200))),
      );
      final observer = FeedbackObserverFactory.build(
        googleChatConfig: channel.config,
        sessions: sessions,
        turnManagerGetter: () => turns,
      )!;
      final sessionKey = SessionKey.dmPerChannelContact(
        agentId: 'ana',
        channelType: 'googlechat',
        peerId: 'users/alice',
      );
      final inbound = ChannelMessage(
        id: 'spaces/AAA/messages/1',
        channelType: ChannelType.googlechat,
        senderJid: 'users/alice',
        text: 'hello',
      );

      final response = await dispatchChannelTurn(
        sessions: sessions,
        messages: messages,
        turnManagerGetter: () => turns,
        sessionKey: sessionKey,
        message: inbound.text,
        channelType: ChannelType.googlechat,
        senderJid: inbound.senderJid,
        binding: binding,
        provenance: _signalProvenance,
      );
      await observer(sessionKey, inbound, channel, 'spaces/AAA', Future.value(response));

      final session = await sessions.getByKey(sessionKey);
      expect(session?.provider, 'codex');
      expect(session?.securityProfile, 'restricted');
      expect(session?.executionMode, ExecutionMode.container);
      expect(turns.started, isEmpty);
      expect(turns.reserved.single.agentName, 'ana');
      expect(turns.reserved.single.promptScope, PromptScope.restricted);
    });

    test('Slack feedback started before the dispatch leaves the bound session to the dispatch', () async {
      const agent = AgentDefinition(
        id: 'ana',
        description: 'Ana',
        prompt: 'You are Ana.',
        provider: 'codex',
        securityProfile: 'restricted',
        profileIsOperatorConfigured: true,
        execution: ExecutionMode.container,
      );
      final binding = binderFor(agent).bind(const GroupEntry(id: 'C1', agent: 'ana'));
      final slackApi = FakeSlackWebApi();
      final channel = SlackChannel(
        config: const SlackConfig(enabled: true),
        api: slackApi,
        dmAccess: DmAccessController(mode: DmAccessMode.open),
        mentionGating: MentionGating(requireMention: false, mentionPatterns: const [], ownJid: ''),
        channelManager: ChannelManager(queue: RecordingMessageQueue(), config: const ChannelConfig.defaults()),
      );
      final observer = FeedbackObserverFactory.build(
        googleChatConfig: const GoogleChatConfig(),
        slackConfig: const SlackConfig(enabled: true),
        sessions: sessions,
        turnManagerGetter: () => turns,
      )!;
      const sessionKey = 'agent:ana:slack:group:C1:thread:1.1';
      final inbound = ChannelMessage(
        id: 'C1:1.1',
        channelType: ChannelType.slack,
        senderJid: 'U1',
        groupJid: 'C1',
        text: 'hello',
        metadata: const {'spaceName': 'C1', threadIdMetadataKey: '1.1'},
      );
      final response = Completer<String>();

      // The queue starts the observer right after invoking the dispatcher, before the session exists.
      final observed = observer(sessionKey, inbound, channel, 'C1', response.future);
      await pumpEventQueue();
      expect(await sessions.getByKey(sessionKey), isNull, reason: 'feedback must not create the session');
      response.complete(
        await dispatchChannelTurn(
          sessions: sessions,
          messages: messages,
          turnManagerGetter: () => turns,
          sessionKey: sessionKey,
          message: inbound.text,
          channelType: ChannelType.slack,
          senderJid: inbound.senderJid,
          groupJid: 'C1',
          binding: binding,
          provenance: _signalProvenance,
        ),
      );
      await observed;

      final session = await sessions.getByKey(sessionKey);
      expect(session?.provider, 'codex');
      expect(session?.securityProfile, 'restricted');
      expect(session?.executionMode, ExecutionMode.container);
      expect(
        await sessions.listSessions(type: SessionType.channel),
        hasLength(1),
        reason: 'created once, by the dispatch',
      );
      expect(turns.started, isEmpty);
      expect(turns.reserved.single.agentName, 'ana', reason: 'the turn runs on the logical-agent surface');
      expect(slackApi.statuses.map((status) => status.status), ['is working...', '']);
    });

    test('pause replay does not reconstruct a bound session as a primary turn', () async {
      final sessionKey = SessionKey.dmPerChannelContact(agentId: 'ana', channelType: 'signal', peerId: '+1');
      const agent = AgentDefinition(
        id: 'ana',
        description: 'Ana',
        prompt: 'You are Ana.',
        provider: 'codex',
        securityProfile: 'restricted',
        profileIsOperatorConfigured: true,
        execution: ExecutionMode.container,
      );
      final binding = binderFor(agent)
          .bind(const GroupEntry(id: '+1', model: 'row-model', effort: 'high', agent: 'ana'));
      final completed = Completer<void>();
      final queue = MessageQueue(
        debounceWindow: Duration.zero,
        dispatcher:
            (
              queuedSessionKey,
              queuedMessage, {
              required channelType,
              senderJid,
              senderDisplayName,
              groupJid,
              recipientId,
              threadId,
              attachments = const [],
            }) async {
              try {
                return await dispatchChannelTurn(
                  sessions: sessions,
                  messages: messages,
                  turnManagerGetter: () => turns,
                  sessionKey: queuedSessionKey,
                  message: queuedMessage,
                  channelType: channelType,
                  senderJid: senderJid,
                  senderDisplayName: senderDisplayName,
                  groupJid: groupJid,
                  model: 'row-model',
                  effort: 'high',
                  binding: binding,
                  provenance: _signalProvenance,
                );
              } finally {
                completed.complete();
              }
            },
      );
      addTearDown(queue.dispose);
      final channel = FakeChannel(ownedJids: const {'+1'});
      final pause = PauseController()..pause('admin');
      pause.enqueue(
        ChannelMessage(
          channelType: ChannelType.signal,
          senderJid: '+1',
          text: 'hello',
          metadata: const {'sourceName': 'Alice'},
        ),
        channel,
        sessionKey,
      );

      await ReservedCommandHandler.drainPauseQueue(collapsed: pause.drain()!, queue: queue);
      await completed.future.timeout(const Duration(seconds: 2));

      final session = await sessions.getByKey(sessionKey);
      expect(session?.provider, 'codex');
      expect(session?.securityProfile, 'restricted');
      expect(session?.executionMode, ExecutionMode.container);
      expect(turns.started, isEmpty);
      expect(turns.reserved.single.agentName, 'ana');
      expect(turns.reserved.single.promptScope, PromptScope.restricted);
      expect(turns.reserved.single.model, 'row-model');
      expect(turns.reserved.single.effort, 'high');
      expect(turns.executed.single.source, 'channel');
      expect(channel.sentMessages.single.$2.text, 'reply');
    });
  });

  test('ChannelWiring pause replay retains the bound agent policy through the production queue', () async {
    final config = loadDartclawConfig(
      configPath: 'dartclaw.yaml',
      fileReader: (path) => path == 'dartclaw.yaml'
          ? '''
data_dir: ${tempDir.path}
container:
  enabled: true
channels:
  debounce_window_ms: 0
  signal:
    enabled: true
    dm_allowlist:
      - id: "+46700000001"
        agent: ana
        model: row-model
        effort: high
agent:
  agents:
    ana:
      description: Ana
      prompt: You are Ana.
      provider: codex
      execution: container
      security_profile: restricted
'''
          : null,
      env: {'HOME': tempDir.path},
    );
    final eventBus = EventBus();
    addTearDown(eventBus.dispose);
    final storage = await wireTestStorage(config: config, eventBus: eventBus, exitFn: neverExit);
    final task = TaskWiring(
      config: config,
      dataDir: config.server.dataDir,
      runtimeCwd: tempDir.path,
      eventBus: eventBus,
      storage: storage,
    );
    await task.wirePreServer();
    final ownerWorkspace = Directory(p.join(tempDir.path, 'workspace'))..createSync();
    File(p.join(ownerWorkspace.path, 'SOUL.md')).writeAsStringSync('PAUSE OWNER SOUL MARKER');
    File(p.join(ownerWorkspace.path, 'USER.md')).writeAsStringSync('PAUSE OWNER USER MARKER');
    File(p.join(ownerWorkspace.path, 'TOOLS.md')).writeAsStringSync('PAUSE OWNER TOOLS MARKER');
    File(p.join(ownerWorkspace.path, 'MEMORY.md')).writeAsStringSync('PAUSE OWNER MEMORY MARKER');
    final behavior = BehaviorFileService(workspaceDir: ownerWorkspace.path);
    final agent = config.agent.definitions.single;
    final binder = ChannelAgentBinder(
      agents: {agent.id: agent},
      policyResolver: ExecutionPolicyResolver(config: config, availableContainerProfiles: const {'restricted'}),
      defaultProviderId: 'claude',
      behavior: behavior,
    );
    final turns = RecordingChannelTurnManager()..reservation = Completer<void>();
    addTearDown(turns.executions.dispose);
    final channels = ChannelWiring(
      config: config,
      dataDir: config.server.dataDir,
      port: 0,
      eventBus: eventBus,
      storage: storage,
      task: task,
      resolvedConfigPath: p.join(tempDir.path, 'dartclaw.yaml'),
      agentBinder: binder,
    );
    await channels.wire(
      serverRefGetter: () => throw StateError('the channel queue must use the injected turn manager'),
      turnManagerGetter: () => turns,
      sseBroadcast: SseBroadcast(),
      messageRedactor: null,
      healthService: HealthService(
        worker: FakeAgentHarness(),
        searchDbPath: config.searchDbPath,
        sessionsDir: config.sessionsDir,
        tasksDir: p.join(config.server.dataDir, 'tasks'),
      ),
      configNotifier: ConfigNotifier(config),
    );
    final manager = channels.channelManager!;
    expect(channels.signalChannel, isNotNull);
    expect(manager.channels, isNotEmpty);
    final pause = channels.pauseController!..pause('admin');
    final inbound = ChannelMessage(
      channelType: ChannelType.signal,
      senderJid: '+46700000001',
      text: 'hello while paused',
      metadata: const {'sourceName': 'Alice'},
    );
    final sessionKey = manager.deriveSessionKey(inbound);
    final replyChannel = FakeChannel(type: ChannelType.signal, ownedJids: const {'+46700000001'});
    pause.enqueue(inbound, replyChannel, sessionKey);

    manager.handleInboundMessage(
      ChannelMessage(channelType: ChannelType.signal, senderJid: '+46700000999', text: '/resume'),
    );
    await turns.reservation!.future.timeout(const Duration(seconds: 2));
    expect(pause.isPaused, isFalse);

    final session = await storage.sessions.getByKey(sessionKey);
    expect(session?.provider, 'codex');
    expect(session?.securityProfile, 'restricted');
    expect(session?.executionMode, ExecutionMode.container);
    expect(turns.started, isEmpty);
    expect(turns.reserved.single.agentName, 'ana');
    expect(turns.reserved.single.model, 'row-model');
    expect(turns.reserved.single.effort, 'high');
    expect(turns.reserved.single.promptScope, PromptScope.restricted);
    final prompt = await turns.reserved.single.behaviorOverride!.composeSystemPrompt(
      scope: turns.reserved.single.promptScope!,
    );
    expect(prompt, contains('You are Ana.'));
    expect(prompt, isNot(contains('PAUSE OWNER SOUL MARKER')));
    expect(prompt, isNot(contains('PAUSE OWNER USER MARKER')));
    expect(prompt, isNot(contains('PAUSE OWNER TOOLS MARKER')));
    expect(prompt, isNot(contains('PAUSE OWNER MEMORY MARKER')));
    expect(turns.executed.single.agentName, 'ana');
    expect(turns.executed.single.source, 'channel');
  });

  group('trusted turn context', () {
    late ChannelWiring channels;
    late StorageWiring storage;
    late RecordingChannelTurnManager turns;

    setUp(() async {
      final config = loadDartclawConfig(
        configPath: 'dartclaw.yaml',
        fileReader: (path) => path == 'dartclaw.yaml'
            ? '''
data_dir: ${tempDir.path}
container:
  enabled: true
channels:
  debounce_window_ms: 0
  signal:
    enabled: true
    dm_allowlist:
      - id: "+46700000001"
        agent: ana
agent:
  agents:
    ana:
      description: Ana
      prompt: You are Ana.
      provider: codex
      execution: container
      security_profile: restricted
'''
            : null,
        env: {'HOME': tempDir.path},
      );
      final eventBus = EventBus();
      addTearDown(eventBus.dispose);
      storage = await wireTestStorage(config: config, eventBus: eventBus, exitFn: neverExit);
      final task = TaskWiring(
        config: config,
        dataDir: config.server.dataDir,
        runtimeCwd: tempDir.path,
        eventBus: eventBus,
        storage: storage,
      );
      await task.wirePreServer();
      final ownerWorkspace = Directory(p.join(tempDir.path, 'workspace'))..createSync();
      for (final file in ['SOUL.md', 'USER.md', 'TOOLS.md', 'MEMORY.md']) {
        File(p.join(ownerWorkspace.path, file)).writeAsStringSync(file);
      }
      final agent = config.agent.definitions.single;
      turns = RecordingChannelTurnManager();
      addTearDown(turns.executions.dispose);
      channels = ChannelWiring(
        config: config,
        dataDir: config.server.dataDir,
        port: 0,
        eventBus: eventBus,
        storage: storage,
        task: task,
        resolvedConfigPath: p.join(tempDir.path, 'dartclaw.yaml'),
        agentBinder: ChannelAgentBinder(
          agents: {agent.id: agent},
          policyResolver: ExecutionPolicyResolver(config: config, availableContainerProfiles: const {'restricted'}),
          defaultProviderId: 'claude',
          behavior: BehaviorFileService(workspaceDir: ownerWorkspace.path),
        ),
      );
      await channels.wire(
        serverRefGetter: () => throw StateError('the channel queue must use the injected turn manager'),
        turnManagerGetter: () => turns,
        sseBroadcast: SseBroadcast(),
        messageRedactor: null,
        healthService: HealthService(
          worker: FakeAgentHarness(),
          searchDbPath: config.searchDbPath,
          sessionsDir: config.sessionsDir,
          tasksDir: p.join(config.server.dataDir, 'tasks'),
        ),
        configNotifier: ConfigNotifier(config),
      );
      addTearDown(channels.channelManager!.queue.dispose);
    });

    Future<void> untilDispatched() async {
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (turns.started.isEmpty && turns.reserved.isEmpty) {
        if (DateTime.now().isAfter(deadline)) fail('No turn was dispatched');
        await pumpEventQueue();
      }
    }

    final googleChatThread = ChannelMessage(
      channelType: ChannelType.googlechat,
      senderJid: 'users/42',
      text: 'run the release check',
      metadata: const {'spaceName': 'spaces/AAA', 'threadName': 'spaces/AAA/threads/T1'},
    );

    TurnProvenance expectedFor(String sessionKey) => TurnProvenance.channel(
      channelType: ChannelType.googlechat,
      recipientId: 'spaces/AAA',
      threadId: 'spaces/AAA/threads/T1',
      sessionKey: sessionKey,
      senderId: 'users/42',
    );

    test('run origin thread: the queue route and the direct route build the same provenance for a Google Chat thread message', () async {
      final manager = channels.channelManager!;
      final sessionKey = manager.deriveSessionKey(googleChatThread);
      manager.registerChannel(
        GoogleChatChannel(config: const GoogleChatConfig(enabled: true), restClient: FakeGoogleChatRestClient()),
      );

      manager.handleInboundMessage(googleChatThread);
      await untilDispatched();
      final viaQueue = turns.started.single.provenance;
      turns.started.clear();
      await ChannelWiring.dispatchInboundChannelMessage(
        channelManager: manager,
        sessions: storage.sessions,
        messages: storage.messages,
        turnManagerGetter: () => turns,
        config: DartclawConfig.defaults(),
        message: googleChatThread,
      );
      final viaDirect = turns.started.single.provenance;

      expect(viaQueue, expectedFor(sessionKey));
      expect(viaDirect, viaQueue);
    });

    test('run origin thread: a channel declaring no capability yields none, and a bound agent turn keeps its logical-agent reservation', () async {
      final manager = channels.channelManager!;
      final inbound = ChannelMessage(
        channelType: ChannelType.signal,
        senderJid: '+46700000001',
        text: 'hello',
        metadata: const {'threadName': 'threads/T9'},
      );
      final sessionKey = manager.deriveSessionKey(inbound);

      manager.handleInboundMessage(inbound);
      await untilDispatched();

      expect(turns.started, isEmpty);
      expect(turns.reserved.single.agentName, 'ana');
      expect(
        turns.reserved.single.provenance,
        TurnProvenance.channel(
          channelType: ChannelType.signal,
          recipientId: '+46700000001',
          threadId: null,
          sessionKey: sessionKey,
          senderId: '+46700000001',
        ),
      );
    });
  });

  test('a reloaded max_parallel_turns reaches the channel queue', () async {
    // The queue copies the cap at construction; without a registration with the
    // notifier the documented-reloadable key kept the boot value here.
    DartclawConfig loadWithCap(int cap) => loadDartclawConfig(
      configPath: 'dartclaw.yaml',
      fileReader: (path) => path == 'dartclaw.yaml'
          ? 'data_dir: ${tempDir.path}\n'
                'concurrency:\n'
                '  max_parallel_turns: $cap\n'
                'channels:\n'
                '  signal:\n'
                '    enabled: true\n'
          : null,
      env: {'HOME': tempDir.path},
    );
    final config = loadWithCap(2);
    final notifier = ConfigNotifier(config);
    final eventBus = EventBus();
    addTearDown(eventBus.dispose);
    final storage = await wireTestStorage(config: config, eventBus: eventBus, exitFn: neverExit);
    final task = TaskWiring(
      config: config,
      dataDir: config.server.dataDir,
      runtimeCwd: tempDir.path,
      eventBus: eventBus,
      storage: storage,
    );
    await task.wirePreServer();
    final channels = ChannelWiring(
      config: config,
      dataDir: config.server.dataDir,
      port: 0,
      eventBus: eventBus,
      storage: storage,
      task: task,
      resolvedConfigPath: p.join(tempDir.path, 'dartclaw.yaml'),
    );
    await channels.wire(
      serverRefGetter: () => throw StateError('no server in this test'),
      turnManagerGetter: () => throw StateError('no turn manager in this test'),
      sseBroadcast: SseBroadcast(),
      messageRedactor: null,
      healthService: HealthService(
        worker: FakeAgentHarness(),
        searchDbPath: config.searchDbPath,
        sessionsDir: config.sessionsDir,
        tasksDir: p.join(config.server.dataDir, 'tasks'),
      ),
      configNotifier: notifier,
    );
    final queue = channels.channelManager!.queue;
    addTearDown(queue.dispose);
    expect(queue.maxConcurrentTurns, 2);

    notifier.reload(loadWithCap(5));

    expect(queue.maxConcurrentTurns, 5);
  });

  test('parses each channel section through the shared channel config resolver', () async {
    // A config built by `DartclawConfig.load` has no channel section primed, so
    // the section warnings reach `config.warnings` only if wiring resolves the
    // sections through `resolveChannelConfig` instead of parsing them itself.
    final config = DartclawConfig.load(
      configPath: 'dartclaw.yaml',
      fileReader: (path) => path == 'dartclaw.yaml'
          ? 'data_dir: ${tempDir.path}\n'
                'channels:\n'
                '  signal:\n'
                '    port: nope\n'
                '  whatsapp:\n'
                '    gowa_port: invalid\n'
          : null,
      env: {'HOME': tempDir.path},
    );
    expect(config.warnings, isEmpty);

    final eventBus = EventBus();
    final storage = await wireTestStorage(config: config, eventBus: eventBus, exitFn: neverExit);
    final task = TaskWiring(
      config: config,
      dataDir: config.server.dataDir,
      runtimeCwd: tempDir.path,
      eventBus: eventBus,
      storage: storage,
    );
    await task.wirePreServer();

    final channels = ChannelWiring(
      config: config,
      dataDir: config.server.dataDir,
      port: 0,
      eventBus: eventBus,
      storage: storage,
      task: task,
      resolvedConfigPath: p.join(tempDir.path, 'dartclaw.yaml'),
    );
    await channels.wire(
      serverRefGetter: () => throw StateError('no server in this test'),
      turnManagerGetter: () => throw StateError('no turn manager in this test'),
      sseBroadcast: SseBroadcast(),
      messageRedactor: null,
      healthService: HealthService(
        worker: FakeAgentHarness(),
        searchDbPath: config.searchDbPath,
        sessionsDir: config.sessionsDir,
        tasksDir: p.join(config.server.dataDir, 'tasks'),
      ),
      configNotifier: ConfigNotifier(config),
    );

    expect(config.warnings.where((w) => w.contains('Invalid type for signal.port')), hasLength(1));
    expect(config.warnings.where((w) => w.contains('Invalid type for whatsapp.gowa_port')), hasLength(1));
  });
}

final _signalProvenance = TurnProvenance.channel(
  channelType: ChannelType.signal,
  recipientId: 'alice',
  sessionKey: 'agent:main:signal:dm:alice',
  senderId: 'alice',
);
