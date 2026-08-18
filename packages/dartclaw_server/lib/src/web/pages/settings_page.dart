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
import '../../templates/helpers.dart';
import '../../templates/settings.dart';
import '../dashboard_page.dart';
import '../page_support.dart';
import '../web_utils.dart';

/// Renders the runtime-settings dashboard page.
class SettingsPage extends DashboardPage {
  new({
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
    final sidebarData = await context.sidebar.build();
    final status = await getStatus(healthService, workerStateGetter, allSessions.length);
    final gc = guardChain;
    final guardsEnabled = gc != null;
    final guardConfigs = extractGuardConfigs(gc, contentGuardDisplay: contentGuardDisplay);
    final providerCards = _buildProviderCards(providerStatus?.all ?? const <ProviderStatus>[]);
    final providerSummary = _buildProviderSummary(providerStatus?.summary);
    final waStatus = await whatsAppChannelStatus(whatsAppChannel);
    final sigStatus = await signalChannelStatus(signalChannel);
    final googleChatConfig =
        context.config?.getChannelConfig<GoogleChatConfig>(ChannelType.googlechat) ?? const GoogleChatConfig.disabled();
    final googleChatConfigured = googleChatConfig.enabled;

    final page = settingsTemplate(
      sidebarData: sidebarData,
      navItems: context.navItems(activePage: title),
      uptimeSeconds: status['uptime_s'] as int? ?? 0,
      sessionCount: status['session_count'] as int? ?? 0,
      workerState: status['worker_state'] as String? ?? '',
      version: status['version'] as String? ?? '',
      providers: providerCards,
      providerConfiguredCount: providerSummary.configured,
      providerHealthyCount: providerSummary.healthy,
      providerDegradedCount: providerSummary.degraded,
      whatsAppEnabled: whatsAppChannel != null,
      whatsAppStatus: waStatus,
      whatsAppPhone: jidToPhone(whatsAppChannel?.gowa.pairedJid),
      whatsAppPendingCount: whatsAppChannel?.dmAccess.pendingPairings.length ?? 0,
      signalEnabled: signalChannel != null,
      signalPhone: signalChannel?.sidecar.registeredPhone,
      signalStatus: sigStatus,
      signalPendingCount: signalChannel?.dmAccess.pendingPairings.length ?? 0,
      googleChatEnabled: googleChatConfigured,
      googleChatStatus: googleChatChannelStatus(googleChatChannel, enabledInConfig: googleChatConfigured),
      googleChatPendingCount: googleChatChannel?.dmAccess?.pendingPairings.length ?? 0,
      guardsEnabled: guardsEnabled,
      guardFailOpen: gc?.failOpen ?? false,
      guardConfigs: guardConfigs,
      workspacePath: workspaceDisplay.path,
      restartBannerHtml: context.restartBannerHtml(),
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
  final capacityUsagePercent = _capacityUsagePercent(
    activeWorkers: provider.activeWorkers,
    effectiveWorkers: provider.effectiveWorkers,
  );

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
    'versionDisplay': provider.binaryFound ? (absentValue(provider.version).value ?? '') : 'Not found',
    // An unreported version renders canon's .value-absent through the existing
    // class hook; "Not found" stays, being a determinate finding rather than
    // an unknown field.
    'versionClass': provider.binaryFound
        ? (absentValue(provider.version).isAbsent ? 'value-absent' : '')
        : 'detail-value-error',
    'credentialStatusLabel': switch (provider.credentialStatus) {
      'present' => 'Present',
      'oauth' => 'Authenticated',
      _ => 'Missing',
    },
    'credentialValueClass': credentialOk ? 'detail-value-ok' : 'detail-value-error',
    'credentialDotClass': credentialOk ? 'credential-dot-ok' : 'credential-dot-missing',
    'credentialEnvVarDisplay': _credentialSourceLabel(provider),
    'capacityUsageText': '${provider.activeWorkers} of ${provider.effectiveWorkers} worker leases active',
    'capacityUsageLabel': '$capacityUsagePercent% of worker capacity in use',
    'capacityUsageWidthStyle': 'width: $capacityUsagePercent%;',
    'capacityMeterEmptyClass': capacityUsagePercent == 0 ? 'meter--empty' : '',
    'capacityDetails':
        '${provider.queuedWorkers} queued · ${provider.cachedWorkers} warm · '
        '${provider.quarantinedWorkers} quarantined',
    'hasError': provider.errorMessage != null,
    'errorTitle': _providerErrorTitle(provider),
    'errorMessage': provider.errorMessage,
    ..._credentialHealthEntries(provider),
  };
}

/// Where the presented credential comes from, rendered directly above the
/// recorded mode.
///
/// The recorded mode decides before the presence answer does: `present` says
/// only that some credential resolved, so naming the API-key env var there puts
/// `ANTHROPIC_API_KEY` one line above `Subscription` on a card presenting a
/// stored subscription.
String _credentialSourceLabel(ProviderStatus provider) {
  if (provider.credentialStatus == 'oauth') {
    return 'OAuth / subscription login';
  }
  if (provider.credentialMode == 'subscription') {
    return 'Stored subscription credential';
  }
  return provider.credentialEnvVar ?? 'Credential source not configured';
}

/// Credential-health entries for the provider card's credential section.
///
/// Nothing here is rendered until health is recorded, and within a recorded
/// block the mode, expiry and remediation are each independently optional — so
/// every element carries its own `has*` boolean rather than sharing one.
Map<String, Object?> _credentialHealthEntries(ProviderStatus provider) {
  final health = _credentialHealthState(provider.credentialHealth);
  final state = _credentialStateUi(health);
  final mode = switch (provider.credentialMode) {
    'subscription' => 'Subscription',
    'api_key' => 'API key',
    _ => null,
  };
  final countdown = _credentialCountdown(
    mode: provider.credentialMode,
    expiresAt: provider.credentialExpiresAt,
    // Presenting a derived estimate as exact is the harmful direction.
    derived: provider.credentialExpiryDerived ?? true,
  );
  final lastChecked = provider.credentialLastChecked;
  // `unknown` keeps its command even though CredentialHealthState.isDegraded
  // excludes it: there the command upgrades an unmanaged vendor login to
  // DartClaw-managed auth rather than repairing a fault.
  final remediation = state == null ? null : absentValue(provider.credentialRemediation).value as String?;

  return <String, Object?>{
    'hasCredentialMode': mode != null,
    'credentialModeLabel': mode ?? '',
    'hasCredentialCountdown': countdown != null,
    'credentialCountdownLabel': countdown?.label ?? '',
    'credentialCountdownClass': countdown?.styleClass ?? '',
    'hasCredentialState': state != null,
    'credentialStateLabel': state?.label ?? '',
    'credentialStateVariant': state?.variant ?? '',
    'hasCredentialLastChecked': lastChecked != null,
    'credentialLastCheckedLabel': lastChecked == null ? '' : 'Checked ${formatRelativeTime(lastChecked)}',
    'credentialLastCheckedIso': isoTitle(lastChecked?.toIso8601String()),
    'credentialExpiresAtIso': isoTitle(provider.credentialExpiresAt?.toIso8601String()),
    'hasCredentialRemediation': remediation != null,
    'credentialRemediationLabel': health == CredentialHealthState.unknown ? 'DartClaw-managed auth:' : 'Fix:',
    'credentialRemediation': remediation ?? '',
  };
}

/// Resolves the wire string `ProviderStatus` carries back to its state.
///
/// Recovering the enum is what makes [_credentialStateUi] exhaustive, so a
/// seventh state cannot reach this page rendering as a healthy one.
CredentialHealthState? _credentialHealthState(String? jsonName) {
  for (final state in CredentialHealthState.values) {
    if (state.jsonName == jsonName) {
      return state;
    }
  }
  return null;
}

/// The credential state's badge, or `null` where no state line is shown.
///
/// `unknown` takes the neutral badge deliberately: an uncheckable credential is
/// not degraded (for Claude it means an interactive vendor login DartClaw does
/// not manage), so it must not borrow a warning hue.
({String label, String variant})? _credentialStateUi(CredentialHealthState? health) => switch (health) {
  CredentialHealthState.nearingExpiry => (label: 'Nearing expiry', variant: 'warning'),
  CredentialHealthState.refreshFailure => (label: 'Refresh failed', variant: 'warning'),
  CredentialHealthState.reauthRequired => (label: 'Re-authentication required', variant: 'error'),
  CredentialHealthState.contractBreak => (label: 'Mediation contract broken', variant: 'error'),
  CredentialHealthState.unknown => (label: 'Lifetime not checkable', variant: 'muted'),
  CredentialHealthState.healthy || null => null,
};

/// The renewal countdown, or `null` for a provider whose credential does not
/// age out (an API key) or whose mode was never recorded.
({String label, String styleClass})? _credentialCountdown({
  required String? mode,
  required DateTime? expiresAt,
  required bool derived,
}) {
  if (mode != 'subscription') {
    return null;
  }
  if (expiresAt == null) {
    return (label: 'Renewal deadline unknown', styleClass: 'value-absent');
  }
  final remaining = formatRemainingTimeIso(expiresAt.toIso8601String());
  // Colon, not a bare join: past 30 elapsed days formatRelativeTime answers an
  // absolute date, and "passed 12 Jul" would read as a typo.
  final label = remaining.isEmpty ? 'Renewal deadline passed: ${formatRelativeTime(expiresAt)}' : 'Renewal $remaining';
  return (label: derived ? '$label · derived' : label, styleClass: '');
}

int _capacityUsagePercent({required int activeWorkers, required int effectiveWorkers}) {
  if (effectiveWorkers <= 0) {
    return 0;
  }
  final percent = ((activeWorkers / effectiveWorkers) * 100).round();
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
