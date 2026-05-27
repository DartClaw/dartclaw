import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';

import '../api/config_api_routes.dart' show readRestartPending;
import '../health/health_service.dart';
import '../templates/restart_banner.dart';
import 'channel_status.dart';

/// Returns a status payload describing health, worker state, and session count.
Future<Map<String, dynamic>> getStatus(
  HealthService? healthService,
  WorkerState? Function()? workerStateGetter,
  int sessionCount,
) async {
  if (healthService != null) return healthService.getStatus();
  final ws = workerStateGetter?.call();
  return {
    'status': 'healthy',
    'uptime_s': 0,
    'worker_state': ws?.name ?? 'unknown',
    'session_count': sessionCount,
    'db_size_bytes': 0,
    'version': 'unknown',
  };
}

/// Resolves the [ChannelStatus] for the WhatsApp gowa sidecar.
Future<ChannelStatus> whatsAppChannelStatus(WhatsAppChannel? channel) async {
  if (channel == null) return ChannelStatus.disabled;
  final gowa = channel.gowa;
  if (!gowa.isRunning) {
    if (gowa.restartCount > 0) return ChannelStatus.reconnecting;
    return gowa.wasPaired ? ChannelStatus.connectionError : ChannelStatus.notRunning;
  }
  try {
    final status = await gowa.status();
    return status.isLoggedIn ? ChannelStatus.connected : ChannelStatus.pairingNeeded;
  } catch (e) {
    return ChannelStatus.pairingNeeded;
  }
}

/// Resolves the [ChannelStatus] for the Signal sidecar.
Future<ChannelStatus> signalChannelStatus(SignalChannel? channel) async {
  if (channel == null) return ChannelStatus.disabled;
  final sidecar = channel.sidecar;
  if (!sidecar.isRunning) {
    if (sidecar.restartCount > 0) return ChannelStatus.reconnecting;
    return sidecar.wasPaired ? ChannelStatus.connectionError : ChannelStatus.notRunning;
  }
  try {
    final registered = await sidecar.isAccountRegistered();
    return registered ? ChannelStatus.connected : ChannelStatus.pairingNeeded;
  } catch (e) {
    return ChannelStatus.pairingNeeded;
  }
}

/// Resolves the [ChannelStatus] for the Google Chat channel.
///
/// Google Chat is webhook-based (no sidecar to probe): a live [channel] means
/// connected; [enabledInConfig] without a live channel is
/// [ChannelStatus.configured] (enabled in config but not connected); otherwise
/// [ChannelStatus.disabled]. Shared by the settings card and the channel detail
/// page so both surfaces report the same status.
ChannelStatus googleChatChannelStatus(GoogleChatChannel? channel, {required bool enabledInConfig}) {
  if (channel != null) return ChannelStatus.connected;
  return enabledInConfig ? ChannelStatus.configured : ChannelStatus.disabled;
}

/// Renders pending DM pairing entries as JSON-ready maps for the dashboard.
List<Map<String, dynamic>> pendingPairingsData(DmAccessController controller) {
  final now = DateTime.now();
  return controller.pendingPairings.map((p) {
    final remaining = p.expiresAt.difference(now).inMinutes;
    return {
      'code': p.code,
      'senderId': p.jid,
      'displayName': p.displayName,
      'remainingLabel': remaining > 0 ? '${remaining}m' : '<1m',
    };
  }).toList();
}

/// Renders the restart-pending banner HTML, or an empty string when no restart is queued.
String restartBannerHtml(String? dataDir) {
  if (dataDir == null) return '';
  final pending = readRestartPending(dataDir);
  if (pending == null) return '';
  final fields = (pending['fields'] as List<dynamic>?)?.whereType<String>().toList() ?? [];
  return restartBannerTemplate(pendingFields: fields);
}
