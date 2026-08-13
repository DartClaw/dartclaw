import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:shelf/shelf.dart';

import '../../params/display_params.dart';
import '../../runtime_config.dart';
import '../../memory/memory_status_service.dart';
import '../../templates/scheduling.dart';
import '../dashboard_page.dart';
import '../web_utils.dart';

/// Renders the scheduled-jobs dashboard page.
class SchedulingPage extends DashboardPage {
  SchedulingPage({
    this.runtimeConfigGetter,
    this.configWriter,
    this.memoryStatusServiceGetter,
    this.heartbeatDisplay = const HeartbeatDisplayParams(),
    this.schedulingDisplay = const SchedulingDisplayParams(),
  });

  final RuntimeConfig? Function()? runtimeConfigGetter;
  final ConfigWriter? configWriter;
  final MemoryStatusService? Function()? memoryStatusServiceGetter;
  final HeartbeatDisplayParams heartbeatDisplay;
  final SchedulingDisplayParams schedulingDisplay;

  @override
  String get route => '/scheduling';

  @override
  String get title => 'Scheduling';

  @override
  String? get icon => 'scheduling';

  @override
  String get navGroup => 'system';

  @override
  Future<Response> handler(Request request, PageContext context) async {
    final sidebarData = await context.sidebar.build();
    final liveHeartbeat = runtimeConfigGetter?.call()?.heartbeatEnabled ?? heartbeatDisplay.enabled;
    final systemActionNames = schedulingDisplay.jobs
        .where((job) => job['type'] == 'system_action')
        .map((job) => job['id'] ?? job['name'])
        .whereType<String>()
        .toSet();

    var liveJobs = configWriter != null
        ? await _liveJobs(configWriter!, schedulingDisplay, systemActionNames)
        : schedulingDisplay.jobs;
    if (liveJobs == null) {
      return Response(409, body: 'A configured scheduled job conflicts with a reserved system action.');
    }
    final memoryStatus = await memoryStatusServiceGetter?.call()?.getStatus();
    if (memoryStatus != null) {
      liveJobs = [
        for (final job in liveJobs)
          if ((job['id'] ?? job['name']) == 'memory-curation')
            {...job, 'lifecycle': memoryStatus['curation'], 'index': memoryStatus['index']}
          else
            job,
      ];
    }

    final page = schedulingTemplate(
      sidebarData: sidebarData,
      navItems: context.navItems(activePage: title),
      heartbeatEnabled: liveHeartbeat,
      heartbeatIntervalMinutes: heartbeatDisplay.intervalMinutes,
      jobs: liveJobs,
      systemJobNames: schedulingDisplay.systemJobNames,
      scheduledTasks: schedulingDisplay.scheduledTasks,
      restartBannerHtml: context.restartBannerHtml(),
      appName: context.appDisplay.name,
    );

    return Response.ok(page, headers: htmlHeaders);
  }
}

Future<List<Map<String, dynamic>>?> _liveJobs(
  ConfigWriter writer,
  SchedulingDisplayParams display,
  Set<String> systemActionNames,
) async {
  final configured = await writer.readSchedulingJobs();
  if (configured.any((job) => systemActionNames.contains(job['id'] ?? job['name']))) return null;
  return [
    ...configured.where((job) => !display.systemJobNames.contains(job['id'] ?? job['name'])),
    ...display.jobs.where((job) => display.systemJobNames.contains(job['id'] ?? job['name'])),
  ];
}
