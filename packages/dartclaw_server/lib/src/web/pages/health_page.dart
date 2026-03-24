import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show WorkerState;
import 'package:shelf/shelf.dart';

import '../../audit/audit_log_reader.dart';
import '../../health/health_service.dart';
import '../../templates/health_dashboard.dart';
import '../dashboard_page.dart';
import '../page_support.dart';
import '../web_utils.dart';

class HealthDashboardPage extends DashboardPage {
  HealthDashboardPage({
    this.healthService,
    this.workerStateGetter,
    this.auditReader,
    this.pubsubHealthGetter,
  });

  final HealthService? healthService;
  final WorkerState? Function()? workerStateGetter;
  final AuditLogReader? auditReader;
  final Map<String, dynamic> Function()? pubsubHealthGetter;

  @override
  String get route => '/health-dashboard';

  @override
  String get title => 'Health';

  @override
  String? get icon => 'health';

  @override
  String get navGroup => 'system';

  @override
  Future<Response> handler(Request request, PageContext context) async {
    final params = request.url.queryParameters;
    final verdictFilter = params['verdict'];
    final guardFilter = params['guard'];
    final allSessions = await context.sessions.listSessions();
    final sidebarData = await context.buildSidebarData();
    final status = await getStatus(healthService, workerStateGetter, allSessions.length);
    final totalArtifactDiskBytes = await _totalArtifactDiskBytes(context.appDisplay.dataDir);
    final auditPage =
        await auditReader?.read(verdictFilter: verdictFilter, guardFilter: guardFilter) ?? AuditPage.empty;
    final pubsubHealth = pubsubHealthGetter?.call();

    final page = healthDashboardTemplate(
      status: status['status'] as String? ?? 'healthy',
      uptimeSeconds: status['uptime_s'] as int? ?? 0,
      workerState: status['worker_state'] as String? ?? 'unknown',
      sessionCount: status['session_count'] as int? ?? 0,
      dbSizeBytes: status['db_size_bytes'] as int? ?? 0,
      totalArtifactDiskBytes: totalArtifactDiskBytes,
      version: status['version'] as String? ?? 'unknown',
      sidebarData: sidebarData,
      navItems: context.navItems(activePage: title),
      auditPage: auditPage,
      verdictFilter: verdictFilter,
      guardFilter: guardFilter,
      bannerHtml: context.restartBannerHtml(),
      appName: context.appDisplay.name,
      pubsubHealth: pubsubHealth,
    );

    return Response.ok(page, headers: htmlHeaders);
  }
}

Future<int> _totalArtifactDiskBytes(String? dataDir) async {
  if (dataDir == null) return 0;

  final tasksDir = Directory('$dataDir/tasks');
  if (!await tasksDir.exists()) return 0;

  var total = 0;
  await for (final entity in tasksDir.list(recursive: true, followLinks: false)) {
    if (entity is File && entity.path.contains('${Platform.pathSeparator}artifacts${Platform.pathSeparator}')) {
      total += await entity.length();
    }
  }
  return total;
}
