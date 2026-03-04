import '../templates/layout.dart';
import '../templates/loader.dart';
import '../templates/sidebar.dart';
import '../templates/topbar.dart';

/// Render the WhatsApp pairing/status page.
///
/// When [fragmentOnly] is true (HTMX SPA navigation), returns only the
/// main content + out-of-band topbar/sidebar fragments. Otherwise returns
/// the full shell layout.
String whatsappPairingTemplate({
  String? qrImageUrl,
  bool isConnected = false,
  String? error,
  String? connectedPhone,
  SidebarData sidebarData = const (main: null, channels: [], entries: []),
  bool signalEnabled = false,
  bool fragmentOnly = false,
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

  if (fragmentOnly) return '$body$topbar$sidebar';
  return layoutTemplate(title: 'WhatsApp Setup', body: body);
}
