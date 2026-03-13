import 'package:shelf/shelf.dart';

import '../../memory/memory_status_service.dart';
import '../../params/display_params.dart';
import '../../templates/memory_dashboard.dart';
import '../dashboard_page.dart';
import '../web_utils.dart';

class MemoryPage extends DashboardPage {
  MemoryPage({this.memoryStatusServiceGetter, this.workspaceDisplay = const WorkspaceDisplayParams()});

  final MemoryStatusService? Function()? memoryStatusServiceGetter;
  final WorkspaceDisplayParams workspaceDisplay;

  @override
  String get route => '/memory';

  @override
  String get title => 'Memory';

  @override
  String get navGroup => 'system';

  @override
  Future<Response> handler(Request request, PageContext context) async {
    final memService = memoryStatusServiceGetter?.call();
    if (memService == null) {
      return Response.internalServerError(
        body: 'Memory dashboard not available — workspace not configured',
        headers: htmlHeaders,
      );
    }

    final sidebarData = await context.buildSidebarData();
    final status = await memService.getStatus();
    final page = memoryDashboardTemplate(
      status: status,
      sidebarData: sidebarData,
      navItems: context.navItems(activePage: title),
      workspacePath: workspaceDisplay.path ?? '~/.dartclaw/workspace/',
      bannerHtml: context.restartBannerHtml(),
      appName: context.appDisplay.name,
    );

    return Response.ok(page, headers: htmlHeaders);
  }
}
