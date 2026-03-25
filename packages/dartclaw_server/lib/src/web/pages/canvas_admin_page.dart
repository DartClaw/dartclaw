import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:shelf/shelf.dart';

import '../../templates/canvas_admin_panel.dart';
import '../dashboard_page.dart';
import '../web_utils.dart';

class CanvasAdminPage extends DashboardPage {
  CanvasAdminPage();

  @override
  String get route => '/canvas-admin';

  @override
  String get title => 'Canvas';

  @override
  String? get icon => 'presentation';

  @override
  String get navGroup => 'system';

  @override
  Future<Response> handler(Request request, PageContext context) async {
    final sidebarData = await context.buildSidebarData();
    final sessionKey = SessionKey.webSession();
    final embedUrl = '/api/sessions/${Uri.encodeComponent(sessionKey)}/canvas/embed';
    final page = canvasAdminPageTemplate(
      sidebarData: sidebarData,
      navItems: context.navItems(activePage: title),
      embedUrl: embedUrl,
      sessionKey: sessionKey,
      bannerHtml: context.restartBannerHtml(),
      appName: context.appDisplay.name,
    );
    return Response.ok(page, headers: htmlHeaders);
  }
}
