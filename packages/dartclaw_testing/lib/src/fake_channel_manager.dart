import 'package:dartclaw_core/dartclaw_core.dart';

/// Capturing [ChannelManager] fake that records inbound messages.
///
/// Wraps a single-turn [MessageQueue] with a no-op dispatcher so channel tests
/// can assert which [ChannelMessage]s reached the manager via
/// [handleInboundMessage] without driving real turn execution.
class FakeChannelManager extends ChannelManager {
  /// Inbound messages captured in arrival order.
  final List<ChannelMessage> received = [];

  FakeChannelManager()
    : super(
        queue: MessageQueue(dispatcher: (_, _, {senderJid, senderDisplayName}) async => '', maxConcurrentTurns: 1),
        config: const ChannelConfig.defaults(),
      );

  @override
  void handleInboundMessage(ChannelMessage message) {
    received.add(message);
  }
}
