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
  required int totalArtifactDiskBytes,
  required String version,
  required SidebarData sidebarData,
  required List<NavItem> navItems,
  AuditPage? auditPage,
  String? verdictFilter,
  String? guardFilter,
  String bannerHtml = '',
  String appName = 'DartClaw',
  Map<String, dynamic>? pubsubHealth,
}) {
  final uptimeStr = formatUptime(uptimeSeconds);
  final dbSizeStr = formatBytes(dbSizeBytes);
  final artifactDiskStr = formatBytes(totalArtifactDiskBytes);
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

  if (pubsubHealth != null) {
    final pubsubStatus = pubsubHealth['status'] as String? ?? 'disabled';
    final pubsubEnabled = pubsubHealth['enabled'] as bool? ?? false;
    final lastPull = pubsubHealth['last_successful_pull'] as String?;
    final errors = pubsubHealth['consecutive_errors'] as int? ?? 0;
    final activeSubs = pubsubHealth['active_subscriptions'] as int? ?? 0;

    final pubsubBadgeClass = switch (pubsubStatus) {
      'healthy' => 'badge-success',
      'degraded' => 'badge-warning',
      'unavailable' => 'badge-error',
      _ => 'badge-muted',
    };
    final pubsubBadgeText = switch (pubsubStatus) {
      'disabled' => 'off',
      _ => pubsubStatus,
    };

    final lastPullDisplay = _formatLastPull(lastPull);

    final pubsubRows = <Map<String, dynamic>>[
      {
        'label': 'Status',
        'value': pubsubEnabled ? pubsubStatus : 'Not configured',
        'valueClass': switch (pubsubStatus) {
          'healthy' => 'text-success',
          'degraded' => 'text-warning',
          'unavailable' || 'disabled' => 'text-muted',
          _ => '',
        },
      },
      {'label': 'Last Pull', 'value': lastPullDisplay, 'valueClass': ''},
      {'label': 'Subscriptions', 'value': '$activeSubs active', 'valueClass': ''},
      if (errors > 0)
        {'label': 'Errors', 'value': '$errors consecutive', 'valueClass': 'text-warning'},
    ];

    cards.add({
      'title': 'Pub/Sub',
      'badgeClass': pubsubBadgeClass,
      'badgeText': pubsubBadgeText,
      'rows': pubsubRows,
    });
  }

  final metrics = <Map<String, dynamic>>[
    {'value': uptimeStr, 'label': 'Uptime', 'metricClass': 'card-metric--accent'},
    {'value': '$sessionCount', 'label': 'Sessions', 'metricClass': 'card-metric--info'},
    {'value': dbSizeStr, 'label': 'DB Size', 'metricClass': 'card-metric--info'},
    {'value': artifactDiskStr, 'label': 'Task Artifacts', 'metricClass': 'card-metric--info'},
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

String _formatLastPull(String? isoTimestamp) {
  if (isoTimestamp == null) return 'never';
  try {
    final dt = DateTime.parse(isoTimestamp);
    final diff = DateTime.now().toUtc().difference(dt);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  } catch (_) {
    return 'unknown';
  }
}
