import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
import 'package:shelf/shelf.dart';

import '../../health/health_service.dart';
import '../../params/display_params.dart';
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
    this.contentGuardDisplay = const ContentGuardDisplayParams(),
    this.workspaceDisplay = const WorkspaceDisplayParams(),
  });

  final HealthService? healthService;
  final WorkerState? Function()? workerStateGetter;
  final WhatsAppChannel? whatsAppChannel;
  final SignalChannel? signalChannel;
  final GoogleChatChannel? googleChatChannel;
  final GuardChain? guardChain;
  final ContentGuardDisplayParams contentGuardDisplay;
  final WorkspaceDisplayParams workspaceDisplay;

  @override
  String get route => '/settings';

  @override
  String get title => 'Settings';

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
