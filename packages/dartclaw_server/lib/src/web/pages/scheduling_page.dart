import 'package:shelf/shelf.dart';

import '../../params/display_params.dart';
import '../../runtime_config.dart';
import '../../templates/scheduling.dart';
import '../dashboard_page.dart';
import '../web_utils.dart';

class SchedulingPage extends DashboardPage {
  SchedulingPage({
    this.runtimeConfigGetter,
    this.heartbeatDisplay = const HeartbeatDisplayParams(),
    this.schedulingDisplay = const SchedulingDisplayParams(),
  });

  final RuntimeConfig? Function()? runtimeConfigGetter;
  final HeartbeatDisplayParams heartbeatDisplay;
  final SchedulingDisplayParams schedulingDisplay;

  @override
  String get route => '/scheduling';

  @override
  String get title => 'Scheduling';

  @override
  String get navGroup => 'system';

  @override
  Future<Response> handler(Request request, PageContext context) async {
    final sidebarData = await context.buildSidebarData();
    final liveHeartbeat = runtimeConfigGetter?.call()?.heartbeatEnabled ?? heartbeatDisplay.enabled;

    final page = schedulingTemplate(
      sidebarData: sidebarData,
      navItems: context.navItems(activePage: title),
      heartbeatEnabled: liveHeartbeat,
      heartbeatIntervalMinutes: heartbeatDisplay.intervalMinutes,
      jobs: schedulingDisplay.jobs,
      systemJobNames: schedulingDisplay.systemJobNames,
      scheduledTasks: schedulingDisplay.scheduledTasks,
      bannerHtml: context.restartBannerHtml(),
      appName: context.appDisplay.name,
    );

    return Response.ok(page, headers: htmlHeaders);
  }
}
