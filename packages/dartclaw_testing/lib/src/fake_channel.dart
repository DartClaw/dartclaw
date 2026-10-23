import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';

/// Recording [Channel] fake for inbound routing and delivery tests.
class FakeChannel extends Channel {
  /// Creates a fake channel with configurable ownership and send behavior.
  new({
    this.name = 'fake',
    this.type = ChannelType.whatsapp,
    this.ownedJids = const {},
    this.ownsAllJids = false,
    this.throwOnSend = false,
    this.responseFormatter,
    this.threadedNotifications,
  });

  @override
  final String name;

  @override
  final ChannelType type;

  @override
  final ThreadedNotifications? threadedNotifications;

  /// JIDs explicitly owned by this channel.
  final Set<String> ownedJids;

  /// Whether [ownsJid] should return true for every input.
  final bool ownsAllJids;

  /// Whether [sendMessage] should throw instead of recording.
  bool throwOnSend;

  /// Optional formatter used to exercise channel-specific delivery paths.
  final List<ChannelResponse> Function(String text)? responseFormatter;

  /// Whether [connect] has been called without a matching [disconnect].
  bool connected = false;

  /// Number of [connect] calls observed.
  int connectCallCount = 0;

  /// Number of [disconnect] calls observed.
  int disconnectCallCount = 0;

  /// Recorded outbound sends as `(recipientJid, response)` tuples.
  final List<(String, ChannelResponse)> sentMessages = [];

  @override
  Future<void> connect() async {
    connectCallCount += 1;
    connected = true;
  }

  @override
  Future<void> disconnect() async {
    disconnectCallCount += 1;
    connected = false;
  }

  @override
  bool ownsJid(String jid) => ownsAllJids || ownedJids.contains(jid);

  @override
  Future<void> sendMessage(String recipientJid, ChannelResponse response) async {
    if (throwOnSend) {
      throw StateError('send failed');
    }
    sentMessages.add((recipientJid, response));
  }

  @override
  List<ChannelResponse> formatResponse(String text) => responseFormatter?.call(text) ?? super.formatResponse(text);
}

/// One send a [FakeThreadedNotifications] received.
typedef RecordedThreadedSend = ({
  String recipientId,
  ChannelResponse response,
  String? threadKey,
  String? threadId,
  ThreadedPost? post,
});

/// Recording [ThreadedNotifications] fake: reads the thread from a metadata key,
/// renders a marker card beside the plain text, and answers sends from a script.
class FakeThreadedNotifications implements ThreadedNotifications {
  /// Creates a fake reading inbound threads from `metadata[threadMetadataKey]`.
  new({this.threadMetadataKey = 'fakeThread'});

  /// Inbound metadata key [extractThread] reads.
  final String threadMetadataKey;

  /// Whether new-thread sends report no thread identity.
  bool newThreadReturnsNull = false;

  /// Whether existing-thread sends fail by returning `null`.
  bool existingThreadReturnsNull = false;

  /// Thrown by every send when set.
  Object? sendError;

  /// Every notification handed to [render], in call order.
  final List<ChannelNotification> rendered = [];

  /// Every send, in call order.
  final List<RecordedThreadedSend> sends = [];

  /// Every edit as `(recipientId, messageId, response)`, in call order.
  final List<(String, String, ChannelResponse)> edits = [];

  /// Whether edits fail by returning `false`.
  bool editReturnsFalse = false;

  int _nextThread = 0;

  @override
  String? extractThread(Map<String, dynamic> metadata) => switch (metadata[threadMetadataKey]) {
    final String id when id.isNotEmpty => id,
    _ => null,
  };

  @override
  ChannelResponse render(ChannelNotification notification) {
    rendered.add(notification);
    return ChannelResponse(text: notification.text, structuredPayload: {'fakeCard': notification.title});
  }

  @override
  Future<ThreadedPost?> sendToNewThread(
    String recipientId,
    ChannelResponse response, {
    required String threadKey,
  }) async {
    final error = sendError;
    final post = newThreadReturnsNull || error != null
        ? null
        : ThreadedPost(threadId: 'thread-${_nextThread++}', messageId: 'message-${sends.length}');
    sends.add((recipientId: recipientId, response: response, threadKey: threadKey, threadId: null, post: post));
    if (error != null) throw error;
    return post;
  }

  @override
  Future<ThreadedPost?> sendToThread(String recipientId, ChannelResponse response, {required String threadId}) async {
    final error = sendError;
    final post = existingThreadReturnsNull || error != null
        ? null
        : ThreadedPost(threadId: threadId, messageId: 'message-${sends.length}');
    sends.add((recipientId: recipientId, response: response, threadKey: null, threadId: threadId, post: post));
    if (error != null) throw error;
    return post;
  }

  @override
  Future<bool> edit(String recipientId, String messageId, ChannelResponse response) async {
    final error = sendError;
    edits.add((recipientId, messageId, response));
    if (error != null) throw error;
    return !editReturnsFalse;
  }
}
