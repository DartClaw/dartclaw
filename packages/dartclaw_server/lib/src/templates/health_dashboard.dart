import '../audit/audit_log_reader.dart';
import 'audit_table.dart';
import 'components.dart';
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

  final statusIcon = switch (status) {
    'healthy' =>
      '<span class="icon icon-check" style="color:var(--success);width:28px;height:28px" aria-hidden="true"></span>',
    'degraded' =>
      '<span class="icon icon-triangle-alert" style="color:var(--warning);width:28px;height:28px" aria-hidden="true"></span>',
    _ =>
      '<span class="icon icon-circle-x" style="color:var(--error);width:28px;height:28px" aria-hidden="true"></span>',
  };

  final workerBadgeClass = switch (workerState) {
    'running' || 'idle' => 'badge-success',
    'crashed' => 'badge-error',
    _ => 'badge-muted',
  };

  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);

  final topbar = pageTopbarTemplate(title: 'System Health');

  final cardDefs = <Map<String, dynamic>>[
    {
      'title': 'Worker',
      'badgeClass': workerBadgeClass,
      'badgeText': workerState,
      'rows': <Map<String, dynamic>>[
        {'label': 'State', 'value': workerState, 'valueClass': ''},
        {'label': 'Runtime', 'value': 'claude binary', 'valueClass': ''},
      ],
    },
    {
      'title': 'Database',
      'badgeClass': 'badge-success',
      'badgeText': 'ok',
      'rows': <Map<String, dynamic>>[
        {'label': 'Size', 'value': dbSizeStr, 'valueClass': ''},
        {'label': 'FTS5 Index', 'value': 'active', 'valueClass': 'text-success'},
        {'label': 'Type', 'value': 'SQLite', 'valueClass': ''},
      ],
    },
    {
      'title': 'Sessions',
      'badgeClass': 'badge-muted',
      'badgeText': '$sessionCount total',
      'rows': <Map<String, dynamic>>[
        {'label': 'Total', 'value': '$sessionCount', 'valueClass': ''},
        {'label': 'Storage', 'value': 'NDJSON files', 'valueClass': ''},
      ],
    },
    {
      'title': 'Storage',
      'badgeClass': 'badge-success',
      'badgeText': 'ok',
      'rows': <Map<String, dynamic>>[
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
      if (errors > 0) {'label': 'Errors', 'value': '$errors consecutive', 'valueClass': 'text-warning'},
    ];

    cardDefs.add({
      'title': 'Pub/Sub',
      'badgeClass': pubsubBadgeClass,
      'badgeText': pubsubBadgeText,
      'rows': pubsubRows,
    });
  }

  final cardsHtml = cardDefs
      .map(
        (c) => infoCardTemplate(
          title: c['title'] as String,
          badgeText: c['badgeText'] as String,
          badgeClass: c['badgeClass'] as String,
          rows: (c['rows'] as List).cast<Map<String, dynamic>>(),
        ),
      )
      .join('\n');

  final metricsHtml = [
    metricCardTemplate(color: 'accent', value: uptimeStr, label: 'Uptime'),
    metricCardTemplate(color: 'info', value: '$sessionCount', label: 'Sessions'),
    metricCardTemplate(color: 'info', value: dbSizeStr, label: 'DB Size'),
    metricCardTemplate(color: 'info', value: artifactDiskStr, label: 'Task Artifacts'),
  ].join('\n');

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
    'cardsHtml': cardsHtml,
    'metricsHtml': metricsHtml,
    'auditSection': auditSection,
    'bannerHtml': bannerHtml.isNotEmpty ? bannerHtml : null,
  });

  return layoutTemplate(title: 'Health', body: body, appName: appName, scripts: standardShellScripts());
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
  } catch (e) {
    return 'unknown';
  }
}
