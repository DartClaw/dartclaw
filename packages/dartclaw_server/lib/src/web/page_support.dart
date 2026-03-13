import 'package:dartclaw_core/dartclaw_core.dart';

import '../api/config_api_routes.dart' show readRestartPending;
import '../health/health_service.dart';
import '../templates/restart_banner.dart';
import 'channel_status.dart';

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

Future<ChannelStatus> whatsAppChannelStatus(WhatsAppChannel? channel) async {
  if (channel == null) return ChannelStatus.disabled;
  final gowa = channel.gowa;
  if (!gowa.isRunning) {
    if (gowa.restartCount > 0) return ChannelStatus.reconnecting;
    return gowa.wasPaired ? ChannelStatus.connectionError : ChannelStatus.notRunning;
  }
  try {
    final status = await gowa.getStatus();
    return status.isLoggedIn ? ChannelStatus.connected : ChannelStatus.pairingNeeded;
  } catch (_) {
    return ChannelStatus.pairingNeeded;
  }
}

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
  } catch (_) {
    return ChannelStatus.pairingNeeded;
  }
}

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

String restartBannerHtml(String? dataDir) {
  if (dataDir == null) return '';
  final pending = readRestartPending(dataDir);
  if (pending == null) return '';
  final fields = (pending['fields'] as List<dynamic>?)?.whereType<String>().toList() ?? [];
  return restartBannerTemplate(pendingFields: fields);
}
