@Tags(['integration'])
library;

import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeChannel, flushAsync;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late File bindingsFile;
  late ThreadBindingStore store;
  late EventBus eventBus;
  late FakeChannel channel;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('thread_binding_lifecycle_test_');
    bindingsFile = File('${tempDir.path}/thread-bindings.json');
    store = ThreadBindingStore(bindingsFile);
    await store.load();
    eventBus = EventBus();
    channel = FakeChannel(ownedJids: {'users/sender1', 'spaces/X'});
  });

  tearDown(() async {
    await eventBus.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  ThreadBinding makeBinding({
    String channelType = 'googlechat',
    String threadId = 'spaces/X/threads/A',
    String taskId = 'task-abc',
    String sessionKey = 'session-xyz',
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

  ChannelMessage makeBoundMessage({String threadId = 'spaces/X/threads/A', String text = 'hello'}) {
    return ChannelMessage(
      channelType: ChannelType.googlechat,
      senderJid: 'users/sender1',
      text: text,
      metadata: {'spaceName': 'spaces/X', 'threadName': threadId},
    );
  }

  // ---------------------------------------------------------------------------
  // TC-1: Bound thread routing — ChannelTaskBridge routes to bound session
  // ---------------------------------------------------------------------------

  test('bound thread: ChannelTaskBridge routes message to the bound task session', () async {
    final binding = makeBinding();
    await store.create(binding);
    final bridge = ChannelTaskBridge(threadBindings: store, threadBindingEnabled: true);
    final enqueuedSessionKeys = <String>[];

    final handled = await bridge.tryHandle(
      makeBoundMessage(),
      channel,
      sessionKey: 'default-session',
      enqueue: (_, _, sessionKey) => enqueuedSessionKeys.add(sessionKey),
    );

    expect(handled, isTrue);
    expect(enqueuedSessionKeys, equals(['session-xyz']));
  });

  // ---------------------------------------------------------------------------
  // TC-2: Unbound thread routing — ChannelTaskBridge falls through
  // ---------------------------------------------------------------------------

  test('unbound thread: ChannelTaskBridge falls through to default handling', () async {
    final bridge = ChannelTaskBridge(threadBindings: store, threadBindingEnabled: true);
    final enqueuedSessionKeys = <String>[];

    final handled = await bridge.tryHandle(
      makeBoundMessage(threadId: 'spaces/X/threads/UNBOUND'),
      channel,
      sessionKey: 'default-session',
      enqueue: (_, _, sessionKey) => enqueuedSessionKeys.add(sessionKey),
    );

    expect(handled, isFalse);
    expect(enqueuedSessionKeys, isEmpty);
  });

  // ---------------------------------------------------------------------------
  // TC-3: Auto-unbind on terminal task state via EventBus
  // ---------------------------------------------------------------------------

  test('auto-unbind: terminal task state removes binding and future routing falls through', () async {
    final binding = makeBinding();
    await store.create(binding);
    final bridge = ChannelTaskBridge(threadBindings: store, threadBindingEnabled: true);
    final enqueuedBefore = <String>[];
    final enqueuedAfter = <String>[];

    final handledBefore = await bridge.tryHandle(
      makeBoundMessage(text: 'before terminal state'),
      channel,
      sessionKey: 'default-session',
      enqueue: (_, _, sessionKey) => enqueuedBefore.add(sessionKey),
    );
    expect(handledBefore, isTrue);
    expect(enqueuedBefore, equals(['session-xyz']));

    final manager = ThreadBindingLifecycleManager(
      store: store,
      eventBus: eventBus,
      idleTimeout: const Duration(hours: 1),
      cleanupInterval: const Duration(hours: 24),
    );
    manager.start();

    eventBus.fire(
      TaskStatusChangedEvent(
        taskId: 'task-abc',
        oldStatus: TaskStatus.running,
        newStatus: TaskStatus.accepted,
        trigger: 'test',
        timestamp: DateTime.now(),
      ),
    );

    // Flush to allow the stream listener to process the event
    await flushAsync(2);

    manager.dispose();

    final afterUnbind = store.lookupByThread('googlechat', 'spaces/X/threads/A');
    expect(afterUnbind, isNull);

    final handledAfter = await bridge.tryHandle(
      makeBoundMessage(text: 'after terminal state'),
      channel,
      sessionKey: 'default-session',
      enqueue: (_, _, sessionKey) => enqueuedAfter.add(sessionKey),
    );
    expect(handledAfter, isFalse);
    expect(enqueuedAfter, isEmpty);
  });
}
