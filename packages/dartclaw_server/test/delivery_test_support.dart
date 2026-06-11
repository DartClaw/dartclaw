import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';

/// Capture-only [DeliveryService] for delivery/scheduling tests.
///
/// Records each [deliver] call in [calls] instead of dispatching. The injected
/// [ChannelManager] uses a no-op dispatcher since delivery never reaches it.
class RecordingDeliveryService extends DeliveryService {
  RecordingDeliveryService({required super.sessions})
    : super(
        channelManager: ChannelManager(
          queue: MessageQueue(dispatcher: _noopTestChannelDispatch),
          config: const ChannelConfig.defaults(),
        ),
        sseBroadcast: SseBroadcast(),
      );

  final List<({DeliveryMode mode, String jobId, String result, String? webhookUrl})> calls = [];

  @override
  Future<void> deliver({
    required DeliveryMode mode,
    required String jobId,
    required String result,
    String? webhookUrl,
  }) async {
    calls.add((mode: mode, jobId: jobId, result: result, webhookUrl: webhookUrl));
  }
}

Future<String> _noopTestChannelDispatch(
  String sessionKey,
  String message, {
  String? senderJid,
  String? senderDisplayName,
}) async => '';
