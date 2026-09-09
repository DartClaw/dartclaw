import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';
import 'dart:io';

import 'package:dartclaw_runtime/dartclaw_runtime.dart' show HealthService, SseBroadcast;
import 'package:dartclaw_runtime/src/behavior/behavior_file_service.dart';
import 'package:dartclaw_runtime/src/config/config_load.dart';
import 'package:dartclaw_runtime/src/execution_policy_resolver.dart';
import 'package:dartclaw_runtime/src/governance/pause_controller.dart';
import 'package:dartclaw_runtime/src/runtime/channel_agent_binding.dart';
import 'package:dartclaw_runtime/src/runtime/channel_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/feedback_observer_factory.dart';
import 'package:dartclaw_runtime/src/runtime/reserved_command_handler.dart';
import 'package:dartclaw_runtime/src/runtime/task_wiring.dart';
import 'package:dartclaw_runtime/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

import '../execution_coordinator_test_support.dart';
import '../turn_runner_test_support.dart';
import 'harness_wiring_fixture.dart';

typedef _StartedTurn = ({
  String sessionId,
  String? source,
  bool isHumanInput,
  String? model,
  String? effort,
  PromptScope? promptScope,
  TurnOrigin? origin,
});

typedef _ReservedTurn = ({
  String sessionId,
  String agentName,
  String? model,
  String? effort,
  bool isHumanInput,
  BehaviorFileService? behaviorOverride,
  PromptScope? promptScope,
  TurnOrigin? origin,
  String? systemPromptOverride,
  ExecutionPolicy? workerPolicy,
});

typedef _ExecutedTurn = ({String sessionId, String turnId, String? source, String agentName, int messageCount});

/// Records what the channel dispatch asks of the runtime [TurnManager]: the
/// unbound branch reaches [startTurn], the bound branch [reserveTurn] and
/// [executeTurn]. Neither runs a harness.
class _RecordingTurnManager extends TurnManager {
  new()
    : super.fromCoordinator(
        coordinator: coordinatorForRunners([FakeTurnRunner()]),
        turnLimits: const TurnLimitsConfig.defaults(),
      );

  final started = <_StartedTurn>[];
  final reserved = <_ReservedTurn>[];
  final executed = <_ExecutedTurn>[];
  Completer<void>? reservation;
  var _nextTurn = 0;

  @override
  Future<String> startTurn(
    String sessionId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
    String? model,
    String? effort,
    String? systemPromptOverride,
    int? maxTurns,
    Map<String, dynamic>? outputSchema,
    bool outputSchemaWhenSupported = false,
    String? providerSessionId,
    bool requestProviderSessionResume = false,
    String? taskId,
    Duration? turnTimeout,
    bool isHumanInput = false,
    List<String>? allowedTools,
    bool readOnly = false,
    PromptScope? promptScope,
    TurnOrigin? origin,
  }) async {
    started.add((
      sessionId: sessionId,
      source: source,
      isHumanInput: isHumanInput,
      model: model,
      effort: effort,
      promptScope: promptScope,
      origin: origin,
    ));
    return 'turn-${_nextTurn++}';
  }

  @override
  Future<String> reserveTurn(
    String sessionId, {
    String agentName = 'main',
    String? directory,
    String? model,
    String? effort,
    String? systemPromptOverride,
    ExecutionPolicy? workerPolicy,
    int? maxTurns,
    Map<String, dynamic>? outputSchema,
    bool outputSchemaWhenSupported = false,
    String? providerSessionId,
    bool requestProviderSessionResume = false,
    String? taskId,
    Duration? turnTimeout,
    bool isHumanInput = false,
    BehaviorFileService? behaviorOverride,
    PromptScope? promptScope,
    List<String>? allowedTools,
    bool readOnly = false,
    ({String? model, String? effort})? workerProviderOptions,
    TurnOrigin? origin,
  }) async {
    reserved.add((
      sessionId: sessionId,
      agentName: agentName,
      model: model,
      effort: effort,
      isHumanInput: isHumanInput,
      behaviorOverride: behaviorOverride,
      promptScope: promptScope,
      origin: origin,
      systemPromptOverride: systemPromptOverride,
      workerPolicy: workerPolicy,
    ));
    reservation?.complete();
    return 'turn-${_nextTurn++}';
  }

  @override
  void executeTurn(
    String sessionId,
    String turnId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
  }) {
    executed.add((
      sessionId: sessionId,
      turnId: turnId,
      source: source,
      agentName: agentName,
      messageCount: messages.length,
    ));
  }

  @override
  void releaseTurn(String sessionId, String turnId) {}

  @override
  Future<TurnOutcome> waitForOutcome(String sessionId, String turnId) async => TurnOutcome(
    turnId: turnId,
    sessionId: sessionId,
    status: TurnStatus.completed,
    responseText: 'reply',
    completedAt: DateTime.now(),
  );
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw-channel-wiring-test-');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('channel dispatch selects the conversational prompt scope', () async {
    final turns = _RecordingTurnManager();
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
    );

    expect(response, 'reply');
    expect(turns.started, hasLength(1));
    final turn = turns.started.single;
    expect(turn.source, 'channel');
    expect(turn.isHumanInput, isTrue);
    expect(turn.promptScope, PromptScope.primary);
    expect(turn.origin, (channel: 'signal', contact: 'Alice', group: false));
  });

  group('bound channel turn', () {
    const origin = (channel: 'signal', contact: 'Alice', group: false);
    late SessionService sessions;
    late MessageService messages;
    late BehaviorFileService behavior;
    late _RecordingTurnManager turns;

    setUp(() {
      sessions = SessionService(baseDir: tempDir.path);
      messages = MessageService(baseDir: tempDir.path);
      behavior = BehaviorFileService(workspaceDir: p.join(tempDir.path, 'workspace'));
      turns = _RecordingTurnManager();
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
    );

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

    test('a restricted agent gets the restricted scope and no behaviour override', () async {
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
      expect(reservedTurn.behaviorOverride, isNull);
      expect(reservedTurn.agentName, 'sandboxed');
    });

    test('a blank prompt inherits the workspace SOUL: the override is the base service itself', () async {
      const quiet = AgentDefinition(id: 'quiet', description: 'Quiet', prompt: '  ', execution: ExecutionMode.host);
      final binding = binderFor(quiet).bind(const GroupEntry(id: '+1', agent: 'quiet'));

      await dispatch(binding: binding);

      expect(turns.reserved.single.behaviorOverride, same(behavior));
      expect(turns.reserved.single.promptScope, PromptScope.task);
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
            (queuedSessionKey, queuedMessage, {required channelType, senderJid, senderDisplayName, groupJid}) async {
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
    final storage = await wireTestStorage(config: config, eventBus: eventBus, exitFn: _neverExit);
    final task = TaskWiring(
      config: config,
      dataDir: config.server.dataDir,
      runtimeCwd: tempDir.path,
      eventBus: eventBus,
      storage: storage,
    );
    await task.wirePreServer();
    final behavior = BehaviorFileService(workspaceDir: p.join(tempDir.path, 'workspace'));
    final agent = config.agent.definitions.single;
    final binder = ChannelAgentBinder(
      agents: {agent.id: agent},
      policyResolver: ExecutionPolicyResolver(config: config, availableContainerProfiles: const {'restricted'}),
      defaultProviderId: 'claude',
      behavior: behavior,
    );
    final turns = _RecordingTurnManager()..reservation = Completer<void>();
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
    expect(turns.reserved.single.behaviorOverride, isNull);
    expect(turns.executed.single.agentName, 'ana');
    expect(turns.executed.single.source, 'channel');
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
    final storage = await wireTestStorage(config: config, eventBus: eventBus, exitFn: _neverExit);
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
    );

    expect(config.warnings.where((w) => w.contains('Invalid type for signal.port')), hasLength(1));
    expect(config.warnings.where((w) => w.contains('Invalid type for whatsapp.gowa_port')), hasLength(1));
  });
}

Never _neverExit(int code) => throw StateError('exit($code)');
