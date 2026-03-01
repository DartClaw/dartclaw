import 'helpers.dart';
import 'layout.dart';
import 'sidebar.dart';
import 'topbar.dart';

/// Returns the color var for the given [status].
String _statusColor(String status) => switch (status) {
  'healthy' => 'var(--success)',
  'degraded' => 'var(--warning)',
  _ => 'var(--error)',
};

String _statusHeroSection({
  required String statusColor,
  required String statusLabel,
  required String statusIcon,
  required String uptimeStr,
  required String version,
  required String workerState,
}) {
  return '''
<div class="status-hero" style="--status-color: $statusColor">
  <div class="status-indicator">$statusIcon</div>
  <div class="status-details">
    <div class="status-label">$statusLabel</div>
    <dl class="status-meta">
      <div><dt>Uptime</dt><dd>$uptimeStr</dd></div>
      <div><dt>Version</dt><dd>${htmlEscape(version)}</dd></div>
      <div><dt>Worker</dt><dd>${htmlEscape(workerState)}</dd></div>
    </dl>
  </div>
</div>''';
}

String _serviceCard({
  required String title,
  required String badgeClass,
  required String badgeText,
  required List<(String label, String value, String? style)> rows,
}) {
  final rowsHtml = rows.map((r) {
    final styleAttr = r.$3 != null ? ' style="${r.$3}"' : '';
    return '<div class="card-row">'
        '<span class="card-row-label">${htmlEscape(r.$1)}</span>'
        '<span class="card-row-value"$styleAttr>${htmlEscape(r.$2)}</span>'
        '</div>';
  }).join('\n            ');

  return '''
        <div class="card">
          <div class="card-header">
            <span class="card-title">${htmlEscape(title)}</span>
            <span class="card-badge $badgeClass">${htmlEscape(badgeText)}</span>
          </div>
          <div class="card-rows">
            $rowsHtml
          </div>
        </div>''';
}

String _metricsGridSection({
  required String uptimeStr,
  required int sessionCount,
  required String dbSizeStr,
}) {
  return '''
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
      </div>''';
}

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

  final topbar = pageTopbarTemplate(
    title: 'System Health',
    backHref: '/',
    backLabel: 'Back',
  );

  final heroHtml = _statusHeroSection(
    statusColor: statusColor,
    statusLabel: statusLabel,
    statusIcon: statusIcon,
    uptimeStr: uptimeStr,
    version: version,
    workerState: workerState,
  );

  final cardsHtml = [
    _serviceCard(
      title: 'Worker',
      badgeClass: workerBadgeClass,
      badgeText: workerState,
      rows: [
        ('State', workerState, null),
        ('Runtime', 'claude binary', null),
      ],
    ),
    _serviceCard(
      title: 'Database',
      badgeClass: 'badge-success',
      badgeText: 'ok',
      rows: [
        ('Size', dbSizeStr, null),
        ('FTS5 Index', 'active', 'color:var(--success)'),
        ('Type', 'SQLite', null),
      ],
    ),
    _serviceCard(
      title: 'Sessions',
      badgeClass: 'badge-muted',
      badgeText: '$sessionCount total',
      rows: [
        ('Total', '$sessionCount', null),
        ('Storage', 'NDJSON files', null),
      ],
    ),
    _serviceCard(
      title: 'Storage',
      badgeClass: 'badge-success',
      badgeText: 'ok',
      rows: [
        ('Search DB', dbSizeStr, null),
        ('Format', 'file-based', null),
      ],
    ),
  ].join('\n');

  final metricsHtml = _metricsGridSection(
    uptimeStr: uptimeStr,
    sessionCount: sessionCount,
    dbSizeStr: dbSizeStr,
  );

  final body = '''
<div class="shell">
  $sidebar
  $topbar
  <main class="dashboard">
    <div class="dashboard-inner">

      $heroHtml

      <h2 class="section-label">Services</h2>
      <div class="card-grid">
$cardsHtml
      </div>

$metricsHtml

    </div>
  </main>
</div>''';

  return layoutTemplate(title: 'Health', body: body);
}
