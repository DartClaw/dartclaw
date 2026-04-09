import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeChannel, InMemoryTaskRepository;
import 'package:test/test.dart';

void main() {
  group('advisor support classes', () {
    test('SlidingContextWindow drops oldest entries on overflow', () {
      final window = SlidingContextWindow(maxEntries: 2);
      window.add(
        ContextEntry(
          kind: 'one',
          summary: 'first',
          sessionKey: 'session-1',
          timestamp: DateTime.parse('2026-03-25T10:00:00Z'),
          estimatedTokens: 1,
        ),
      );
      window.add(
        ContextEntry(
          kind: 'two',
          summary: 'second',
          sessionKey: 'session-1',
          timestamp: DateTime.parse('2026-03-25T10:01:00Z'),
          estimatedTokens: 1,
        ),
      );
      window.add(
        ContextEntry(
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
      const parser = AdvisorOutputParser();
      final output = parser.parse('{"status":"stuck","observation":"Loop detected","suggestion":"Narrow scope"}');

      expect(output.status, AdvisorStatus.stuck);
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
      channel = FakeChannel(type: ChannelType.whatsapp, ownedJids: {'group@g.us'});
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

      expect(channel.sentMessages, hasLength(1));
      expect(channel.sentMessages.single.$1, 'group@g.us');
      expect(channel.sentMessages.single.$2.text, contains('[Advisor] Status: stuck'));
      expect(insights, hasLength(1));
      expect(insights.single.status, 'stuck');
      expect(secondaryHarness.lastMaxTurns, 1);
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
  Future<void> cancel() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    await _events.close();
  }
}
