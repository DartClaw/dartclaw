import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
import 'package:shelf/shelf.dart';

import '../../health/health_service.dart';
import '../../params/display_params.dart';
import '../../provider_status_service.dart';
import '../../templates/guard_config_summary.dart';
import '../../templates/settings.dart';
import '../dashboard_page.dart';
import '../page_support.dart';
import '../web_utils.dart';

class SettingsPage extends DashboardPage {
  SettingsPage({
    this.healthService,
    this.workerStateGetter,
    this.whatsAppChannel,
    this.signalChannel,
    this.googleChatChannel,
    this.guardChain,
    this.providerStatus,
    this.contentGuardDisplay = const ContentGuardDisplayParams(),
    this.workspaceDisplay = const WorkspaceDisplayParams(),
  });

  final HealthService? healthService;
  final WorkerState? Function()? workerStateGetter;
  final WhatsAppChannel? whatsAppChannel;
  final SignalChannel? signalChannel;
  final GoogleChatChannel? googleChatChannel;
  final GuardChain? guardChain;
  final ProviderStatusService? providerStatus;
  final ContentGuardDisplayParams contentGuardDisplay;
  final WorkspaceDisplayParams workspaceDisplay;

  @override
  String get route => '/settings';

  @override
  String get title => 'Settings';

  @override
  String? get icon => 'settings';

  @override
  String get navGroup => 'system';

  @override
  Future<Response> handler(Request request, PageContext context) async {
    ensureDartclawGoogleChatRegistered();

    final allSessions = await context.sessions.listSessions();
    final sidebarData = await context.buildSidebarData();
    final status = await getStatus(healthService, workerStateGetter, allSessions.length);
    final gc = guardChain;
    final guardsEnabled = gc != null;
    final guardConfigs = extractGuardConfigs(gc, contentGuardDisplay: contentGuardDisplay);
    final providerCards = _buildProviderCards(providerStatus?.getAll() ?? const <ProviderStatus>[]);
    final providerSummary = _buildProviderSummary(providerStatus?.getSummary());
    final waStatus = await whatsAppChannelStatus(whatsAppChannel);
    final sigStatus = await signalChannelStatus(signalChannel);
    final googleChatConfig =
        context.config?.getChannelConfig<GoogleChatConfig>(ChannelType.googlechat) ?? const GoogleChatConfig.disabled();
    final googleChatConfigured = googleChatConfig.enabled;
    final googleChatConnected = googleChatChannel != null;

    final page = settingsTemplate(
      sidebarData: sidebarData,
      navItems: context.navItems(activePage: title),
      uptimeSeconds: status['uptime_s'] as int? ?? 0,
      sessionCount: status['session_count'] as int? ?? 0,
      workerState: status['worker_state'] as String? ?? 'unknown',
      version: status['version'] as String? ?? 'unknown',
      providers: providerCards,
      providerConfiguredCount: providerSummary.configured,
      providerHealthyCount: providerSummary.healthy,
      providerDegradedCount: providerSummary.degraded,
      whatsAppEnabled: whatsAppChannel != null,
      whatsAppStatusLabel: waStatus.label,
      whatsAppStatusClass: waStatus.badgeClass,
      whatsAppPhone: jidToPhone(whatsAppChannel?.gowa.pairedJid),
      whatsAppPendingCount: whatsAppChannel?.dmAccess.pendingPairings.length ?? 0,
      signalEnabled: signalChannel != null,
      signalPhone: signalChannel?.sidecar.registeredPhone,
      signalStatusLabel: sigStatus.label,
      signalStatusClass: sigStatus.badgeClass,
      signalPendingCount: signalChannel?.dmAccess.pendingPairings.length ?? 0,
      googleChatEnabled: googleChatConfigured,
      googleChatStatusLabel: googleChatConnected
          ? 'Connected'
          : googleChatConfigured
          ? 'Configured'
          : 'Disabled',
      googleChatStatusClass: googleChatConnected
          ? 'status-badge-success'
          : googleChatConfigured
          ? 'status-badge-warning'
          : 'status-badge-muted',
      googleChatPendingCount: googleChatChannel?.dmAccess?.pendingPairings.length ?? 0,
      guardsEnabled: guardsEnabled,
      guardFailOpen: gc?.failOpen ?? false,
      guardConfigs: guardConfigs,
      workspacePath: workspaceDisplay.path,
      bannerHtml: context.restartBannerHtml(),
      appName: context.appDisplay.name,
    );

    return Response.ok(page, headers: htmlHeaders);
  }
}

({int configured, int healthy, int degraded}) _buildProviderSummary(Map<String, dynamic>? summary) {
  final counts = summary ?? const <String, dynamic>{};
  return (
    configured: _summaryCount(counts['configured']),
    healthy: _summaryCount(counts['healthy']),
    degraded: _summaryCount(counts['degraded']),
  );
}

int _summaryCount(Object? value) {
  if (value is int) {
    return value;
  }
  return int.tryParse('$value') ?? 0;
}

List<Map<String, Object?>> _buildProviderCards(List<ProviderStatus> providers) {
  return providers.map(_buildProviderCard).toList(growable: false);
}

Map<String, Object?> _buildProviderCard(ProviderStatus provider) {
  final healthUi = _providerHealthUi(provider.health);
  final credentialOk = provider.credentialStatus != 'missing';
  final poolUsagePercent = _poolUsagePercent(activeWorkers: provider.activeWorkers, poolSize: provider.poolSize);

  return <String, Object?>{
    'id': provider.id,
    'title': ProviderIdentity.displayName(provider.id),
    'subtitle': 'Provider ID: ${provider.id}',
    'iconLabel': _providerIconLabel(provider.id),
    'iconClass': _providerIconClass(provider.id, binaryFound: provider.binaryFound),
    'isDefault': provider.isDefault,
    'healthLabel': healthUi.label,
    'healthBadgeClass': healthUi.badgeClass,
    'binaryStatusLabel': provider.binaryFound ? 'Found' : 'Not found',
    'binaryStatusClass': provider.binaryFound ? 'detail-value-ok' : 'detail-value-error',
    'executable': provider.executable,
    'versionDisplay': provider.binaryFound ? (provider.version ?? 'unknown') : 'Not found',
    'versionClass': provider.binaryFound ? '' : 'detail-value-error',
    'credentialStatusLabel': switch (provider.credentialStatus) {
      'present' => 'Present',
      'oauth' => 'Authenticated',
      _ => 'Missing',
    },
    'credentialValueClass': credentialOk ? 'detail-value-ok' : 'detail-value-error',
    'credentialDotClass': credentialOk ? 'credential-dot-ok' : 'credential-dot-missing',
    'credentialEnvVarDisplay': switch (provider.credentialStatus) {
      'oauth' => 'OAuth / subscription login',
      _ => provider.credentialEnvVar ?? 'Credential source not configured',
    },
    'poolUsageText': provider.poolSize > 0
        ? '${provider.activeWorkers} of ${provider.poolSize} Task Workers busy'
        : 'No Workers configured',
    'poolUsageLabel': provider.poolSize > 0
        ? '$poolUsagePercent% of Task Harness Pool in use'
        : 'Configure pool_size to reserve task Workers',
    'poolUsageWidthStyle': 'width: $poolUsagePercent%;',
    'hasError': provider.errorMessage != null,
    'errorTitle': _providerErrorTitle(provider),
    'errorMessage': provider.errorMessage,
  };
}

int _poolUsagePercent({required int activeWorkers, required int poolSize}) {
  if (poolSize <= 0) {
    return 0;
  }
  final percent = ((activeWorkers / poolSize) * 100).round();
  return percent.clamp(0, 100).toInt();
}

({String label, String badgeClass}) _providerHealthUi(String health) {
  return switch (health) {
    'healthy' => (label: 'Healthy', badgeClass: 'status-badge-success'),
    'degraded' => (label: 'Degraded', badgeClass: 'status-badge-warning'),
    _ => (label: 'Unavailable', badgeClass: 'status-badge-error'),
  };
}

String _providerIconLabel(String id) {
  final normalized = id.trim().toUpperCase();
  if (normalized.isEmpty) {
    return '??';
  }
  if (normalized.length <= 2) {
    return normalized;
  }
  return normalized.substring(0, 2);
}

String _providerIconClass(String id, {required bool binaryFound}) {
  if (!binaryFound) {
    return 'provider-icon-missing';
  }
  return switch (ProviderIdentity.family(id)) {
    'claude' => 'provider-icon-claude',
    'codex' => 'provider-icon-codex',
    _ => 'provider-icon-generic',
  };
}

String _providerErrorTitle(ProviderStatus provider) {
  if (!provider.binaryFound) {
    return 'Binary unavailable';
  }
  if (provider.credentialStatus == 'missing') {
    return 'Credentials missing';
  }
  return 'Action required';
}
