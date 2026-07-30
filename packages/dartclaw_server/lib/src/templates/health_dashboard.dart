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
  String restartBannerHtml = '',
  String appName = 'DartClaw',
  Map<String, dynamic>? pubsubHealth,
}) {
  final uptimeStr = formatUptime(uptimeSeconds);
  final dbSizeStr = formatBytes(dbSizeBytes);
  final artifactDiskStr = formatBytes(totalArtifactDiskBytes);
  final statusLabel = status[0].toUpperCase() + status.substring(1);

  final (statusCardClass, statusBadgeClass, statusDotClass) = switch (status) {
    'healthy' => ('card-featured-accent', 'status-badge-success', 'status-dot--live'),
    'degraded' => ('card-featured-warning', 'status-badge-warning', 'status-dot--warning'),
    _ => ('card-featured-error', 'status-badge-error', 'status-dot--error'),
  };

  final workerValueClass = switch (workerState) {
    '' => 'value-absent',
    'running' || 'idle' => 'text-success',
    'crashed' => 'text-error',
    _ => 'text-muted',
  };

  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);

  final topbar = pageTopbarTemplate(title: 'System Health', restartBannerHtml: restartBannerHtml);

  // Uptime, session count and DB size live in the KPI row above; the service
  // cards carry only the facts that row cannot express.
  final cardDefs = <Map<String, dynamic>>[
    {
      'title': 'Storage',
      'variant': 'success',
      'badgeText': 'ok',
      'rows': <Map<String, dynamic>>[
        {'label': 'Database', 'value': 'SQLite', 'valueClass': ''},
        {'label': 'Sessions', 'value': 'NDJSON files', 'valueClass': ''},
      ],
    },
  ];

  if (pubsubHealth != null) {
    final pubsubStatus = pubsubHealth['status'] as String? ?? 'disabled';
    final pubsubEnabled = pubsubHealth['enabled'] as bool? ?? false;
    final lastPull = pubsubHealth['last_successful_pull'] as String?;
    final errors = pubsubHealth['consecutive_errors'] as int? ?? 0;
    final activeSubs = pubsubHealth['active_subscriptions'] as int? ?? 0;

    final pubsubVariant = switch (pubsubStatus) {
      'healthy' => 'success',
      'degraded' => 'warning',
      'unavailable' => 'error',
      _ => 'muted',
    };
    final pubsubBadgeText = switch (pubsubStatus) {
      'disabled' => 'off',
      _ => pubsubStatus,
    };

    final lastPullDisplay = lastPull == null ? 'never' : formatRelativeTimeIso(lastPull);

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
      {'label': 'Last Pull', 'value': lastPullDisplay, 'valueClass': lastPullDisplay.isEmpty ? 'value-absent' : ''},
      {'label': 'Subscriptions', 'value': '$activeSubs active', 'valueClass': ''},
      if (errors > 0) {'label': 'Errors', 'value': '$errors consecutive', 'valueClass': 'text-warning'},
    ];

    cardDefs.add({'title': 'Pub/Sub', 'variant': pubsubVariant, 'badgeText': pubsubBadgeText, 'rows': pubsubRows});
  }

  final cardsHtml = cardDefs
      .map(
        (c) => infoCardTemplate(
          title: c['title'] as String,
          badgeText: c['badgeText'] as String,
          variant: c['variant'] as String,
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
    'statusCardClass': statusCardClass,
    'statusBadgeClass': statusBadgeClass,
    'statusDotClass': statusDotClass,
    'statusLabel': statusLabel,
    'version': version,
    'workerState': workerState,
    'workerValueClass': workerValueClass,
    'cardsHtml': cardsHtml,
    'metricsHtml': metricsHtml,
    'auditSection': auditSection,
  });

  return layoutTemplate(title: 'Health', body: body, appName: appName, scripts: standardShellScripts());
}
