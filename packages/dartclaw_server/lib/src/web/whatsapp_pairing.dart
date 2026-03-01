import '../templates/helpers.dart';
import '../templates/layout.dart';
import '../templates/sidebar.dart';
import '../templates/topbar.dart';

/// Render the WhatsApp pairing/status page using the full shell layout.
String whatsappPairingTemplate({
  String? qrImageUrl,
  bool isConnected = false,
  String? error,
  String? connectedPhone,
  SidebarData sidebarData = const (main: null, channels: [], entries: []),
}) {
  final navItems = [(label: 'Settings', href: '/settings', active: false)];
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

  final content = StringBuffer();

  if (error != null) {
    content.write(
      '<div class="banner banner-warning">${htmlEscape(error)}'
      '<button class="dismiss" aria-label="Dismiss">&#10005;</button></div>',
    );
  }

  content.write('<div class="wa-content">');

  if (isConnected) {
    final phoneDisplay = connectedPhone != null ? htmlEscape(connectedPhone) : 'Connected';
    content.write('''
<div class="wa-section">
  <div class="wa-connected-header">
    <span style="color:var(--success);font-size:var(--text-xl);">&#10003;</span>
    WhatsApp Connected
  </div>
  <div class="wa-detail">Phone: <span class="wa-detail-value">$phoneDisplay</span></div>
  <div class="wa-detail" style="color:var(--fg-overlay);font-size:var(--text-sm);">
    Messages will be delivered to your WhatsApp number.
  </div>
</div>
''');
  } else if (qrImageUrl != null) {
    content.write('''
<div class="wa-section">
  <div class="section-label">Connect WhatsApp</div>
  <div class="wa-qr-wrapper">
    <img src="${htmlEscape(qrImageUrl)}" alt="WhatsApp QR Code" class="wa-qr-img">
  </div>
  <p class="wa-hint">Open WhatsApp &rarr; Settings &rarr; Linked Devices &rarr; Link a Device, then scan this QR code.</p>
  <p style="font-size:var(--text-xs);color:var(--fg-overlay);">
    QR code refreshes automatically. <a href="/whatsapp/pairing">Reload page</a> if expired.
  </p>
  <div class="wa-status-row">
    <span class="wa-spinner"></span>
    <span style="color:var(--fg-sub0);font-size:var(--text-sm);">Waiting for connection...</span>
  </div>
</div>
''');
  } else {
    content.write('''
<div class="wa-section">
  <div class="section-label">Not Connected</div>
  <p style="color:var(--fg-sub0);font-size:var(--text-sm);">GOWA sidecar is not running or not ready.</p>
  <p style="font-size:var(--text-sm);color:var(--fg-sub0);margin-top:var(--sp-2);">
    Ensure GOWA is installed and configured in <code>dartclaw.yaml</code>:
  </p>
  <pre class="wa-pre">channels:
  whatsapp:
    enabled: true
    gowa_executable: whatsapp</pre>
</div>
''');
  }

  content.write('</div>');

  final body = '''
<div class="shell">
  $sidebar
  $topbar
  <main class="wa-main">
    <div class="wa-inner">
      $content
    </div>
  </main>
</div>''';

  return layoutTemplate(title: 'WhatsApp Setup', body: body);
}
