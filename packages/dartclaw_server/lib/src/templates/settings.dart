import 'helpers.dart';
import 'layout.dart';
import 'sidebar.dart';

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

  final waCard = whatsAppEnabled
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

  final topbar = '''
<header class="topbar">
  <button class="btn btn-icon btn-ghost menu-toggle" aria-label="Open sidebar">&#9776;</button>
  <span class="session-title-static">Settings</span>
  <div class="topbar-actions">
    <button class="theme-toggle" aria-label="Toggle theme"></button>
  </div>
</header>''';

  final body =
      '''
<style>
  .settings-area { overflow-y: auto; padding: var(--sp-6) var(--sp-8); }
  @media (max-width: 768px) { .settings-area { padding: var(--sp-4); } }
  .settings-header { margin-bottom: var(--sp-6); }
  .settings-header h1 { font-size: var(--text-xl); font-weight: var(--weight-bold); color: var(--fg); margin-bottom: var(--sp-1); }
  .settings-header p { font-size: var(--text-sm); color: var(--fg-overlay); }
  .settings-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: var(--sp-4); max-width: 960px; }
  @media (max-width: 768px) { .settings-grid { grid-template-columns: 1fr; } }
  .settings-card { display: flex; flex-direction: column; gap: var(--sp-3); }
  .card-header { display: flex; align-items: center; justify-content: space-between; gap: var(--sp-2); }
  .card-title { font-size: var(--text-base); font-weight: var(--weight-bold); color: var(--fg); }
  .card-detail { font-size: var(--text-sm); color: var(--fg-sub0); display: flex; align-items: center; gap: var(--sp-1); flex-wrap: wrap; }
  .card-detail-value { color: var(--fg); }
  .guard-list { display: flex; flex-direction: column; gap: var(--sp-1); }
  .guard-item { display: flex; align-items: center; gap: var(--sp-2); font-size: var(--text-sm); color: var(--fg-sub0); }
  .guard-check { color: var(--success); font-weight: var(--weight-bold); flex-shrink: 0; }
  .token-row { display: flex; align-items: center; gap: var(--sp-2); }
  .token-masked { font-family: var(--font-mono); font-size: var(--text-sm); color: var(--fg); letter-spacing: 0.1em; }
  .card-actions {
    margin-top: auto; padding-top: var(--sp-2);
    border-top: 1px solid color-mix(in srgb, var(--bg-surface0) 50%, transparent);
    display: flex; align-items: center; gap: var(--sp-2);
  }
  .card-link { font-size: var(--text-xs); color: var(--accent); text-decoration: none; display: inline-flex; align-items: center; gap: var(--sp-1); }
  .card-link:hover { text-decoration: underline; }
  .mode-badge { font-size: var(--text-xs); font-weight: var(--weight-medium); padding: 2px var(--sp-2); border-radius: var(--radius); background: var(--bg-surface0); color: var(--fg-sub0); }
</style>
<div class="shell">
  $sidebar
  $topbar
  <main class="settings-area">
    <div class="settings-header">
      <h1>Settings</h1>
      <p>Configuration and system status</p>
    </div>
    <div class="settings-grid">

      <!-- WhatsApp Channel -->
      <div class="card settings-card">
        <div class="card-header">
          <span class="card-title">WhatsApp Channel</span>
          $waStatusBadge
        </div>
        $waCard
      </div>

      <!-- Security & Guards -->
      <div class="card settings-card">
        <div class="card-header">
          <span class="card-title">Security &amp; Guards</span>
          $guardsStatusBadge
        </div>
        <div class="guard-list">
          $guardListHtml
        </div>
        <div class="card-actions">
          <a href="/health-dashboard" class="card-link">View Audit Log &#8594;</a>
        </div>
      </div>

      <!-- Scheduling -->
      <div class="card settings-card">
        <div class="card-header">
          <span class="card-title">Scheduling</span>
          $schedStatusBadge
        </div>
        <div class="card-detail">
          Scheduled jobs: <span class="card-detail-value">$scheduledJobsCount</span>
        </div>
        <div class="card-detail">
          Heartbeat: <span class="card-detail-value">${heartbeatEnabled ? 'every ${heartbeatIntervalMinutes}m' : 'disabled'}</span>
        </div>
        <div class="card-actions">
          <a href="/scheduling" class="card-link">View Schedule &#8594;</a>
        </div>
      </div>

      <!-- Authentication -->
      <div class="card settings-card">
        <div class="card-header">
          <span class="card-title">Authentication</span>
          <span class="mode-badge">Token-based</span>
        </div>
        <div class="card-detail">Token:</div>
        <div class="token-row">
          <span class="token-masked">&#8226;&#8226;&#8226;&#8226;&#8226;&#8226;&#8226;&#8226;</span>
        </div>
        <div class="card-detail" style="font-size:var(--text-xs);color:var(--fg-overlay);">
          Use <code>dartclaw token show</code> to reveal
        </div>
      </div>

      <!-- System Health -->
      <div class="card settings-card">
        <div class="card-header">
          <span class="card-title">System Health</span>
          <span class="status-badge ${healthStatus.$2}">${htmlEscape(healthStatus.$1)}</span>
        </div>
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
        </div>
      </div>

      <!-- Workspace -->
      <div class="card settings-card">
        <div class="card-header">
          <span class="card-title">Workspace</span>
          $wsStatusBadge
        </div>
        <div class="card-detail" style="font-family:var(--font-mono);font-size:var(--text-xs);">
          $workspacePathDisplay
        </div>
        <div class="card-detail">
          Git sync: <span class="card-detail-value">${gitSyncEnabled ? 'Enabled' : 'Disabled'}</span>
        </div>
      </div>

    </div>
  </main>
</div>''';

  return layoutTemplate(title: 'Settings', body: body);
}
