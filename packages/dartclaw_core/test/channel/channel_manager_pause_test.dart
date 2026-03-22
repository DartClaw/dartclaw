import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeChannel;
import 'package:test/test.dart';

void main() {
  group('ChannelManager — pause interception', () {
    late FakeChannel channel;
    late MessageQueue queue;
    late ChannelManager manager;
    final dispatched = <(String, String)>[];

    // Pause callbacks — backed by a simple mutable bool.
    late bool paused;
    final queued = <(ChannelMessage, Channel, String)>[];
    final sent = <(String, ChannelResponse)>[];

    MessageQueue makeQueue() => MessageQueue(
      debounceWindow: const Duration(milliseconds: 50),
      dispatcher: (sessionKey, message, {String? senderJid, String? senderDisplayName}) async {
        dispatched.add((sessionKey, message));
        return 'ok';
      },
    );

    setUp(() {
      dispatched.clear();
      queued.clear();
      sent.clear();
      paused = false;
      channel = FakeChannel(ownedJids: {'sender@s.whatsapp.net'});
    });

    tearDown(() => manager.dispose());

    // ---- No pause callbacks (backward compat) ----

    test('no pause callbacks — message routes to queue normally', () async {
      queue = makeQueue();
      manager = ChannelManager(queue: queue, config: const ChannelConfig.defaults());
      manager.registerChannel(channel);

      final msg = ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'sender@s.whatsapp.net', text: 'hi');
      manager.handleInboundMessage(msg);

      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(dispatched, hasLength(1));
    });

    // ---- Pause callbacks wired ----

    ChannelManager buildManager() {
      // Capture sends via the real FakeChannel.sent is tricky since ChannelManager uses
      // the channel's sendMessage. We intercept via a spy channel.
      final spyChannel = _SpyChannel(ownedJids: {'sender@s.whatsapp.net'}, sentOut: sent);
      channel = FakeChannel(ownedJids: const {});
      // rebuild channel variable for tests that need it
      queue = makeQueue();
      final m = ChannelManager(
        queue: queue,
        config: const ChannelConfig.defaults(),
        isPaused: () => paused,
        enqueueForPause: (msg, ch, sk) {
          queued.add((msg, ch, sk));
          return true; // always succeeds
        },
        pausedByName: () => 'admin',
      );
      m.registerChannel(spyChannel);
      return m;
    }

    test('when not paused — message routes to queue normally', () async {
      manager = buildManager();
      paused = false;
      final msg = ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'sender@s.whatsapp.net', text: 'hi');
      manager.handleInboundMessage(msg);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(dispatched, hasLength(1));
      expect(queued, isEmpty);
    });

    test('when paused — message goes to pause queue, not MessageQueue', () async {
      manager = buildManager();
      paused = true;
      final msg = ChannelMessage(
        channelType: ChannelType.whatsapp,
        senderJid: 'sender@s.whatsapp.net',
        text: 'queued msg',
      );
      manager.handleInboundMessage(msg);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(dispatched, isEmpty);
      expect(queued, hasLength(1));
      expect(queued.first.$1.text, 'queued msg');
    });

    test('when paused — acknowledgment is sent to sender', () async {
      manager = buildManager();
      paused = true;
      final msg = ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'sender@s.whatsapp.net', text: 'hello');
      manager.handleInboundMessage(msg);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(sent, hasLength(1));
      expect(sent.first.$2.text, contains('paused'));
    });

    test('when paused and queue full — queue-full acknowledgment sent', () async {
      // enqueueForPause returns false = queue full
      sent.clear();
      queue = makeQueue();
      final spyChannel = _SpyChannel(ownedJids: {'sender@s.whatsapp.net'}, sentOut: sent);
      manager = ChannelManager(
        queue: queue,
        config: const ChannelConfig.defaults(),
        isPaused: () => true,
        enqueueForPause: (msg, ch, sk) => false, // queue full
        pausedByName: () => 'admin',
      );
      manager.registerChannel(spyChannel);

      final msg = ChannelMessage(
        channelType: ChannelType.whatsapp,
        senderJid: 'sender@s.whatsapp.net',
        text: 'overflow',
      );
      manager.handleInboundMessage(msg);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(dispatched, isEmpty);
      expect(sent, hasLength(1));
      expect(sent.first.$2.text, contains('full'));
    });

    test('when paused — bound-thread messages are queued with the bound session key', () async {
      sent.clear();
      queue = makeQueue();
      final spyChannel = _SpyChannel(ownedJids: {'spaces/AAAA', 'users/123'}, sentOut: sent);
      final binding = ThreadBinding(
        channelType: ChannelType.googlechat.name,
        threadId: 'spaces/AAAA/threads/THREAD-1',
        taskId: 'task-123',
        sessionKey: 'task-session-key',
        createdAt: DateTime.parse('2026-03-21T10:00:00Z'),
        lastActivity: DateTime.parse('2026-03-21T10:00:00Z'),
      );
      manager = ChannelManager(
        queue: queue,
        config: const ChannelConfig.defaults(),
        taskBridge: _BoundThreadBridge(binding),
        isPaused: () => true,
        enqueueForPause: (msg, ch, sk) {
          queued.add((msg, ch, sk));
          return true;
        },
        pausedByName: () => 'admin',
      );
      manager.registerChannel(spyChannel);

      manager.handleInboundMessage(
        ChannelMessage(
          channelType: ChannelType.googlechat,
          senderJid: 'users/123',
          groupJid: 'spaces/AAAA',
          text: 'please continue',
          metadata: const {'spaceName': 'spaces/AAAA', 'threadName': 'spaces/AAAA/threads/THREAD-1'},
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(dispatched, isEmpty);
      expect(queued, hasLength(1));
      expect(queued.single.$3, 'task-session-key');
      expect(sent, hasLength(1));
      expect(sent.single.$2.text, contains('queued'));
    });
  });
}

class _SpyChannel extends Channel {
  _SpyChannel({required Set<String> ownedJids, required this.sentOut}) : _ownedJids = ownedJids;

  final Set<String> _ownedJids;
  final List<(String, ChannelResponse)> sentOut;

  @override
  String get name => 'spy';
  @override
  ChannelType get type => ChannelType.whatsapp;

  @override
  bool ownsJid(String jid) => _ownedJids.contains(jid);

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> sendMessage(String recipientId, ChannelResponse response) async {
    sentOut.add((recipientId, response));
  }
}

class _BoundThreadBridge extends ChannelTaskBridge {
  final ThreadBinding binding;

  _BoundThreadBridge(this.binding);

  @override
  bool isReservedCommand(String text) => false;

  @override
  ThreadBinding? lookupThreadBinding(ChannelMessage message) => binding;

  @override
  Future<bool> tryHandle(
    ChannelMessage message,
    Channel channel, {
    required String sessionKey,
    void Function(ChannelMessage, Channel, String)? enqueue,
    String? boundTaskId,
    ThreadBinding? boundThreadBinding,
  }) async {
    return false;
  }
}
