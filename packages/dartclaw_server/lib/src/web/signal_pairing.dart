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
/// - [captchaPending] — Signal requires captcha before SMS registration
/// - [verificationPending] — SMS code sent, waiting for user to enter it
/// - [linkDeviceUri] set — sidecar reachable, show link-device + SMS options
/// - default — sidecar not reachable, show setup instructions
///
/// Note: SMS registration UI is currently hidden (TD-035). The captcha,
/// verify, and SMS register routes still exist for future use.
String signalPairingTemplate({
  bool isConnected = false,
  bool showReconnecting = false,
  String? connectedPhone,
  String? linkDeviceUri,
  bool verificationPending = false,
  bool captchaPending = false,
  String? captchaPhone,
  String? configuredPhone,
  String? error,
  int restartAttempt = 0,
  int maxRestartAttempts = 5,
  SidebarData sidebarData = const (main: null, dmChannels: [], groupChannels: [], activeEntries: [], archivedEntries: []),
  bool fragmentOnly = false,
  String appName = 'DartClaw',
}) {
  final navItems = buildSystemNavItems(activePage: 'Settings');
  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);

  final topbar = pageTopbarTemplate(
    title: 'Signal Channel',
    backHref: '/settings#channels',
    backLabel: 'Settings',
  );

  final showLinkDevice = !isConnected && !showReconnecting &&
      !verificationPending && !captchaPending && linkDeviceUri != null;

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
      'captchaPending': !isConnected && !showReconnecting && captchaPending,
      'captchaPhone': captchaPhone ?? '',
      'verificationPending': !isConnected && !showReconnecting &&
          !captchaPending && verificationPending,
      'verifyPhone': configuredPhone ?? 'your number',
      'showLinkDevice': showLinkDevice,
      'linkDeviceUri': linkDeviceUri ?? '',
      'smsPhoneDisplay': configuredPhone != null && configuredPhone.isNotEmpty
          ? configuredPhone
          : '',
      'showSetup': !isConnected && !showReconnecting &&
          !verificationPending && !captchaPending && linkDeviceUri == null,
      'restartAttempt': showReconnecting ? '$restartAttempt of $maxRestartAttempts' : null,
    },
  );

  if (fragmentOnly) return '$body$topbar$sidebar';
  return layoutTemplate(title: 'Signal Setup', body: body, appName: appName);
}
