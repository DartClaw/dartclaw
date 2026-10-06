import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/execution_coordinator.dart';
import 'package:dartclaw_runtime/src/runtime/feedback_observer_factory.dart';
import 'package:dartclaw_runtime/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_slack/dartclaw_slack.dart';
import 'package:dartclaw_slack/testing.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager;
import 'package:test/test.dart';

import '../turn_runner_test_support.dart';

const _snapshot = TurnProgressSnapshot(elapsed: Duration.zero, toolCallCount: 0);

/// A runner whose progress events and active sessions a test scripts, instead of running a harness.
class _ScriptedRunner extends FakeTurnRunner {
  final _events = StreamController<TurnProgressEvent>.broadcast();
  final activeSessions = <String>{};

  @override
  Stream<TurnProgressEvent> get progressEvents => _events.stream;

  @override
  bool isActive(String sessionId) => activeSessions.contains(sessionId);

  void say(String text) => _events.add(TextDeltaProgressEvent(snapshot: _snapshot, text: text));
}

ChannelMessage _inbound(String thread, {String sender = 'U1'}) => ChannelMessage(
  id: 'C1:$thread',
  channelType: ChannelType.slack,
  senderJid: sender,
  groupJid: 'C1',
  text: 'hello',
  metadata: {'spaceName': 'C1', threadIdMetadataKey: thread},
);

void main() {
  late Directory tempDir;
  late SessionService sessions;
  late FakeSlackWebApi api;
  late SlackChannel slack;
  late TurnManager turns;
  late _ScriptedRunner primary;
  final leases = <ExecutionLease>[];

  const googleChatOff = GoogleChatConfig();

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw-feedback-observer-test-');
    sessions = SessionService(baseDir: tempDir.path);
    api = FakeSlackWebApi();
    final manager = ChannelManager(queue: RecordingMessageQueue(), config: const ChannelConfig.defaults());
    slack = SlackChannel(
      config: const SlackConfig(enabled: true),
      api: api,
      dmAccess: DmAccessController(mode: DmAccessMode.open),
      mentionGating: MentionGating(requireMention: false, mentionPatterns: const [], ownJid: ''),
      channelManager: manager,
    );
    primary = _ScriptedRunner();
    final workers = [_ScriptedRunner(), _ScriptedRunner()];
    turns = TurnManager.fromCoordinator(
      turnLimits: const TurnLimitsConfig.defaults(),
      coordinator: ExecutionCoordinator(
        providerCapacities: const {'claude': 2},
        primary: primary,
        admitExecution: (_) async {},
        releaseAdmission: (_) {},
        createWorker: (_) async => workers.removeAt(0),
      ),
    );
  });

  tearDown(() async {
    for (final held in leases) {
      await held.release();
    }
    await turns.executions.dispose();
    tempDir.deleteSync(recursive: true);
  });

  TurnObserver observer({SlackConfig slackConfig = const SlackConfig(enabled: true)}) => FeedbackObserverFactory.build(
    googleChatConfig: googleChatOff,
    slackConfig: slackConfig,
    sessions: sessions,
    turnManagerGetter: () => turns,
  )!;

  /// Leases a worker for [sessionId] as a turn's dispatch does, and marks the session active on it.
  Future<_ScriptedRunner> lease(String sessionId) async {
    final acquired = (await turns.executions.acquire(
      ExecutionRequest(
        surface: ExecutionSurface.logicalAgent,
        providerId: 'claude',
        policy: const ExecutionPolicy.host(),
        sessionId: sessionId,
      ),
    ))!;
    leases.add(acquired);
    final runner = acquired.runner as _ScriptedRunner;
    runner.activeSessions.add(sessionId);
    await pumpEventQueue(); // the coordinator's `acquired` event reaches the observer
    return runner;
  }

  test('no observer is built when neither channel has feedback enabled', () {
    expect(
      FeedbackObserverFactory.build(
        googleChatConfig: googleChatOff,
        slackConfig: const SlackConfig(),
        sessions: sessions,
        turnManagerGetter: () => turns,
      ),
      isNull,
    );
    expect(
      FeedbackObserverFactory.build(
        googleChatConfig: googleChatOff,
        sessions: sessions,
        turnManagerGetter: () => turns,
      ),
      isNull,
    );
  });

  test('one observer serves a Slack turn and ignores a channel it has no feedback for', () async {
    final observe = observer();
    final other = FakeChannel(type: ChannelType.signal);

    final skipped = await observe('key', _inbound('1.1'), other, 'C1', Future.value('reply'));

    expect(skipped, isFalse);
    expect(api.calls, isEmpty);
  });

  group('a turn that starts before its session and runner exist', () {
    test('streams the deltas once the dispatch has created the session and the turn leased a runner', () async {
      const key = 'agent:eng-bot:slack:group:C1:thread:1.1';
      final response = Completer<String>();
      final result = observer()(key, _inbound('1.1'), slack, 'C1', response.future);
      await pumpEventQueue();
      expect(await sessions.getByKey(key), isNull, reason: 'the observer must never create the session');

      // The dispatch pins the bound agent's provider when it creates the session.
      final session = await sessions.getOrCreateByKey(key, type: SessionType.channel, provider: 'codex');
      final runner = await lease(session.id);
      runner.say('Working on ');
      runner.say('it now. ');
      await pumpEventQueue();
      response.complete('Working on it now.');

      expect(await result, isTrue, reason: 'the stream delivered the reply, so the queue skips its own send');
      expect(api.startedStreams.single.threadTs, '1.1');
      expect(
        [api.startedStreams.single.markdownText, ...api.appends.map((a) => a.markdownText)].join(),
        startsWith('Working on'),
      );
      expect(api.posts, isEmpty);
      expect(
        (await sessions.getByKey(key))?.provider,
        'codex',
        reason: 'the session policy stays as the dispatch pinned it',
      );
      expect(await sessions.listSessions(type: SessionType.channel), hasLength(1));
    });

    test('events from a runner busy with another session are not this turn\'s text', () async {
      const key = 'agent:main:slack:group:C1:thread:1.1';
      final response = Completer<String>();
      final result = observer()(key, _inbound('1.1'), slack, 'C1', response.future);
      final session = await sessions.getOrCreateByKey(key, type: SessionType.channel);

      primary.activeSessions.add('someone-else');
      primary.say('not for this thread ');
      await pumpEventQueue();
      response.complete('reply');

      expect(await result, isFalse, reason: 'no delta was this turn\'s, so the queue posts the reply');
      expect(api.startedStreams, isEmpty);
      expect(session.id, isNot('someone-else'));
    });
  });

  group('concurrent threads never cross', () {
    test('each thread streams only its own turn\'s text', () async {
      const keyA = 'agent:main:slack:group:C1:thread:1.1';
      const keyB = 'agent:main:slack:group:C1:thread:2.2';
      final sessionA = await sessions.getOrCreateByKey(keyA, type: SessionType.channel);
      final sessionB = await sessions.getOrCreateByKey(keyB, type: SessionType.channel);
      final responseA = Completer<String>();
      final responseB = Completer<String>();
      final observe = observer();
      final resultA = observe(keyA, _inbound('1.1'), slack, 'C1', responseA.future);
      final resultB = observe(keyB, _inbound('2.2', sender: 'U2'), slack, 'C1', responseB.future);
      final runnerA = await lease(sessionA.id);
      final runnerB = await lease(sessionB.id);

      runnerA.say('alpha ');
      runnerB.say('bravo ');
      await pumpEventQueue();
      runnerA.say('again ');
      await pumpEventQueue();
      responseA.complete('alpha again');
      responseB.complete('bravo');

      expect(await resultA, isTrue);
      expect(await resultB, isTrue);
      final byThread = {for (final start in api.startedStreams) start.threadTs: start.markdownText};
      expect(byThread.keys, unorderedEquals(['1.1', '2.2']));
      expect(byThread['1.1'], isNot(contains('bravo')));
      expect(byThread['2.2'], 'bravo ');
      expect(api.appends.map((append) => append.markdownText).join(), isNot(contains('bravo')));
      final recipients = {for (final start in api.startedStreams) start.threadTs: start.recipientUserId};
      expect(recipients, {'1.1': 'U1', '2.2': 'U2'});
    });
  });

  group('a turn that fails', () {
    test('clears the status and stops the open stream, and leaves the failure to the queue', () async {
      const key = 'agent:main:slack:group:C1:thread:1.1';
      final session = await sessions.getOrCreateByKey(key, type: SessionType.channel);
      final response = Completer<String>();
      final result = observer()(key, _inbound('1.1'), slack, 'C1', response.future);
      final runner = await lease(session.id);
      runner.say('partial answer ');
      await pumpEventQueue();

      response.completeError(StateError('harness crashed'));

      expect(await result, isFalse);
      expect(api.statuses.first.status, 'is working...');
      expect(api.statuses.last.status, '');
      expect(api.stops, hasLength(1));
      expect(api.updates, isEmpty);
    });
  });

  test('a Slack message with no thread streams nothing and shows no status', () async {
    final response = Future.value('reply');
    final noThread = ChannelMessage(
      channelType: ChannelType.slack,
      senderJid: 'U1',
      groupJid: 'C1',
      text: '/cmd',
      metadata: const {'spaceName': 'C1'},
    );

    final delivered = await observer()('key', noThread, slack, 'C1', response);

    expect(delivered, isFalse);
    expect(api.calls, isEmpty, reason: 'a thread-less message has nothing to show a status on');
  });

  test('streaming off keeps the chunked reply path while the status still runs', () async {
    final off = SlackChannel(
      config: const SlackConfig(enabled: true, streaming: false),
      api: api,
      dmAccess: DmAccessController(mode: DmAccessMode.open),
      mentionGating: MentionGating(requireMention: false, mentionPatterns: const [], ownJid: ''),
      channelManager: ChannelManager(queue: RecordingMessageQueue(), config: const ChannelConfig.defaults()),
    );
    final session = await sessions.getOrCreateByKey('k', type: SessionType.channel);
    final response = Completer<String>();
    final result = observer()('k', _inbound('1.1'), off, 'C1', response.future);
    final runner = await lease(session.id);
    runner.say('text ');
    await pumpEventQueue();
    response.complete('text');

    expect(await result, isFalse);
    expect(api.startedStreams, isEmpty);
    expect(api.statuses.map((s) => s.status), ['is working...', '']);
  });
}
