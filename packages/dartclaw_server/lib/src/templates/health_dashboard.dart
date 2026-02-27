import 'helpers.dart';
import 'layout.dart';
import 'sidebar.dart';

/// Returns the color var for the given [status].
String _statusColor(String status) => switch (status) {
  'healthy' => 'var(--success)',
  'degraded' => 'var(--warning)',
  _ => 'var(--error)',
};

/// Renders the full health dashboard page.
String healthDashboardTemplate({
  required String status,
  required int uptimeSeconds,
  required String workerState,
  required int sessionCount,
  required int dbSizeBytes,
  required String version,
  required SidebarData sidebarData,
}) {
  final statusColor = _statusColor(status);
  final statusLabel = status[0].toUpperCase() + status.substring(1);
  final uptimeStr = formatUptime(uptimeSeconds);
  final dbSizeStr = formatBytes(dbSizeBytes);

  final workerBadgeClass = switch (workerState) {
    'running' || 'idle' => 'badge-success',
    'crashed' => 'badge-error',
    _ => 'badge-muted',
  };

  const svgAttrs =
      'viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" '
      'stroke-linecap="round" stroke-linejoin="round" width="28" height="28"';
  final statusIcon = switch (status) {
    'healthy' => '<svg $svgAttrs><polyline points="20 6 9 17 4 12"/></svg>',
    'degraded' =>
      '<svg $svgAttrs>'
          '<path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/>'
          '<line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/></svg>',
    _ =>
      '<svg $svgAttrs>'
          '<circle cx="12" cy="12" r="10"/>'
          '<line x1="15" y1="9" x2="9" y2="15"/><line x1="9" y1="9" x2="15" y2="15"/></svg>',
  };

  final navItems = [
    (label: 'Health', href: '/health-dashboard', active: true),
    (label: 'Settings', href: '/settings', active: false),
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
  <span class="session-title-static">System Health</span>
  <div class="topbar-actions">
    <a href="/" class="btn btn-ghost" style="font-size: var(--text-sm);">&larr; Back</a>
    <button class="theme-toggle" aria-label="Toggle theme"></button>
  </div>
</header>''';

  final body =
      '''
<style>
  .dashboard { overflow-y: auto; padding: var(--sp-6); }
  .dashboard-inner { max-width: var(--container-max); margin: 0 auto; }
  .status-hero {
    display: flex; align-items: center; gap: var(--sp-6); padding: var(--sp-6);
    background: var(--bg-mantle); border: var(--border); border-radius: var(--radius-lg);
    margin-bottom: var(--sp-6);
  }
  @media (max-width: 768px) { .status-hero { flex-direction: column; text-align: center; } }
  .status-indicator {
    display: flex; align-items: center; justify-content: center;
    width: 64px; height: 64px; border-radius: 50%; flex-shrink: 0;
    background: color-mix(in srgb, $statusColor 15%, var(--bg-base));
    border: 2px solid $statusColor; color: $statusColor;
  }
  .status-details { flex: 1; min-width: 0; }
  .status-label { font-size: var(--text-xl); font-weight: var(--weight-bold); color: $statusColor; }
  .status-meta { display: flex; gap: var(--sp-6); margin-top: var(--sp-2); flex-wrap: wrap; }
  @media (max-width: 768px) { .status-meta { justify-content: center; } }
  .status-meta dt {
    color: var(--fg-overlay); font-size: var(--text-xs);
    text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: var(--sp-1);
  }
  .status-meta dd { font-weight: var(--weight-medium); color: var(--fg); }
  .card-grid {
    display: grid; grid-template-columns: repeat(2, 1fr); gap: var(--sp-4);
    margin-bottom: var(--sp-6);
  }
  @media (max-width: 768px) { .card-grid { grid-template-columns: 1fr; } }
  .card-header {
    display: flex; align-items: center; justify-content: space-between; margin-bottom: var(--sp-3);
  }
  .card-title {
    font-size: var(--text-sm); font-weight: var(--weight-bold); color: var(--fg-sub1);
    text-transform: uppercase; letter-spacing: 0.05em;
  }
  .card-badge { font-size: var(--text-xs); font-weight: var(--weight-medium); padding: var(--sp-1) var(--sp-2); border-radius: var(--radius); }
  .badge-success { background: color-mix(in srgb, var(--success) 15%, var(--bg-base)); color: var(--success); }
  .badge-warning { background: color-mix(in srgb, var(--warning) 15%, var(--bg-base)); color: var(--warning); }
  .badge-error   { background: color-mix(in srgb, var(--error)   15%, var(--bg-base)); color: var(--error); }
  .badge-muted   { background: var(--bg-surface0); color: var(--fg-sub0); }
  .card-rows { display: flex; flex-direction: column; gap: var(--sp-2); }
  .card-row { display: flex; justify-content: space-between; align-items: center; font-size: var(--text-sm); }
  .card-row-label { color: var(--fg-overlay); }
  .card-row-value { color: var(--fg); font-weight: var(--weight-medium); text-align: right; }
  .metrics-grid {
    display: grid; grid-template-columns: repeat(3, 1fr); gap: var(--sp-4); margin-bottom: var(--sp-4);
  }
  @media (max-width: 768px) { .metrics-grid { grid-template-columns: repeat(2, 1fr); } }
  .metric-card {
    background: var(--bg-mantle); border: var(--border); border-radius: var(--radius-lg);
    padding: var(--sp-3) var(--sp-4); text-align: center;
  }
  .metric-value { font-size: var(--text-xl); font-weight: var(--weight-bold); color: var(--fg); line-height: var(--leading-tight); }
  .metric-label { font-size: var(--text-xs); color: var(--fg-overlay); text-transform: uppercase; letter-spacing: 0.05em; margin-top: var(--sp-1); }
</style>
<div class="shell">
  $sidebar
  $topbar
  <main class="dashboard">
    <div class="dashboard-inner">

      <div class="status-hero">
        <div class="status-indicator">$statusIcon</div>
        <div class="status-details">
          <div class="status-label">$statusLabel</div>
          <dl class="status-meta">
            <div><dt>Uptime</dt><dd>$uptimeStr</dd></div>
            <div><dt>Version</dt><dd>${htmlEscape(version)}</dd></div>
            <div><dt>Worker</dt><dd>${htmlEscape(workerState)}</dd></div>
          </dl>
        </div>
      </div>

      <h2 class="section-label">Services</h2>
      <div class="card-grid">
        <div class="card">
          <div class="card-header">
            <span class="card-title">Worker</span>
            <span class="card-badge $workerBadgeClass">${htmlEscape(workerState)}</span>
          </div>
          <div class="card-rows">
            <div class="card-row">
              <span class="card-row-label">State</span>
              <span class="card-row-value">${htmlEscape(workerState)}</span>
            </div>
            <div class="card-row">
              <span class="card-row-label">Runtime</span>
              <span class="card-row-value">claude binary</span>
            </div>
          </div>
        </div>

        <div class="card">
          <div class="card-header">
            <span class="card-title">Database</span>
            <span class="card-badge badge-success">ok</span>
          </div>
          <div class="card-rows">
            <div class="card-row">
              <span class="card-row-label">Size</span>
              <span class="card-row-value">$dbSizeStr</span>
            </div>
            <div class="card-row">
              <span class="card-row-label">FTS5 Index</span>
              <span class="card-row-value" style="color:var(--success)">active</span>
            </div>
            <div class="card-row">
              <span class="card-row-label">Type</span>
              <span class="card-row-value">SQLite</span>
            </div>
          </div>
        </div>

        <div class="card">
          <div class="card-header">
            <span class="card-title">Sessions</span>
            <span class="card-badge badge-muted">$sessionCount total</span>
          </div>
          <div class="card-rows">
            <div class="card-row">
              <span class="card-row-label">Total</span>
              <span class="card-row-value">$sessionCount</span>
            </div>
            <div class="card-row">
              <span class="card-row-label">Storage</span>
              <span class="card-row-value">NDJSON files</span>
            </div>
          </div>
        </div>

        <div class="card">
          <div class="card-header">
            <span class="card-title">Storage</span>
            <span class="card-badge badge-success">ok</span>
          </div>
          <div class="card-rows">
            <div class="card-row">
              <span class="card-row-label">Search DB</span>
              <span class="card-row-value">$dbSizeStr</span>
            </div>
            <div class="card-row">
              <span class="card-row-label">Format</span>
              <span class="card-row-value">file-based</span>
            </div>
          </div>
        </div>
      </div>

      <h2 class="section-label">Metrics</h2>
      <div class="metrics-grid">
        <div class="metric-card">
          <div class="metric-value">$uptimeStr</div>
          <div class="metric-label">Uptime</div>
        </div>
        <div class="metric-card">
          <div class="metric-value">$sessionCount</div>
          <div class="metric-label">Sessions</div>
        </div>
        <div class="metric-card">
          <div class="metric-value">$dbSizeStr</div>
          <div class="metric-label">DB Size</div>
        </div>
      </div>

    </div>
  </main>
</div>''';

  return layoutTemplate(title: 'Health', body: body);
}
