import '../audit/audit_log_reader.dart';
import 'audit_table.dart';
import 'helpers.dart';
import 'layout.dart';
import 'loader.dart';
import 'sidebar.dart';
import 'topbar.dart';

/// Renders the full health dashboard page.
String healthDashboardTemplate({
  required String status,
  required int uptimeSeconds,
  required String workerState,
  required int sessionCount,
  required int dbSizeBytes,
  required String version,
  required SidebarData sidebarData,
  AuditPage? auditPage,
  String? verdictFilter,
  String? guardFilter,
  String bannerHtml = '',
  String appName = 'DartClaw',
}) {
  final uptimeStr = formatUptime(uptimeSeconds);
  final dbSizeStr = formatBytes(dbSizeBytes);
  final statusLabel = status[0].toUpperCase() + status.substring(1);

  final statusColorClass = switch (status) {
    'healthy' => 'status-hero-healthy',
    'degraded' => 'status-hero-degraded',
    _ => 'status-hero-error',
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

  final workerBadgeClass = switch (workerState) {
    'running' || 'idle' => 'badge-success',
    'crashed' => 'badge-error',
    _ => 'badge-muted',
  };

  final navItems = buildSystemNavItems(activePage: 'Health');

  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);

  final topbar = pageTopbarTemplate(title: 'System Health', backHref: '/', backLabel: 'Back to Chat');

  final cards = <Map<String, dynamic>>[
    {
      'title': 'Worker',
      'badgeClass': workerBadgeClass,
      'badgeText': workerState,
      'rows': [
        {'label': 'State', 'value': workerState, 'valueClass': ''},
        {'label': 'Runtime', 'value': 'claude binary', 'valueClass': ''},
      ],
    },
    {
      'title': 'Database',
      'badgeClass': 'badge-success',
      'badgeText': 'ok',
      'rows': [
        {'label': 'Size', 'value': dbSizeStr, 'valueClass': ''},
        {'label': 'FTS5 Index', 'value': 'active', 'valueClass': 'text-success'},
        {'label': 'Type', 'value': 'SQLite', 'valueClass': ''},
      ],
    },
    {
      'title': 'Sessions',
      'badgeClass': 'badge-muted',
      'badgeText': '$sessionCount total',
      'rows': [
        {'label': 'Total', 'value': '$sessionCount', 'valueClass': ''},
        {'label': 'Storage', 'value': 'NDJSON files', 'valueClass': ''},
      ],
    },
    {
      'title': 'Storage',
      'badgeClass': 'badge-success',
      'badgeText': 'ok',
      'rows': [
        {'label': 'Search DB', 'value': dbSizeStr, 'valueClass': ''},
        {'label': 'Format', 'value': 'file-based', 'valueClass': ''},
      ],
    },
  ];

  final metrics = <Map<String, dynamic>>[
    {'value': uptimeStr, 'label': 'Uptime'},
    {'value': '$sessionCount', 'label': 'Sessions'},
    {'value': dbSizeStr, 'label': 'DB Size'},
  ];

  final auditSection = auditTableFragment(
    auditPage: auditPage ?? AuditPage.empty,
    verdictFilter: verdictFilter,
    guardFilter: guardFilter,
  );

  final body = templateLoader.trellis.render(templateLoader.source('health_dashboard'), {
    'sidebar': sidebar,
    'topbar': topbar,
    'statusColorClass': statusColorClass,
    'statusIcon': statusIcon,
    'statusLabel': statusLabel,
    'uptimeStr': uptimeStr,
    'version': version,
    'workerState': workerState,
    'cards': cards,
    'metrics': metrics,
    'auditSection': auditSection,
    'bannerHtml': bannerHtml.isNotEmpty ? bannerHtml : null,
  });

  return layoutTemplate(title: 'Health', body: body, appName: appName);
}
