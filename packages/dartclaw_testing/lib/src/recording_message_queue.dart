import 'package:dartclaw_core/dartclaw_core.dart';

typedef RecordedEnqueue = ({ChannelMessage message, Channel sourceChannel, String sessionKey});

typedef RecordingMessageQueueEnqueueCallback =
    void Function(ChannelMessage message, Channel sourceChannel, String sessionKey);

/// [MessageQueue] fake that records enqueues and can optionally forward to super.
class RecordingMessageQueue extends MessageQueue {
  RecordingMessageQueue({
    super.debounceWindow,
    super.maxConcurrentTurns,
    super.maxQueueDepth,
    super.maxQueued,
    super.defaultRetryPolicy,
    super.queueStrategy,
    TurnDispatcher? dispatcher,
    super.turnObserver,
    super.redactor,
    super.random,
    super.isAdmin,
    this.forwardToSuper = false,
    this.onEnqueue,
  }) : super(dispatcher: dispatcher ?? ((sessionKey, message, {senderJid, senderDisplayName}) async => 'ok'));

  final bool forwardToSuper;
  final RecordingMessageQueueEnqueueCallback? onEnqueue;

  final List<RecordedEnqueue> enqueued = [];

  bool disposeCalled = false;

  @override
  void enqueue(ChannelMessage message, Channel sourceChannel, String sessionKey) {
    enqueued.add((message: message, sourceChannel: sourceChannel, sessionKey: sessionKey));
    onEnqueue?.call(message, sourceChannel, sessionKey);
    if (forwardToSuper) {
      super.enqueue(message, sourceChannel, sessionKey);
    }
  }

  @override
  void dispose() {
    disposeCalled = true;
    if (forwardToSuper) {
      super.dispose();
    }
  }
}
