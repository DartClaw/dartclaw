import '../templates/layout.dart';
import '../templates/loader.dart';
import '../templates/sidebar.dart';
import '../templates/topbar.dart';

/// Render the Signal pairing/status page using the full shell layout.
///
/// States (checked in order via template conditionals):
/// - [isConnected] — account registered and sidecar healthy
/// - [verificationPending] — SMS code sent, waiting for user to enter it
/// - [linkDeviceUri] set — sidecar reachable, show link-device + SMS options
/// - default — sidecar not reachable, show setup instructions
String signalPairingTemplate({
  bool isConnected = false,
  String? connectedPhone,
  String? linkDeviceUri,
  bool verificationPending = false,
  String? configuredPhone,
  String? error,
  SidebarData sidebarData = const (main: null, channels: [], entries: []),
  bool signalEnabled = false,
}) {
  final navItems = buildSystemNavItems(activePage: 'Settings', signalEnabled: signalEnabled);
  final sidebar = sidebarTemplate(
    mainSession: sidebarData.main,
    channelSessions: sidebarData.channels,
    sessionEntries: sidebarData.entries,
    navItems: navItems,
  );

  final topbar = pageTopbarTemplate(
    title: 'Signal Channel',
    backHref: '/settings',
    backLabel: 'Settings',
  );

  final showLinkDevice = !isConnected && !verificationPending && linkDeviceUri != null;

  final body = templateLoader.trellis.renderFragment(
    templateLoader.source('signal_pairing'),
    fragment: 'signalPairing',
    context: {
      'sidebar': sidebar,
      'topbar': topbar,
      'error': error,
      'isConnected': isConnected,
      'phoneDisplay': connectedPhone ?? 'Connected',
      'verificationPending': !isConnected && verificationPending,
      'verifyPhone': configuredPhone ?? 'your number',
      'showLinkDevice': showLinkDevice,
      'linkDeviceUri': linkDeviceUri ?? '',
      'smsPhoneDisplay': configuredPhone != null && configuredPhone.isNotEmpty
          ? configuredPhone
          : 'the configured number',
      'showSetup': !isConnected && !verificationPending && linkDeviceUri == null,
    },
  );

  return layoutTemplate(title: 'Signal Setup', body: body);
}
