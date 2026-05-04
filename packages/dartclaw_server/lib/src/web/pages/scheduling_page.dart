import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:shelf/shelf.dart';

import '../../params/display_params.dart';
import '../../runtime_config.dart';
import '../../templates/scheduling.dart';
import '../dashboard_page.dart';
import '../web_utils.dart';

class SchedulingPage extends DashboardPage {
  SchedulingPage({
    this.runtimeConfigGetter,
    this.configWriter,
    this.heartbeatDisplay = const HeartbeatDisplayParams(),
    this.schedulingDisplay = const SchedulingDisplayParams(),
  });

  final RuntimeConfig? Function()? runtimeConfigGetter;
  final ConfigWriter? configWriter;
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
    final sidebarData = await context.buildSidebarData();
    final liveHeartbeat = runtimeConfigGetter?.call()?.heartbeatEnabled ?? heartbeatDisplay.enabled;

    // Read jobs fresh from YAML so newly-added jobs surface without restart;
    // fall back to the startup snapshot when no writer is wired.
    final liveJobs = configWriter != null ? await configWriter!.readSchedulingJobs() : schedulingDisplay.jobs;

    final page = schedulingTemplate(
      sidebarData: sidebarData,
      navItems: context.navItems(activePage: title),
      heartbeatEnabled: liveHeartbeat,
      heartbeatIntervalMinutes: heartbeatDisplay.intervalMinutes,
      jobs: liveJobs,
      systemJobNames: schedulingDisplay.systemJobNames,
      scheduledTasks: schedulingDisplay.scheduledTasks,
      bannerHtml: context.restartBannerHtml(),
      appName: context.appDisplay.name,
    );

    return Response.ok(page, headers: htmlHeaders);
  }
}
