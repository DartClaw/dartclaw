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
  });

  @override
  final String name;

  @override
  final ChannelType type;

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
