import '../templates/layout.dart';
import '../templates/loader.dart';
import '../templates/sidebar.dart';
import '../templates/topbar.dart';

/// Render the WhatsApp pairing/status page using the full shell layout.
String whatsappPairingTemplate({
  String? qrImageUrl,
  bool isConnected = false,
  String? error,
  String? connectedPhone,
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
    title: 'WhatsApp Channel',
    backHref: '/settings',
    backLabel: 'Settings',
  );

  final body = templateLoader.trellis.renderFragment(
    templateLoader.source('whatsapp_pairing'),
    fragment: 'whatsappPairing',
    context: {
      'sidebar': sidebar,
      'topbar': topbar,
      'error': error,
      'isConnected': isConnected,
      'phoneDisplay': connectedPhone ?? 'Connected',
      'showQr': !isConnected && qrImageUrl != null,
      'qrImageUrl': qrImageUrl ?? '',
      'showSetup': !isConnected && qrImageUrl == null,
    },
  );

  return layoutTemplate(title: 'WhatsApp Setup', body: body);
}
