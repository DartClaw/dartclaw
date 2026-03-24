import 'package:shelf/shelf.dart';

import '../../templates/projects.dart';
import '../dashboard_page.dart';
import '../web_utils.dart';

/// Dashboard page for managing external project repositories.
class ProjectsPage extends DashboardPage {
  @override
  String get route => '/projects';

  @override
  String get title => 'Projects';

  @override
  String? get icon => 'folder-git';

  @override
  String get navGroup => 'system';

  @override
  Future<Response> handler(Request request, PageContext context) async {
    final projectService = context.projectService;
    if (projectService == null) {
      return Response.ok(
        '<div class="empty-state"><p class="empty-state-title">Projects not configured</p></div>',
        headers: htmlHeaders,
      );
    }

    final projects = await projectService.getAll();
    final defaultProject = await projectService.getDefaultProject();
    final sidebarData = await context.buildSidebarData();

    final page = projectsPageTemplate(
      sidebarData: sidebarData,
      navItems: context.navItems(activePage: title),
      projects: projects,
      defaultProject: defaultProject,
      bannerHtml: context.restartBannerHtml(),
      appName: context.appDisplay.name,
    );

    return Response.ok(page, headers: htmlHeaders);
  }
}
