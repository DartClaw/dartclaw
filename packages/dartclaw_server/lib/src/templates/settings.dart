import 'helpers.dart';
import 'layout.dart';
import 'sidebar.dart';
import 'topbar.dart';

/// Settings card wrapper — shared structure for all cards on the settings page.
String _settingsCard({
  required String title,
  String? statusBadge,
  required String content,
}) {
  final badge = statusBadge ?? '';
  return '''
      <div class="card settings-card">
        <div class="card-header">
          <span class="card-title">${htmlEscape(title)}</span>
          $badge
        </div>
        $content
      </div>''';
}

/// Renders the settings hub page.
String settingsTemplate({
  required SidebarData sidebarData,
  required int uptimeSeconds,
  required int sessionCount,
  required int dbSizeBytes,
  required String workerState,
  required String version,
  bool whatsAppEnabled = false,
  bool guardsEnabled = false,
  List<String> activeGuards = const [],
  int scheduledJobsCount = 0,
  bool heartbeatEnabled = false,
  int heartbeatIntervalMinutes = 30,
  String? workspacePath,
  bool gitSyncEnabled = false,
}) {
  final uptimeStr = formatUptime(uptimeSeconds);

  final healthStatus = switch (workerState) {
    'running' || 'idle' => ('Healthy', 'status-badge-success'),
    'crashed' => ('Degraded', 'status-badge-warning'),
    _ => ('Unhealthy', 'status-badge-error'),
  };

  final waStatusBadge = whatsAppEnabled
      ? '<span class="status-badge status-badge-success">Connected</span>'
      : '<span class="status-badge status-badge-muted">Disabled</span>';

  final guardsStatusBadge = guardsEnabled && activeGuards.isNotEmpty
      ? '<span class="status-badge status-badge-success">${activeGuards.length} active</span>'
      : '<span class="status-badge status-badge-muted">Disabled</span>';

  final schedStatusBadge = (scheduledJobsCount > 0 || heartbeatEnabled)
      ? '<span class="status-badge status-badge-success">Active</span>'
      : '<span class="status-badge status-badge-muted">Inactive</span>';

  final wsStatusBadge = gitSyncEnabled
      ? '<span class="status-badge status-badge-success">Synced</span>'
      : '<span class="status-badge status-badge-muted">No sync</span>';

  final guardListHtml = StringBuffer();
  for (final g in activeGuards) {
    guardListHtml.write(
      '<div class="guard-item">'
      '<span class="guard-check">&#10003;</span> ${htmlEscape(g)}'
      '</div>\n',
    );
  }
  if (activeGuards.isEmpty) {
    guardListHtml.write('<div class="guard-item" style="color:var(--fg-overlay);">No guards active</div>\n');
  }

  final waContent = whatsAppEnabled
      ? '<div class="card-actions">'
            '<a href="/whatsapp/pairing" class="card-link">Configure &#8594;</a>'
            '</div>'
      : '<div class="card-detail" style="color:var(--fg-overlay);">Enable in dartclaw.yaml</div>';

  final workspacePathDisplay = workspacePath != null ? htmlEscape(workspacePath) : '~/.dartclaw/workspace/';

  final navItems = [
    (label: 'Health', href: '/health-dashboard', active: false),
    (label: 'Settings', href: '/settings', active: true),
    (label: 'Scheduling', href: '/scheduling', active: false),
  ];

  final sidebar = sidebarTemplate(
    mainSession: sidebarData.main,
    channelSessions: sidebarData.channels,
    sessionEntries: sidebarData.entries,
    navItems: navItems,
  );

  final topbar = pageTopbarTemplate(title: 'Settings');

  final cards = [
    _settingsCard(
      title: 'WhatsApp Channel',
      statusBadge: waStatusBadge,
      content: waContent,
    ),
    _settingsCard(
      title: 'Security & Guards',
      statusBadge: guardsStatusBadge,
      content: '''
        <div class="guard-list">
          $guardListHtml
        </div>
        <div class="card-actions">
          <a href="/health-dashboard" class="card-link">View Audit Log &#8594;</a>
        </div>''',
    ),
    _settingsCard(
      title: 'Scheduling',
      statusBadge: schedStatusBadge,
      content: '''
        <div class="card-detail">
          Scheduled jobs: <span class="card-detail-value">$scheduledJobsCount</span>
        </div>
        <div class="card-detail">
          Heartbeat: <span class="card-detail-value">${heartbeatEnabled ? 'every ${heartbeatIntervalMinutes}m' : 'disabled'}</span>
        </div>
        <div class="card-actions">
          <a href="/scheduling" class="card-link">View Schedule &#8594;</a>
        </div>''',
    ),
    _settingsCard(
      title: 'Authentication',
      statusBadge: '<span class="mode-badge">Token-based</span>',
      content: '''
        <div class="card-detail">Token:</div>
        <div class="token-row">
          <span class="token-masked">&#8226;&#8226;&#8226;&#8226;&#8226;&#8226;&#8226;&#8226;</span>
        </div>
        <div class="card-detail" style="font-size:var(--text-xs);color:var(--fg-overlay);">
          Use <code>dartclaw token show</code> to reveal
        </div>''',
    ),
    _settingsCard(
      title: 'System Health',
      statusBadge: '<span class="status-badge ${healthStatus.$2}">${htmlEscape(healthStatus.$1)}</span>',
      content: '''
        <div class="card-detail">
          Uptime: <span class="card-detail-value">$uptimeStr</span>
        </div>
        <div class="card-detail">
          Sessions: <span class="card-detail-value">$sessionCount</span>
        </div>
        <div class="card-detail">
          Version: <span class="card-detail-value">${htmlEscape(version)}</span>
        </div>
        <div class="card-actions">
          <a href="/health-dashboard" class="card-link">Full Dashboard &#8594;</a>
        </div>''',
    ),
    _settingsCard(
      title: 'Workspace',
      statusBadge: wsStatusBadge,
      content: '''
        <div class="card-detail" style="font-family:var(--font-mono);font-size:var(--text-xs);">
          $workspacePathDisplay
        </div>
        <div class="card-detail">
          Git sync: <span class="card-detail-value">${gitSyncEnabled ? 'Enabled' : 'Disabled'}</span>
        </div>''',
    ),
  ].join('\n');

  final body = '''
<div class="shell">
  $sidebar
  $topbar
  <main class="settings-area">
    <div class="settings-header">
      <h1>Settings</h1>
      <p>Configuration and system status</p>
    </div>
    <div class="settings-grid">

$cards

    </div>
  </main>
</div>''';

  return layoutTemplate(title: 'Settings', body: body);
}
