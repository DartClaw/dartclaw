import '../templates/layout.dart';
import '../templates/loader.dart';
import '../templates/sidebar.dart';
import '../templates/topbar.dart';

/// Render the WhatsApp pairing/status page.
///
/// States (checked in order via template conditionals):
/// - [isConnected] — GOWA logged in, WhatsApp active
/// - [showReconnecting] — sidecar crashed, auto-restart in progress
/// - [qrImageUrl] set — GOWA reachable, show QR + pairing code option
/// - default — sidecar not reachable, show setup instructions
///
/// When [fragmentOnly] is true (HTMX SPA navigation), returns only the
/// main content + out-of-band topbar/sidebar fragments.
String whatsappPairingTemplate({
  String? qrImageUrl,
  int qrDuration = 60,
  bool isConnected = false,
  bool showReconnecting = false,
  String? error,
  String? connectedPhone,
  String? pairingCode,
  int restartAttempt = 0,
  int maxRestartAttempts = 5,
  SidebarData sidebarData = const (
    main: null,
    dmChannels: [],
    groupChannels: [],
    activeEntries: [],
    archivedEntries: [],
    activeTasks: [],
    activeWorkflows: [],
    showChannels: true,
    tasksEnabled: false,
  ),
  List<NavItem> navItems = const [],
  bool fragmentOnly = false,
  String appName = 'DartClaw',
}) {
  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);

  final topbar = pageTopbarTemplate(title: 'WhatsApp Channel', backHref: '/settings#channels', backLabel: 'Settings');

  final showQr = !isConnected && !showReconnecting && qrImageUrl != null;

  final body = templateLoader.trellis.renderFragment(
    templateLoader.source('whatsapp_pairing'),
    fragment: 'whatsappPairing',
    context: {
      'sidebar': sidebar,
      'topbar': topbar,
      'error': error,
      'isConnected': isConnected,
      'phoneDisplay': connectedPhone ?? 'Connected',
      'showReconnecting': showReconnecting,
      'showQr': showQr,
      'qrImageUrl': qrImageUrl ?? '',
      'pairingCode': pairingCode,
      'qrDuration': showQr ? qrDuration : 0,
      'showSetup': !isConnected && !showReconnecting && qrImageUrl == null,
      'restartAttempt': showReconnecting ? '$restartAttempt of $maxRestartAttempts' : null,
    },
  );

  if (fragmentOnly) return '$body$topbar$sidebar';
  return layoutTemplate(
    title: 'WhatsApp Setup',
    body: body,
    appName: appName,
    scripts: standardShellScripts(const ['/static/whatsapp.js']),
  );
}
