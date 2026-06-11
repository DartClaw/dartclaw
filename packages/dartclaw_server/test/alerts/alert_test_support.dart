import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/alerts/alert_delivery_adapter.dart';

/// Capture-only [AlertDeliveryAdapter] for alert-routing tests.
///
/// Records each [deliver] call in [delivered] instead of dispatching to a
/// channel. The channel-lookup callback is irrelevant and returns null.
class FakeAlertDeliveryAdapter extends AlertDeliveryAdapter {
  FakeAlertDeliveryAdapter() : super((_) => null);

  final List<(AlertTarget, ChannelResponse)> delivered = [];

  @override
  Future<void> deliver(AlertTarget target, ChannelResponse response) async {
    delivered.add((target, response));
  }
}
