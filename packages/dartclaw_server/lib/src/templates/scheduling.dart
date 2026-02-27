import 'helpers.dart';
import 'layout.dart';
import 'sidebar.dart';

/// Renders the scheduling status page.
String schedulingTemplate({
  required SidebarData sidebarData,
  bool heartbeatEnabled = false,
  int heartbeatIntervalMinutes = 30,
  List<Map<String, dynamic>> jobs = const [],
}) {
  final heartbeatBadgeClass = heartbeatEnabled ? '' : ' paused';
  final heartbeatBadgeText = heartbeatEnabled ? 'Active' : 'Disabled';
  final pulseClass = heartbeatEnabled ? '' : ' paused';

  final jobRows = StringBuffer();
  if (jobs.isEmpty) {
    jobRows.write(
      '<tr><td colspan="4" style="text-align:center;color:var(--fg-overlay);padding:var(--sp-6);">'
      'No scheduled jobs configured</td></tr>',
    );
  } else {
    for (final job in jobs) {
      final name = htmlEscape(job['name']?.toString() ?? '');
      final schedule = htmlEscape(job['schedule']?.toString() ?? '');
      final delivery = job['delivery']?.toString() ?? 'none';
      final jobStatus = job['status']?.toString() ?? 'active';

      final deliveryBadgeClass = switch (delivery) {
        'announce' => ' announce',
        'webhook' => ' webhook',
        _ => '',
      };

      final statusDotClass = switch (jobStatus) {
        'active' => ' active',
        'error' => ' error',
        'paused' => ' paused',
        _ => '',
      };

      final rowClass = jobStatus == 'error' ? ' class="row-error"' : '';

      jobRows.write('''
<tr$rowClass>
  <td>$name</td>
  <td><span class="cron-expr">$schedule</span></td>
  <td><span class="delivery-badge$deliveryBadgeClass">${htmlEscape(delivery)}</span></td>
  <td><span class="status-dot$statusDotClass">${htmlEscape(jobStatus)}</span></td>
</tr>
''');
    }
  }

  final navItems = [
    (label: 'Health', href: '/health-dashboard', active: false),
    (label: 'Settings', href: '/settings', active: false),
    (label: 'Scheduling', href: '/scheduling', active: true),
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
  <span class="session-title-static">Scheduling Status</span>
  <div class="topbar-actions">
    <button class="theme-toggle" aria-label="Toggle theme"></button>
  </div>
</header>''';

  final body = '''
<style>
  .page-content { overflow-y: auto; padding: var(--sp-6); }
  @media (max-width: 768px) { .page-content { padding: var(--sp-4) var(--sp-3); } }
  .page-inner { max-width: var(--container-max); margin: 0 auto; display: flex; flex-direction: column; gap: var(--sp-6); }
  .page-title { font-size: var(--text-xl); font-weight: var(--weight-bold); color: var(--fg); }
  .heartbeat-card {
    background: var(--bg-mantle); border: var(--border); border-radius: var(--radius-lg);
    padding: var(--sp-5) var(--sp-6); display: flex; flex-direction: column; gap: var(--sp-4);
  }
  @media (max-width: 768px) { .heartbeat-card { padding: var(--sp-4); } }
  .heartbeat-header { display: flex; align-items: center; gap: var(--sp-3); }
  .heartbeat-label { font-size: var(--text-xs); font-weight: var(--weight-bold); text-transform: uppercase; letter-spacing: 0.1em; color: var(--fg-sub0); }
  .heartbeat-status-badge { font-size: var(--text-sm); font-weight: var(--weight-medium); padding: var(--sp-1) var(--sp-2); border-radius: var(--radius); background: color-mix(in srgb, var(--success) 15%, var(--bg-surface0)); color: var(--success); }
  .heartbeat-status-badge.paused { background: var(--bg-surface0); color: var(--fg-overlay); }
  .heartbeat-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: var(--sp-4); }
  @media (max-width: 768px) { .heartbeat-grid { grid-template-columns: 1fr 1fr; } }
  .heartbeat-stat { display: flex; flex-direction: column; gap: var(--sp-1); }
  .heartbeat-stat-label { font-size: var(--text-xs); color: var(--fg-overlay); text-transform: uppercase; letter-spacing: 0.05em; }
  .heartbeat-stat-value { font-size: var(--text-base); color: var(--fg); }
  .pulse-icon {
    display: inline-block; width: 10px; height: 10px; border-radius: 50%;
    background: var(--success); box-shadow: 0 0 0 0 var(--success);
    animation: pulse-anim 2s ease-in-out infinite;
  }
  .pulse-icon.paused { background: var(--fg-overlay); box-shadow: none; animation: none; }
  @keyframes pulse-anim {
    0%, 100% { box-shadow: 0 0 0 0 rgba(166, 227, 161, 0.4); }
    50% { box-shadow: 0 0 0 6px rgba(166, 227, 161, 0); }
  }
  .section-header { font-size: var(--text-lg); font-weight: var(--weight-bold); color: var(--fg); }
  .table-wrap { overflow-x: auto; border: var(--border); border-radius: var(--radius-lg); -webkit-overflow-scrolling: touch; }
  @media (max-width: 768px) {
    .table-wrap { position: relative; }
    .table-wrap::after { content: ''; position: absolute; top: 0; right: 0; bottom: 0; width: 32px; background: linear-gradient(to right, transparent, var(--bg-base)); pointer-events: none; }
  }
  .data-table { border-collapse: collapse; width: 100%; min-width: 560px; font-size: var(--text-sm); }
  .data-table th, .data-table td { border-bottom: var(--border); padding: var(--sp-2) var(--sp-3); text-align: left; white-space: nowrap; }
  .data-table th { background: var(--bg-surface0); font-weight: var(--weight-bold); color: var(--fg-sub0); font-size: var(--text-xs); text-transform: uppercase; letter-spacing: 0.05em; }
  .data-table td { color: var(--fg); }
  .data-table tbody tr:last-child td { border-bottom: none; }
  .data-table tbody tr:hover { background: var(--bg-mantle); }
  .data-table tr.row-error { background: color-mix(in srgb, var(--error) 5%, transparent); }
  .data-table tr.row-error:hover { background: color-mix(in srgb, var(--error) 10%, var(--bg-mantle)); }
  .cron-expr { font-size: var(--text-xs); color: var(--fg-overlay); font-family: var(--font-mono); }
  .status-dot { display: inline-flex; align-items: center; gap: var(--sp-1); }
  .status-dot::before { content: ''; display: inline-block; width: 8px; height: 8px; border-radius: 50%; background: var(--fg-overlay); }
  .status-dot.active::before { background: var(--success); }
  .status-dot.error::before { background: var(--error); }
  .status-dot.paused::before { background: var(--fg-overlay); }
  .delivery-badge { font-size: var(--text-xs); padding: 0.1em 0.4em; border-radius: var(--radius); background: var(--bg-surface0); color: var(--fg-sub0); }
  .delivery-badge.announce { background: color-mix(in srgb, var(--info) 15%, var(--bg-surface0)); color: var(--info); }
  .delivery-badge.webhook { background: color-mix(in srgb, var(--warning) 15%, var(--bg-surface0)); color: var(--warning); }
  .info-footer { font-size: var(--text-xs); color: var(--fg-overlay); padding: var(--sp-2) 0; border-top: var(--border); }
  .info-footer code { background: var(--bg-surface0); padding: 0.1em 0.3em; border-radius: var(--radius); }
</style>
<div class="shell">
  $sidebar
  $topbar
  <main class="page-content">
    <div class="page-inner">

      <div class="heartbeat-card">
        <div class="heartbeat-header">
          <span class="pulse-icon$pulseClass"></span>
          <span class="heartbeat-label">Heartbeat</span>
          <span class="heartbeat-status-badge$heartbeatBadgeClass">$heartbeatBadgeText</span>
        </div>
        <div class="heartbeat-grid">
          <div class="heartbeat-stat">
            <span class="heartbeat-stat-label">Interval</span>
            <span class="heartbeat-stat-value">${heartbeatEnabled ? 'every $heartbeatIntervalMinutes min' : '—'}</span>
          </div>
          <div class="heartbeat-stat">
            <span class="heartbeat-stat-label">Status</span>
            <span class="heartbeat-stat-value">$heartbeatBadgeText</span>
          </div>
        </div>
      </div>

      <h2 class="section-header">Scheduled Jobs</h2>
      <div class="table-wrap">
        <table class="data-table">
          <caption class="sr-only">Scheduled jobs overview</caption>
          <thead>
            <tr>
              <th>Name</th>
              <th>Schedule</th>
              <th>Delivery</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>
            $jobRows
          </tbody>
        </table>
      </div>

      <div class="info-footer">
        Scheduling configured in <code>dartclaw.yaml</code> under <code>scheduling:</code>. This is a read-only status view.
      </div>

    </div>
  </main>
</div>''';

  return layoutTemplate(title: 'Scheduling', body: body);
}
