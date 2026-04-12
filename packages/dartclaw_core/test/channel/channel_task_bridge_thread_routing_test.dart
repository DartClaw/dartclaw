import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeChannel;
import 'package:test/test.dart';

void main() {
  group('ChannelTaskBridge — thread routing', () {
    late FakeChannel channel;
    late Directory tempDir;

    ThreadBinding makeBinding({
      String channelType = 'googlechat',
      String threadId = 'spaces/AAAA/threads/CCCC',
      String taskId = 'task-123',
      String sessionKey = 'bound-session-key',
    }) {
      final now = DateTime.now();
      return ThreadBinding(
        channelType: channelType,
        threadId: threadId,
        taskId: taskId,
        sessionKey: sessionKey,
        createdAt: now,
        lastActivity: now,
      );
    }

    ChannelMessage makeGchatMessage({String text = 'hello', String? threadName}) {
      return ChannelMessage(
        channelType: ChannelType.googlechat,
        senderJid: 'users/sender1',
        text: text,
        metadata: {'spaceName': 'spaces/AAAA', 'threadName': ?threadName},
      );
    }

    setUp(() async {
      channel = FakeChannel(ownedJids: {'users/sender1', 'spaces/AAAA'});
      tempDir = await Directory.systemTemp.createTemp('bridge_thread_test_');
    });

    tearDown(() async {
      // Wait briefly for any unawaited file I/O (e.g., updateLastActivity persists)
      // to complete before deleting the temp directory.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    Future<({ThreadBindingStore store, ChannelTaskBridge bridge})> setupWithBinding({
      bool threadBindingEnabled = true,
    }) async {
      final file = File('${tempDir.path}/bindings.json');
      final store = ThreadBindingStore(file);
      await store.load();
      await store.create(makeBinding());

      final bridge = ChannelTaskBridge(threadBindings: store, threadBindingEnabled: threadBindingEnabled);
      return (store: store, bridge: bridge);
    }

    test('message in bound thread routes to task session when thread binding enabled', () async {
      final setup = await setupWithBinding();
      final bridge = setup.bridge;

      final List<String> enqueuedSessionKeys = [];
      final msg = makeGchatMessage(threadName: 'spaces/AAAA/threads/CCCC');

      final handled = await bridge.tryHandle(
        msg,
        channel,
        sessionKey: 'default-session',
        enqueue: (msg, ch, sessionKey) => enqueuedSessionKeys.add(sessionKey),
      );

      expect(handled, isTrue);
      expect(enqueuedSessionKeys, equals(['bound-session-key']));
    });

    test('message in unbound thread falls through to normal routing', () async {
      final setup = await setupWithBinding();
      final bridge = setup.bridge;

      final List<String> enqueuedSessionKeys = [];
      final msg = makeGchatMessage(threadName: 'spaces/AAAA/threads/UNBOUND');

      final handled = await bridge.tryHandle(
        msg,
        channel,
        sessionKey: 'default-session',
        enqueue: (msg, ch, sessionKey) => enqueuedSessionKeys.add(sessionKey),
      );

      expect(handled, isFalse);
      expect(enqueuedSessionKeys, isEmpty);
    });

    test('message without threadId falls through — no thread binding check', () async {
      final setup = await setupWithBinding();
      final bridge = setup.bridge;

      final List<String> enqueuedSessionKeys = [];
      final msg = makeGchatMessage(); // no threadName in metadata

      final handled = await bridge.tryHandle(
        msg,
        channel,
        sessionKey: 'default-session',
        enqueue: (msg, ch, sessionKey) => enqueuedSessionKeys.add(sessionKey),
      );

      expect(handled, isFalse);
      expect(enqueuedSessionKeys, isEmpty);
    });

    test('thread routing skipped when threadBindingEnabled is false', () async {
      final setup = await setupWithBinding(threadBindingEnabled: false);
      final bridge = setup.bridge;

      final List<String> enqueuedSessionKeys = [];
      final msg = makeGchatMessage(threadName: 'spaces/AAAA/threads/CCCC');

      final handled = await bridge.tryHandle(
        msg,
        channel,
        sessionKey: 'default-session',
        enqueue: (msg, ch, sessionKey) => enqueuedSessionKeys.add(sessionKey),
      );

      expect(handled, isFalse);
      expect(enqueuedSessionKeys, isEmpty);
    });

    test('thread routing skipped when enqueue callback is null', () async {
      final setup = await setupWithBinding();
      final bridge = setup.bridge;

      final msg = makeGchatMessage(threadName: 'spaces/AAAA/threads/CCCC');

      final handled = await bridge.tryHandle(
        msg,
        channel,
        sessionKey: 'default-session',
        // No enqueue callback.
      );

      expect(handled, isFalse);
    });

    test('thread routing updates lastActivity on the binding', () async {
      final setup = await setupWithBinding();
      final bridge = setup.bridge;
      final store = setup.store;

      final before = store.lookupByThread('googlechat', 'spaces/AAAA/threads/CCCC')!.lastActivity;
      await Future<void>.delayed(const Duration(milliseconds: 5));

      final msg = makeGchatMessage(threadName: 'spaces/AAAA/threads/CCCC');
      await bridge.tryHandle(msg, channel, sessionKey: 'default-session', enqueue: (msg, ch, sk) {});

      // Give the unawaited updateLastActivity time to complete.
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final after = store.lookupByThread('googlechat', 'spaces/AAAA/threads/CCCC')!.lastActivity;
      expect(after.isAfter(before), isTrue);
    });

    test('non-thread messages with bridge wired but no bindings fall through (regression)', () async {
      final file = File('${tempDir.path}/bindings.json');
      final store = ThreadBindingStore(file);
      await store.load(); // empty store

      final bridge = ChannelTaskBridge(threadBindings: store, threadBindingEnabled: true);

      final msg = ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'sender@s.whatsapp.net', text: 'hello');
      final handled = await bridge.tryHandle(msg, channel, sessionKey: 'sk');
      expect(handled, isFalse);
    });
  });
}
