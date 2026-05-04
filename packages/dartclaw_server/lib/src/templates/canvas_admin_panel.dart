import 'layout.dart';
import 'loader.dart';
import 'sidebar.dart';
import 'topbar.dart';

/// Renders the admin canvas dashboard page.
String canvasAdminPageTemplate({
  required SidebarData sidebarData,
  required List<NavItem> navItems,
  required String embedUrl,
  required String sessionKey,
  String bannerHtml = '',
  String appName = 'DartClaw',
}) {
  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);
  final topbar = pageTopbarTemplate(title: 'Canvas');
  final body = templateLoader.trellis.render(templateLoader.source('canvas_admin_panel'), {
    'sidebar': sidebar,
    'topbar': topbar,
    'bannerHtml': bannerHtml.isNotEmpty ? bannerHtml : null,
    'embedUrl': embedUrl,
    'sessionKey': sessionKey,
  });
  return layoutTemplate(title: 'Canvas', body: body, appName: appName, scripts: standardShellScripts());
}
