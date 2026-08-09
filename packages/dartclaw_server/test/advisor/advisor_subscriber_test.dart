import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide HarnessPool, TurnRunner;
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_server/dartclaw_server.dart' hide HarnessPool, TurnRunner;
import 'package:dartclaw_server/src/advisor/advisor_subscriber.dart' as advisor;
import 'package:dartclaw_server/src/harness_pool.dart' show HarnessPool;
import 'package:dartclaw_server/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart'
    show FakeChannel, FakeGoogleChatRestClient, InMemoryTaskRepository;
import 'package:test/test.dart';

void main() {
  group('advisor support classes', () {
    test('SlidingContextWindow drops oldest entries on overflow', () {
      final window = advisor.SlidingContextWindow(maxEntries: 2);
      window.add(
        advisor.ContextEntry(
          kind: 'one',
          summary: 'first',
          sessionKey: 'session-1',
          timestamp: DateTime.parse('2026-03-25T10:00:00Z'),
          estimatedTokens: 1,
        ),
      );
      window.add(
        advisor.ContextEntry(
          kind: 'two',
          summary: 'second',
          sessionKey: 'session-1',
          timestamp: DateTime.parse('2026-03-25T10:01:00Z'),
          estimatedTokens: 1,
        ),
      );
      window.add(
        advisor.ContextEntry(
          kind: 'three',
          summary: 'third',
          sessionKey: 'session-1',
          timestamp: DateTime.parse('2026-03-25T10:02:00Z'),
          estimatedTokens: 1,
        ),
      );

      expect(window.entries.map((entry) => entry.kind), ['two', 'three']);
    });

    test('AdvisorOutputParser parses JSON payloads', () {
      const parser = advisor.AdvisorOutputParser();
      final output = parser.parse('{"status":"stuck","observation":"Loop detected","suggestion":"Narrow scope"}');

      expect(output.status, advisor.AdvisorStatus.stuck);
      expect(output.observation, 'Loop detected');
      expect(output.suggestion, 'Narrow scope');
    });
  });

  group('AdvisorSubscriber', () {
    late Directory tempDir;
    late SessionService sessions;
    late MessageService messages;
    late EventBus eventBus;
    late FakeChannel channel;
    late ChannelManager channelManager;
    late HarnessPool pool;
    late AdvisorSubscriber subscriber;
    late _AdvisorHarness primaryHarness;
    late _AdvisorHarness secondaryHarness;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('advisor_subscriber_test_');
      sessions = SessionService(baseDir: tempDir.path);
      messages = MessageService(baseDir: tempDir.path);
      eventBus = EventBus();
      channel = FakeChannel(
        type: ChannelType.whatsapp,
        ownedJids: {'group@g.us'},
        responseFormatter: (text) => [
          ChannelResponse(text: 'formatted:$text'),
          const ChannelResponse(text: 'continued'),
        ],
      );
      channelManager = ChannelManager(
        queue: MessageQueue(dispatcher: (sessionKey, message, {senderJid, senderDisplayName}) async => ''),
        config: const ChannelConfig.defaults(),
      )..registerChannel(channel);

      primaryHarness = _AdvisorHarness('{"status":"on_track","observation":"Things look steady"}');
      secondaryHarness = _AdvisorHarness(
        '{"status":"stuck","observation":"The group is blocked","suggestion":"Pick one failing path"}',
      );
      pool = HarnessPool(
        runners: [
          _makeRunner(messages: messages, sessions: sessions, harness: primaryHarness),
          _makeRunner(messages: messages, sessions: sessions, harness: secondaryHarness),
        ],
        maxConcurrentTasks: 1,
      );

      subscriber = AdvisorSubscriber(
        pool: pool,
        sessions: sessions,
        taskService: TaskService(InMemoryTaskRepository()),
        channelManager: channelManager,
        eventBus: eventBus,
        triggers: const ['explicit'],
      );
      subscriber.subscribe();
    });

    tearDown(() async {
      await subscriber.dispose();
      await eventBus.dispose();
      await pool.dispose();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('explicit advisor mention executes a turn, emits event, and replies to channel', () async {
      final insights = <AdvisorInsightEvent>[];
      eventBus.on<AdvisorInsightEvent>().listen(insights.add);

      eventBus.fire(
        AdvisorMentionEvent(
          senderJid: 'sender@s.whatsapp.net',
          channelType: 'whatsapp',
          recipientId: 'group@g.us',
          threadId: 'group@g.us',
          messageText: '@advisor should we change direction?',
          sessionKey: 'agent:main:group:whatsapp:group@g.us',
          timestamp: DateTime.now(),
        ),
      );

      for (var i = 0; i < 20 && channel.sentMessages.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(channel.sentMessages, hasLength(2));
      expect(channel.sentMessages.map((message) => message.$1), everyElement('group@g.us'));
      expect(channel.sentMessages.first.$2.text, contains('formatted:[Advisor] Status: stuck'));
      expect(channel.sentMessages.last.$2.text, 'continued');
      expect(insights, hasLength(1));
      expect(insights.single.status, 'stuck');
      expect(secondaryHarness.lastMaxTurns, 1);
    });

    test('Google advisor output keeps cards and formats Markdown fallback text', () async {
      final googleChannel = _AdvisorGoogleChatChannel();
      channelManager.registerChannel(googleChannel);
      final router = advisor.AdvisorOutputRouter(
        channelManager: channelManager,
        eventBus: eventBus,
        googleChatCardBuilder: const ChatCardBuilder(),
      );

      await router.route(
        const advisor.AdvisorOutput(
          status: advisor.AdvisorStatus.stuck,
          observation: '**Blocked** on `build`.',
          suggestion: 'Try **one** path.',
        ),
        const advisor.AdvisorTriggerContext(
          type: advisor.AdvisorTriggerType.explicit,
          reason: 'mention',
          sessionKey: 'agent:main:group:googlechat:spaces/AAA',
          channelType: 'googlechat',
          recipientId: 'spaces/AAA',
        ),
        const [],
      );

      expect(googleChannel.sent, hasLength(1));
      final response = googleChannel.sent.single.$2;
      expect(response.text, contains('Observation: *Blocked* on `build`.'));
      expect(response.structuredPayload, isNotNull);
      expect(jsonEncode(response.structuredPayload), isNot(contains('**')));
    });

    test('Google advisor output preserves existing-thread card delivery', () async {
      final googleChannel = _AdvisorGoogleChatChannel();
      channelManager.registerChannel(googleChannel);
      final router = advisor.AdvisorOutputRouter(
        channelManager: channelManager,
        eventBus: eventBus,
        googleChatCardBuilder: const ChatCardBuilder(),
      );

      await router.route(
        const advisor.AdvisorOutput(status: advisor.AdvisorStatus.onTrack, observation: 'Steady.'),
        const advisor.AdvisorTriggerContext(
          type: advisor.AdvisorTriggerType.explicit,
          reason: 'mention',
          sessionKey: 'agent:main:group:googlechat:spaces/AAA',
          channelType: 'googlechat',
          recipientId: 'spaces/AAA',
          threadId: 'spaces/AAA/threads/BBB',
        ),
        const [],
      );

      expect(googleChannel.threaded, hasLength(1));
      expect(googleChannel.threaded.single.$1, 'spaces/AAA');
      expect(googleChannel.threaded.single.$3, 'spaces/AAA/threads/BBB');
      expect(googleChannel.threaded.single.$2.structuredPayload, isNotNull);
      expect(googleChannel.sent, isEmpty);
    });
  });
}

TurnRunner _makeRunner({
  required MessageService messages,
  required SessionService sessions,
  required _AdvisorHarness harness,
}) {
  return TurnRunner(
    harness: harness,
    messages: messages,
    behavior: BehaviorFileService(workspaceDir: Directory.systemTemp.path),
    sessions: sessions,
  );
}

class _AdvisorHarness implements AgentHarness {
  @override
  String skillActivationLine(String skill) => "Use the '$skill' skill.";

  _AdvisorHarness(this._responseText);

  final String _responseText;
  final _events = StreamController<BridgeEvent>.broadcast();
  int? lastMaxTurns;

  @override
  bool get supportsCostReporting => true;

  @override
  bool get supportsToolApproval => true;

  @override
  bool get supportsStreaming => true;

  @override
  bool get supportsCachedTokens => false;

  @override
  bool get supportsSessionContinuity => false;

  @override
  bool get supportsPreCompactHook => false;

  @override
  PromptStrategy get promptStrategy => PromptStrategy.replace;

  @override
  WorkerState get state => WorkerState.idle;

  @override
  Stream<BridgeEvent> get events => _events.stream;

  @override
  Future<void> start() async {}

  @override
  Future<Map<String, dynamic>> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    String? agentId,
    Map<String, dynamic>? mcpServers,
    bool resume = false,
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
  }) async {
    lastMaxTurns = maxTurns;
    _events.add(DeltaEvent(_responseText));
    await Future<void>.delayed(Duration.zero);
    return {'input_tokens': 12, 'output_tokens': 18, 'model': model ?? 'sonnet'};
  }

  @override
  Future<void> resetSessionContinuity(String sessionId) async {}

  @override
  Future<void> cancel() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    await _events.close();
  }
}

class _AdvisorGoogleChatChannel extends GoogleChatChannel {
  _AdvisorGoogleChatChannel()
    : super(config: const GoogleChatConfig(enabled: true), restClient: FakeGoogleChatRestClient());

  final List<(String, ChannelResponse)> sent = [];
  final List<(String, ChannelResponse, String)> threaded = [];

  @override
  Future<void> sendMessage(String recipientJid, ChannelResponse response) async {
    sent.add((recipientJid, response));
  }

  @override
  Future<void> sendMessageToThreadName(
    String recipientJid,
    ChannelResponse response, {
    required String threadName,
  }) async {
    threaded.add((recipientJid, response, threadName));
  }
}
