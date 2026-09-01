import '../templates/layout.dart';
import '../templates/loader.dart';
import '../templates/sidebar.dart';
import '../templates/topbar.dart';

/// Render the Signal pairing/status page.
///
/// When [fragmentOnly] is true (HTMX SPA navigation), returns only the
/// main content + out-of-band topbar/sidebar fragments. Otherwise returns
/// the full shell layout.
///
/// States (checked in order via template conditionals):
/// - [isConnected] — account registered and sidecar healthy
/// - [showReconnecting] — sidecar restarting after a lost connection
/// - [showStatusUnavailable] — sidecar healthy but registration probe indeterminate
/// - [linkDeviceUri] set — sidecar reachable, show the link-device QR
/// - default — sidecar not reachable, show setup instructions
String signalPairingTemplate({
  bool isConnected = false,
  bool showReconnecting = false,
  bool showStatusUnavailable = false,
  String? connectedPhone,
  String? linkDeviceUri,
  String? error,
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
    activeSessionId: null,
  ),
  List<NavItem> navItems = const [],
  bool fragmentOnly = false,
  String appName = 'DartClaw',
}) {
  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);

  final topbar = pageTopbarTemplate(title: 'Signal Channel', backHref: '/settings#channels', backLabel: 'Settings');

  final showPairingChoice = !isConnected && !showReconnecting && !showStatusUnavailable;
  final showLinkDevice = showPairingChoice && linkDeviceUri != null;

  final body = templateLoader.trellis.renderFragment(
    templateLoader.source('signal_pairing'),
    fragment: 'signalPairing',
    context: {
      'sidebar': sidebar,
      'topbar': topbar,
      'error': error,
      'isConnected': isConnected,
      'phoneDisplay': connectedPhone ?? 'Connected',
      'showReconnecting': showReconnecting,
      'showStatusUnavailable': showStatusUnavailable,
      'showLinkDevice': showLinkDevice,
      'linkDeviceUri': linkDeviceUri ?? '',
      'showSetup': showPairingChoice && linkDeviceUri == null,
      'restartAttempt': showReconnecting ? '$restartAttempt of $maxRestartAttempts' : null,
    },
  );

  if (fragmentOnly) return '$body$topbar$sidebar';
  return layoutTemplate(title: 'Signal Setup', body: body, appName: appName, scripts: standardShellScripts());
}
