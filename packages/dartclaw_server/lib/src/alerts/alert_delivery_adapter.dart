import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

/// Thin stateless adapter that resolves an [AlertTarget] to a [Channel] and
/// calls [Channel.sendMessage].
///
/// Best-effort: all exceptions are caught and logged; no retry logic.
class AlertDeliveryAdapter {
  static final _log = Logger('AlertDeliveryAdapter');

  final Channel? Function(String channelTypeName) _channelLookup;

  AlertDeliveryAdapter(this._channelLookup);

  /// Resolves [target] to a [Channel] and sends [response] to
  /// [target.recipient].
  ///
  /// Logs a warning if the channel type is unknown. Logs an error if
  /// [Channel.sendMessage] throws. Never propagates exceptions.
  Future<void> deliver(AlertTarget target, ChannelResponse response) async {
    final channel = _channelLookup(target.channel);
    if (channel == null) {
      _log.warning('AlertDeliveryAdapter: unknown channel type "${target.channel}" for recipient "${target.recipient}"');
      return;
    }
    try {
      await channel.sendMessage(target.recipient, response);
    } catch (error, stackTrace) {
      _log.severe(
        'AlertDeliveryAdapter: failed to send alert to ${target.channel}/${target.recipient}',
        error,
        stackTrace,
      );
    }
  }
}
