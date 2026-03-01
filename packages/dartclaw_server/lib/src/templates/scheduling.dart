import 'helpers.dart';
import 'layout.dart';
import 'sidebar.dart';
import 'topbar.dart';

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

  final topbar = pageTopbarTemplate(title: 'Scheduling Status');

  final body = '''
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
