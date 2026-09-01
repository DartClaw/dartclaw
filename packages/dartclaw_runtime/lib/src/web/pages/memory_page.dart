import 'package:shelf/shelf.dart';

import '../../memory/memory_prune_service.dart';
import '../../memory/memory_status_service.dart';
import '../../templates/memory_dashboard.dart';
import '../dashboard_page.dart';
import '../web_utils.dart';

class MemoryPage extends DashboardPage {
  new({this.memoryStatusServiceGetter, this.memoryPruneServiceGetter});
  final MemoryStatusService? Function()? memoryStatusServiceGetter;
  final MemoryPruneService? Function()? memoryPruneServiceGetter;
  @override
  String get route => '/memory';
  @override
  String get title => 'Memory';
  @override
  String? get icon => 'memory';
  @override
  String get navGroup => 'system';
  @override
  List<PageRouteDeclaration> get declaredRoutes => const [(method: 'POST', path: '/memory/prune')];
  @override
  Future<Response> handler(Request request, PageContext context) async {
    final memService = memoryStatusServiceGetter?.call();
    if (memService == null) {
      return Response.internalServerError(
        body: 'Memory dashboard not available — workspace not configured',
        headers: htmlHeaders,
      );
    }
    if (request.method == 'POST') {
      return _prune(memService, context);
    }
    final sidebarData = await context.sidebar.build();
    final status = await memService.getStatus();
    final page = memoryDashboardTemplate(
      status: status,
      sidebarData: sidebarData,
      navItems: context.navItems(activePage: title),
      workspacePath: context.config?.workspaceDir ?? '~/.dartclaw/workspace/',
      restartBannerHtml: context.restartBannerHtml(),
      appName: context.appName,
    );
    return Response.ok(page, headers: htmlHeaders);
  }

  Future<Response> _prune(MemoryStatusService statusService, PageContext context) async {
    final result = await memoryPruneServiceGetter?.call()?.prune();
    final type = result == null ? 'error' : 'success';
    final message = result == null
        ? 'Memory pruner not configured'
        : 'Archived ${result.entriesArchived}; de-duplicated ${result.duplicatesRemoved}; '
              '${result.entriesRemaining} entries remain';
    final fragment = memoryDashboardContentFragment(
      status: await statusService.getStatus(),
      workspacePath: context.config?.workspaceDir ?? '',
    );
    return Response.ok(fragment, headers: {...htmlHeaders, ...toastTriggerHeader(type, message)});
  }
}
